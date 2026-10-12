import Foundation

// 云同步重放器。
//
// 触发时机由调用方决定（前台、网络恢复、用户手动、本地有新变更、退避到点），
// 但**同一时刻只有一个重放在跑**：用 InFlightWriteGuard（复用既有类型）做互斥，
// actor 隔离本身挡不住 await 处的重入，所以互斥必须显式做。
//
// 三条硬约束：
//   1. 未登录 -> 完全本地可用，一个网络请求都不发；
//   2. pull 失败 -> 绝不推进游标（推进了就会永久丢数据）；
//   3. 网络失败 -> 退避后重试，绝不紧密重试；401 -> 需要重新登录，不重试。

/// 一次重放的触发原因。只用于日志与界面提示。
public enum CloudSyncTrigger: String, Sendable {
    case appForeground
    case networkRestored
    case manual
    case localChange
    case retry

    public var displayName: String {
        switch self {
        case .appForeground: return "App 进入前台"
        case .networkRestored: return "网络恢复"
        case .manual: return "手动同步"
        case .localChange: return "本地有新变更"
        case .retry: return "自动重试"
        }
    }
}

/// 登录状态。界面据此显示「未登录，云同步未启用」，而不是「同步失败」。
public enum CloudSyncSignInState: Equatable, Sendable {
    case notSignedIn
    case signedIn
    case needsReauthentication(reason: String)

    public var isUsable: Bool { self == .signedIn }

    public var displayText: String {
        switch self {
        case .notSignedIn: return "未登录，云同步未启用"
        case .signedIn: return "已登录"
        case .needsReauthentication: return "登录已失效，需要重新登录"
        }
    }
}

/// 一轮重放的结果。所有计数都是显式的，界面与测试都靠它断言。
public struct CloudSyncRunResult: Equatable, Sendable {
    /// false 表示这一轮什么都没做（未登录 / 已有重放在跑）。
    public var didRun: Bool
    public var trigger: CloudSyncTrigger
    public var signInState: CloudSyncSignInState
    public var collectedChanges: Int
    public var pushedItems: Int
    public var acceptedItems: Int
    public var conflictedItems: Int
    public var rejectedItems: Int
    public var pulledChanges: Int
    public var appliedChanges: Int
    /// 因为「本地已删除」而拒绝服务端旧数据的条数。> 0 说明复活被挡住了。
    public var skippedLocalDeletions: Int
    public var cursor: String?
    /// 排了下一次重试的等待秒数；nil 表示没有排期。
    public var retryScheduledIn: TimeInterval?
    public var message: String

    public init(
        didRun: Bool,
        trigger: CloudSyncTrigger,
        signInState: CloudSyncSignInState,
        collectedChanges: Int = 0,
        pushedItems: Int = 0,
        acceptedItems: Int = 0,
        conflictedItems: Int = 0,
        rejectedItems: Int = 0,
        pulledChanges: Int = 0,
        appliedChanges: Int = 0,
        skippedLocalDeletions: Int = 0,
        cursor: String? = nil,
        retryScheduledIn: TimeInterval? = nil,
        message: String
    ) {
        self.didRun = didRun
        self.trigger = trigger
        self.signInState = signInState
        self.collectedChanges = collectedChanges
        self.pushedItems = pushedItems
        self.acceptedItems = acceptedItems
        self.conflictedItems = conflictedItems
        self.rejectedItems = rejectedItems
        self.pulledChanges = pulledChanges
        self.appliedChanges = appliedChanges
        self.skippedLocalDeletions = skippedLocalDeletions
        self.cursor = cursor
        self.retryScheduledIn = retryScheduledIn
        self.message = message
    }
}

/// 可注入的调度器。测试用 Manual 版本，生产用 Task 版本；Core 不依赖 Timer。
public protocol CloudSyncScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping () async -> Void)
}

/// 生产实现。用 Task.sleep 而不是 Timer：重放本身是 async，Timer 还要跨线程回调。
public final class TaskCloudSyncScheduler: CloudSyncScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, action: @escaping () async -> Void) {
        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await action()
        }
    }
}

/// 测试实现：只记录排期，不真的等待。测试里显式 runAll() 才会执行。
public final class ManualCloudSyncScheduler: CloudSyncScheduling {
    public private(set) var scheduledDelays: [TimeInterval] = []
    private var actions: [() async -> Void] = []

    public init() {}

    public func schedule(after delay: TimeInterval, action: @escaping () async -> Void) {
        scheduledDelays.append(delay)
        actions.append(action)
    }

    public var pendingCount: Int { actions.count }

    /// 按注册顺序执行所有已排期动作，并清空排期（避免重入时无限嵌套）。
    public func runAll() async {
        let pending = actions
        actions = []
        for action in pending {
            await action()
        }
    }
}

/// 指数退避。不做随机抖动：抖动会让「同一台设备重试间隔」不可预测，
/// 而这里的重试压力本来就来自单台设备，先保证可测试与可解释。
public struct CloudSyncBackoff: Equatable, Sendable {
    public var base: TimeInterval
    public var maximum: TimeInterval
    public var multiplier: Double

    public init(base: TimeInterval, maximum: TimeInterval, multiplier: Double = 2) {
        self.base = base
        self.maximum = maximum
        self.multiplier = multiplier
    }

    /// 默认：5 秒起，最长 5 分钟。
    public static let standard = CloudSyncBackoff(base: 5, maximum: 300)

    /// 第 attempt 次失败后应等待的秒数（attempt 从 1 开始）。
    public func delay(attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = base * pow(multiplier, Double(exponent))
        return min(raw, maximum)
    }
}

/// 待推送批次与拉取批次的默认大小。服务端上限是 500，这里留出余量。
public enum CloudSyncLimits {
    public static let pushBatch = 200
    public static let pullBatch = 200
    public static let maxPullPages = 20
}

public actor CloudSyncReplayer {

    /// 拉取游标在 sync_cursor 里的 scope。写成常量，避免各处拼字符串读不到同一行。
    public static let cursorScope = "cloud.sync.pull"

    private static let replayGuardKey = "cloud.sync.replay"

    private let store: DayCueStore
    private let client: SyncClientProtocol
    private let devices: DeviceRegistrationService?
    private let scheduler: CloudSyncScheduling
    private let tokenProvider: () -> String?
    /// 用于给「排期重试」取当前时刻。显式注入，测试里给固定时钟。
    private let clock: () -> Date
    private let backoff: CloudSyncBackoff

    private let guardrail = InFlightWriteGuard()

    /// 触发过 401 的令牌。当前令牌与它不同（用户重新登录了）时自动解除「需要重新登录」。
    private var failedToken: String?

    public init(
        store: DayCueStore,
        client: SyncClientProtocol,
        tokenProvider: @escaping () -> String?,
        clock: @escaping () -> Date,
        scheduler: CloudSyncScheduling = TaskCloudSyncScheduler(),
        devices: DeviceRegistrationService? = nil,
        backoff: CloudSyncBackoff = .standard
    ) {
        self.store = store
        self.client = client
        self.tokenProvider = tokenProvider
        self.clock = clock
        self.scheduler = scheduler
        self.devices = devices
        self.backoff = backoff
    }

    // MARK: - 状态

    private func normalizedToken() -> String? {
        let token = (tokenProvider() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public func currentSignInState() -> CloudSyncSignInState {
        guard let token = normalizedToken() else { return .notSignedIn }
        if let failedToken, failedToken == token {
            return .needsReauthentication(reason: "登录状态已失效，请重新登录。")
        }
        return .signedIn
    }

    public func isReplaying() async -> Bool {
        await guardrail.isInFlight(Self.replayGuardKey)
    }

    // MARK: - 重放

    public func replay(_ trigger: CloudSyncTrigger, at: Date) async -> CloudSyncRunResult {
        guard let token = normalizedToken() else {
            // 未登录：不报错、不弹窗、不发任何请求。
            return CloudSyncRunResult(
                didRun: false,
                trigger: trigger,
                signInState: .notSignedIn,
                message: "未登录，云同步未启用。"
            )
        }

        // 同一时刻只允许一个重放。actor 隔离挡不住 await 处的重入，必须显式互斥。
        let started = await guardrail.begin(Self.replayGuardKey)
        guard started else {
            return CloudSyncRunResult(
                didRun: false,
                trigger: trigger,
                signInState: currentSignInState(),
                message: "已经有一轮同步在进行中。"
            )
        }

        var result: CloudSyncRunResult
        do {
            result = try await perform(trigger: trigger, at: at, token: token)
        } catch let error as SyncClientError {
            result = handle(error: error, trigger: trigger, at: at)
        } catch {
            result = CloudSyncRunResult(
                didRun: true,
                trigger: trigger,
                signInState: currentSignInState(),
                message: "同步失败：\(error)"
            )
        }
        await guardrail.end(Self.replayGuardKey)
        return result
    }

    // MARK: - 主流程

    private func perform(trigger: CloudSyncTrigger, at: Date, token: String) async throws -> CloudSyncRunResult {
        // 1. 采集本地变更（合并同一条记录的多次修改）。
        let collector = CloudChangeCollector(store: store)
        let collected = try collector.collect(at: at)

        var deviceNote: String?

        // 2. 设备登记与能力上报。失败不阻塞数据同步，除非是令牌失效。
        if let devices {
            do {
                _ = try await devices.register(at: at)
            } catch let error as SyncClientError {
                if error.isUnauthorized {
                    failedToken = token
                    return CloudSyncRunResult(
                        didRun: true,
                        trigger: trigger,
                        signInState: currentSignInState(),
                        collectedChanges: collected,
                        message: error.userFacingMessage
                    )
                }
                deviceNote = error.userFacingMessage
            } catch {
                deviceNote = "设备登记失败：\(error)"
            }
        }

        // 3. 推送。逐条结算，一条失败不影响其余条目。
        let pushOutcome = try await pushPending(at: at, token: token)
        if pushOutcome.requiresReauthentication {
            return CloudSyncRunResult(
                didRun: true,
                trigger: trigger,
                signInState: currentSignInState(),
                collectedChanges: collected,
                pushedItems: pushOutcome.pushed,
                acceptedItems: pushOutcome.accepted,
                conflictedItems: pushOutcome.conflicted,
                rejectedItems: pushOutcome.rejected,
                retryScheduledIn: pushOutcome.retryScheduledIn,
                message: SyncClientError.unauthorized.userFacingMessage
            )
        }

        // 推送已经排了退避重试：这一轮不再拉取，避免同时排两次重试。
        if let retry = pushOutcome.retryScheduledIn {
            return CloudSyncRunResult(
                didRun: true,
                trigger: trigger,
                signInState: currentSignInState(),
                collectedChanges: collected,
                pushedItems: pushOutcome.pushed,
                acceptedItems: pushOutcome.accepted,
                conflictedItems: pushOutcome.conflicted,
                rejectedItems: pushOutcome.rejected,
                retryScheduledIn: retry,
                message: deviceNote ?? "网络不可用，已保留本地改动，稍后自动重试。"
            )
        }

        // 4. 拉取。失败绝不推进游标。
        let pullOutcome = try await pullChanges(at: at, token: token)

        var notes: [String] = []
        if let deviceNote { notes.append(deviceNote) }
        if pushOutcome.conflicted > 0 { notes.append("有 \(pushOutcome.conflicted) 条需要你裁决的冲突。") }
        if pushOutcome.rejected > 0 { notes.append("有 \(pushOutcome.rejected) 条被服务端拒绝，需要处理。") }
        if pullOutcome.skippedLocalDeletions > 0 { notes.append("本地已删除的 \(pullOutcome.skippedLocalDeletions) 条数据没有被服务端的旧数据复活。") }

        let retry = pushOutcome.retryScheduledIn ?? pullOutcome.retryScheduledIn

        return CloudSyncRunResult(
            didRun: true,
            trigger: trigger,
            signInState: currentSignInState(),
            collectedChanges: collected,
            pushedItems: pushOutcome.pushed,
            acceptedItems: pushOutcome.accepted,
            conflictedItems: pushOutcome.conflicted,
            rejectedItems: pushOutcome.rejected,
            pulledChanges: pullOutcome.pulled,
            appliedChanges: pullOutcome.applied,
            skippedLocalDeletions: pullOutcome.skippedLocalDeletions,
            cursor: pullOutcome.cursor,
            retryScheduledIn: retry,
            message: notes.isEmpty ? "同步完成。" : notes.joined(separator: " ")
        )
    }

    // MARK: - 错误处理

    private func handle(error: SyncClientError, trigger: CloudSyncTrigger, at: Date) async -> CloudSyncRunResult {
        switch error {
        case .notSignedIn:
            return CloudSyncRunResult(
                didRun: false,
                trigger: trigger,
                signInState: .notSignedIn,
                message: error.userFacingMessage
            )
        case .unauthorized:
            // 令牌失效：进入「需要重新登录」，不排重试。
            return CloudSyncRunResult(
                didRun: true,
                trigger: trigger,
                signInState: .needsReauthentication(reason: error.userFacingMessage),
                message: error.userFacingMessage
            )
        case .retryable:
            return CloudSyncRunResult(
                didRun: true,
                trigger: trigger,
                signInState: currentSignInState(),
                message: error.userFacingMessage
            )
        case .rejected, .unexpected:
            return CloudSyncRunResult(
                didRun: true,
                trigger: trigger,
                signInState: currentSignInState(),
                message: error.userFacingMessage
            )
        }
    }

    // MARK: - 推送

    private struct PushOutcome {
        var pushed = 0
        var accepted = 0
        var conflicted = 0
        var rejected = 0
        var requiresReauthentication = false
        var retryScheduledIn: TimeInterval?
    }

    private func pushPending(at: Date, token: String) async throws -> PushOutcome {
        var outcome = PushOutcome()
        let due = try store.dueSyncChanges(now: at, limit: CloudSyncLimits.pushBatch)
        guard !due.isEmpty else { return outcome }

        var items: [SyncPushItem] = []
        var rows: [SyncChangeRecord] = []
        for row in due {
            guard let item = try makePushItem(row) else {
                // 载荷解不出来：不推、也不丢，标成 blocked 等用户处理。
                try store.markSyncChangeBlocked(
                    entityType: row.entityType,
                    entityId: row.entityId,
                    reason: "本地载荷无法序列化，已跳过本次推送。"
                )
                continue
            }
            items.append(item)
            rows.append(row)
        }
        guard !items.isEmpty else { return outcome }

        outcome.pushed = items.count

        let results: [SyncPushResult]
        do {
            results = try await client.push(items)
        } catch let error as SyncClientError {
            switch error {
            case .unauthorized:
                failedToken = token
                outcome.requiresReauthentication = true
                return outcome
            case .retryable:
                // 网络失败：整批退避重试。条目仍是 pending，内容不会丢。
                outcome.retryScheduledIn = try scheduleRetry(for: rows, at: at, error: error.userFacingMessage)
                return outcome
            case .rejected, .unexpected, .notSignedIn:
                // 请求本身有问题：整批标 blocked，等用户处理，不做无意义重试。
                for row in rows {
                    try store.markSyncChangeBlocked(
                        entityType: row.entityType,
                        entityId: row.entityId,
                        reason: error.userFacingMessage
                    )
                    outcome.rejected += 1
                }
                return outcome
            }
        }

        for (index, row) in rows.enumerated() {
            let result = matchResult(results, row: row, index: index)
            guard let result else {
                // 服务端少回了一条：保守地当成可重试，不假装成功。
                _ = try scheduleRetry(for: [row], at: at, error: "服务端没有返回这条的结算结果。")
                outcome.retryScheduledIn = backoff.delay(attempt: row.attempt + 1)
                continue
            }

            if result.isAccepted {
                try store.markSyncChangeSynced(
                    entityType: row.entityType,
                    entityId: row.entityId,
                    serverVersion: result.version ?? row.baseVersion,
                    contentHash: row.contentHash,
                    at: at
                )
                outcome.accepted += 1
            } else if result.isConflict {
                try storeConflict(row: row, result: result, at: at)
                outcome.conflicted += 1
            } else if result.isRejected {
                try store.markSyncChangeBlocked(
                    entityType: row.entityType,
                    entityId: row.entityId,
                    reason: result.reason ?? result.outcome
                )
                outcome.rejected += 1
            } else {
                // 没见过的结算结果：不猜，标 blocked 并在原因里写清原值。
                try store.markSyncChangeBlocked(
                    entityType: row.entityType,
                    entityId: row.entityId,
                    reason: "未识别的结算结果：" + result.outcome
                )
                outcome.rejected += 1
            }
        }
        return outcome
    }

    private func makePushItem(_ row: SyncChangeRecord) throws -> SyncPushItem? {
        var payload: SyncEntityPayload?
        if row.operation == .upsert {
            guard let json = row.payloadJSON, let decoded = try? SyncPayloadCodec.decode(json) else {
                return nil
            }
            payload = decoded
        }
        return SyncPushItem(
            type: row.entityType.rawValue,
            id: row.entityId,
            baseVersion: row.baseVersion,
            payload: payload,
            updatedAt: row.updatedAt,
            deleted: row.operation == .delete
        )
    }

    /// 服务端保证结果与入参同序，但客户端仍然按 id 核对一次：
    /// 位置一旦错位，把别人的冲突记到这条上会造成静默的数据错配。
    private func matchResult(_ results: [SyncPushResult], row: SyncChangeRecord, index: Int) -> SyncPushResult? {
        if index < results.count {
            let candidate = results[index]
            if candidate.id == row.entityId, candidate.type == row.entityType.rawValue {
                return candidate
            }
        }
        return results.first { $0.id == row.entityId && $0.type == row.entityType.rawValue }
    }

    private func storeConflict(row: SyncChangeRecord, result: SyncPushResult, at: Date) throws {
        let serverPayloadJSON = try encodeServerPayload(result.serverPayload)
        let local = SyncConflictPresenter.dictionary(row.payloadJSON)
        let server = SyncConflictPresenter.dictionary(serverPayloadJSON)
        var fields = SyncConflictFields.conflictedFields(for: row.entityType, local: local, server: server)
        if fields.isEmpty {
            // 服务端说冲突但内容一致（极少见：例如服务端墓碑）。
            // 仍然让用户确认，不自动选边。
            fields = SyncConflictFields.groups(for: row.entityType).map(\.field)
        }
        try store.upsertSyncConflict(SyncConflictRecord(
            entityType: row.entityType,
            entityId: row.entityId,
            serverVersion: result.serverVersion ?? 0,
            baseVersion: row.baseVersion,
            serverDeleted: result.serverDeleted ?? false,
            serverPayloadJSON: serverPayloadJSON,
            localPayloadJSON: row.payloadJSON,
            conflictingFields: fields,
            resolvedFields: [],
            choseLocal: false,
            detectedAt: DayCueClock.nowUTCString(date: at)
        ))
    }

    private func encodeServerPayload(_ value: SyncJSONValue?) throws -> String? {
        guard let value else { return nil }
        return try DayCueJSON.encodeToString(value)
    }

    // MARK: - 拉取

    private struct PullOutcome {
        var pulled = 0
        var applied = 0
        var skippedLocalDeletions = 0
        var cursor: String?
        var retryScheduledIn: TimeInterval?
    }

    private func pullChanges(at: Date, token: String) async throws -> PullOutcome {
        var outcome = PullOutcome()
        var cursor = try store.syncCursor(scope: Self.cursorScope)
        outcome.cursor = cursor

        var page = 0
        while page < CloudSyncLimits.maxPullPages {
            let fetched: SyncPullPage
            do {
                fetched = try await client.pull(cursor: cursor, limit: CloudSyncLimits.pullBatch)
            } catch let error as SyncClientError {
                if error.isUnauthorized {
                    failedToken = token
                    return outcome
                }
                if error.isRetryable {
                    // 拉取失败绝不推进游标：游标推进了就会永久跳过这段变更。
                    outcome.retryScheduledIn = try scheduleRetry(
                        for: try store.dueSyncChanges(now: at, limit: CloudSyncLimits.pushBatch),
                        at: at,
                        error: error.userFacingMessage
                    )
                    return outcome
                }
                return outcome
            }

            outcome.pulled += fetched.changes.count
            let applied = try apply(changes: fetched.changes, at: at)
            outcome.applied += applied.applied
            outcome.skippedLocalDeletions += applied.skippedLocalDeletions

            // 整页应用成功之后才推进游标。
            try store.setSyncCursor(scope: Self.cursorScope, cursor: fetched.cursor)
            cursor = fetched.cursor
            outcome.cursor = fetched.cursor
            page += 1
            if !fetched.hasMore { break }
        }
        return outcome
    }

    private struct ApplyOutcome {
        var applied = 0
        var skippedLocalDeletions = 0
    }

    private func apply(changes: [SyncPullChange], at: Date) throws -> ApplyOutcome {
        var outcome = ApplyOutcome()
        for change in changes {
            // 客户端没建模的实体类型直接跳过：不认识的类型不能删也不能覆盖。
            guard let type = change.entityType else { continue }

            let queueRow = try store.syncChange(entityType: type, entityId: change.id)
            let locallyDeleted = try store.cloudLocalDeletionState(entityType: type, entityId: change.id) == true

            if change.isDeletion {
                // 本地有还没推上去的修改，服务端却已删除 -> 冲突，绝不自动删本地。
                if let queueRow, queueRow.state != .synced, queueRow.operation == .upsert {
                    try storePullConflict(change: change, row: queueRow, serverDeleted: true, at: at)
                    outcome.applied += 1
                    continue
                }
                try store.applyCloudDeletion(entityType: type, entityId: change.id, at: at)
                try store.markSyncChangeSynced(
                    entityType: type,
                    entityId: change.id,
                    serverVersion: change.version,
                    contentHash: SyncPayloadCodec.changeHash(operation: .delete, payloadJSON: nil),
                    at: at
                )
                outcome.applied += 1
                continue
            }

            // 关键：用户已经删除的数据，同步绝不能把它复活。
            if locallyDeleted {
                outcome.skippedLocalDeletions += 1
                continue
            }

            // 冲突已经开着就等用户，不覆盖。
            if let queueRow, queueRow.state == .conflict { continue }

            // 本地有未推送修改且服务端版本更靠前 -> 双方都改过 -> 冲突。
            if let queueRow, queueRow.state != .synced, queueRow.operation == .upsert,
               change.version > queueRow.baseVersion {
                try storePullConflict(change: change, row: queueRow, serverDeleted: false, at: at)
                outcome.applied += 1
                continue
            }

            guard let payloadJSON = encodeServerPayload(change.payload),
                  let payload = try? SyncPayloadCodec.decode(payloadJSON) else {
                // 载荷解不出来：不写本地，但游标继续推进，否则永远卡在这一页。
                continue
            }
            try store.applyCloudPayload(
                entityType: type,
                entityId: change.id,
                payload: payload,
                updatedAt: normalizedTimestamp(change.updatedAt, at: at)
            )
            // 用「写回本地之后读回来的内容」作为指纹：只有它才能保证采集器
            // 下一轮不会把这次拉取当成新的本地变更再推回去。
            let refreshed = try store.cloudLocalEntity(entityType: type, entityId: change.id)
            let hash = (try? SyncPayloadCodec.contentHash(refreshed?.payload ?? payload))
                ?? SyncPayloadCodec.changeHash(operation: .upsert, payloadJSON: payloadJSON)
            try store.markSyncChangeSynced(
                entityType: type,
                entityId: change.id,
                serverVersion: change.version,
                contentHash: hash,
                at: at
            )
            outcome.applied += 1
        }
        return outcome
    }

    private func storePullConflict(
        change: SyncPullChange,
        row: SyncChangeRecord,
        serverDeleted: Bool,
        at: Date
    ) throws {
        let serverPayloadJSON = try encodeServerPayload(change.payload)
        let local = SyncConflictPresenter.dictionary(row.payloadJSON)
        let server = SyncConflictPresenter.dictionary(serverPayloadJSON)
        var fields = SyncConflictFields.conflictedFields(for: row.entityType, local: local, server: server)
        if fields.isEmpty {
            fields = SyncConflictFields.groups(for: row.entityType).map(\.field)
        }
        try store.upsertSyncConflict(SyncConflictRecord(
            entityType: row.entityType,
            entityId: row.entityId,
            serverVersion: change.version,
            baseVersion: row.baseVersion,
            serverDeleted: serverDeleted,
            serverPayloadJSON: serverPayloadJSON,
            localPayloadJSON: row.payloadJSON,
            conflictingFields: fields,
            resolvedFields: [],
            choseLocal: false,
            detectedAt: DayCueClock.nowUTCString(date: at)
        ))
    }

    /// 服务端时间戳（RFC3339Nano）归一成秒精度，与本地既有格式保持一致。
    private func normalizedTimestamp(_ raw: String, at: Date) -> String {
        guard !raw.isEmpty else { return DayCueClock.nowUTCString(date: at) }
        if let date = RFC3339.date(fromUTC: raw) {
            return DayCueClock.nowUTCString(date: date)
        }
        return raw
    }

    // MARK: - 退避

    /// 给一批条目排下一次重试，并排一次重放。返回等待秒数。
    ///
    /// 即使 rows 为空也会排（拉取失败时没有队列条目可退避，但重放本身要重来）。
    @discardableResult
    private func scheduleRetry(
        for rows: [SyncChangeRecord],
        at: Date,
        error: String
    ) throws -> TimeInterval {
        let maxAttempt = rows.map(\.attempt).max() ?? 0
        let delay = backoff.delay(attempt: maxAttempt + 1)
        let nextRetryAt = DayCueClock.nowUTCString(date: at.addingTimeInterval(delay))
        for row in rows {
            try store.scheduleSyncChangeRetry(
                entityType: row.entityType,
                entityId: row.entityId,
                attempt: row.attempt + 1,
                nextRetryAt: nextRetryAt,
                error: error
            )
        }
        scheduleReplay(after: delay)
        return delay
    }

    private func scheduleReplay(after delay: TimeInterval) {
        scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            let now = await self.currentClock()
            _ = await self.replay(.retry, at: now)
        }
    }

    private func currentClock() -> Date { clock() }
}
