import Foundation
import XCTest
@testable import DayCueCore

/// 云同步链路测试。
///
/// 所有时间都显式传入固定基准（now），Core 不读系统时钟；
/// 网络全部走假客户端，断言「调用了几次、推了什么载荷」。
final class CloudSyncTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private var nowISO: String { DayCueClock.nowUTCString(date: now) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "daycue-cloudsync-" + UUID().uuidString
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = try DayCueStore(baseDirectory: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        store = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    private func makeReplayer(
        client: SyncClientProtocol,
        scheduler: CloudSyncScheduling = ManualCloudSyncScheduler(),
        token: String? = "test-token",
        devices: DeviceRegistrationService? = nil,
        backoff: CloudSyncBackoff = .standard
    ) -> CloudSyncReplayer {
        let fixedToken = token
        let fixedNow = now
        return CloudSyncReplayer(
            store: store,
            client: client,
            tokenProvider: { fixedToken },
            clock: { fixedNow },
            scheduler: scheduler,
            devices: devices,
            backoff: backoff
        )
    }

    @discardableResult
    private func insertTask(id: String, title: String, secondOffset: TimeInterval = 0) throws -> TaskRecord {
        let stamp = DayCueClock.nowUTCString(date: now.addingTimeInterval(secondOffset))
        return try store.insertTask(TaskRecord(id: id, title: title, createdAt: stamp, updatedAt: stamp))
    }

    // MARK: - 1. 变更入队

    func testCollectorCoalescesRepeatedEditsIntoOneQueueRow() throws {
        try insertTask(id: "task_coalesce", title: "第一版")
        let collector = CloudChangeCollector(store: store)

        XCTAssertEqual(try collector.collect(at: now), 1)

        var edited = try XCTUnwrap(try store.task(id: "task_coalesce"))
        edited.title = "第二版"
        try store.updateTask(edited)
        XCTAssertEqual(try collector.collect(at: now), 1, "同一条记录再次修改只应改写同一行")

        let rows = try store.syncChanges(entityType: .task)
        XCTAssertEqual(rows.count, 1)
        let payload = try XCTUnwrap(rows.first?.payloadJSON)
        XCTAssertTrue(payload.contains("第二版"), "队列里必须是合并后的最新内容")
        XCTAssertFalse(payload.contains("第一版"))
    }

    func testCollectorIsIdempotentWhenNothingChanged() throws {
        try insertTask(id: "task_idem", title: "没变")
        let collector = CloudChangeCollector(store: store)

        XCTAssertEqual(try collector.collect(at: now), 1)
        XCTAssertEqual(try collector.collect(at: now), 0, "内容没变时重复采集必须什么都不做")
        XCTAssertEqual(try store.syncChanges(entityType: .task).count, 1)
    }

    func testCollectorEnqueuesDeleteAndWritesTombstone() throws {
        try insertTask(id: "task_del", title: "待删")
        let collector = CloudChangeCollector(store: store)
        try collector.collect(at: now)

        try store.softDeleteTask(id: "task_del")
        XCTAssertEqual(try collector.collect(at: now), 1)

        let row = try XCTUnwrap(try store.syncChange(entityType: .task, entityId: "task_del"))
        XCTAssertEqual(row.operation, .delete)
        XCTAssertNil(row.payloadJSON, "删除只推墓碑，不推内容")

        let tombstones = try store.syncTombstones(entityType: "task")
        XCTAssertTrue(tombstones.contains { $0.entityId == "task_del" }, "删除必须写 sync_tombstone")
    }

    func testNoteChangesAreCollected() throws {
        _ = try store.insertNote(NoteRecord(
            id: "note_1",
            title: "笔记标题",
            body: "正文",
            createdAt: nowISO,
            updatedAt: nowISO
        ))
        let collector = CloudChangeCollector(store: store)
        XCTAssertEqual(try collector.collect(at: now), 1)
        let row = try XCTUnwrap(try store.syncChange(entityType: .note, entityId: "note_1"))
        XCTAssertEqual(row.operation, .upsert)
        XCTAssertTrue((row.payloadJSON ?? "").contains("笔记标题"))
    }

    // MARK: - 2. 自动重放真的调用 SyncClient

    func testReplayPushesLocalChangeThroughSyncClient() async throws {
        try insertTask(id: "task_push", title: "推我")
        let fake = FakeSyncClient()
        fake.autoAccept = true
        let replayer = makeReplayer(client: fake)

        let result = await replayer.replay(.localChange, at: now)

        XCTAssertTrue(result.didRun)
        XCTAssertEqual(result.collectedChanges, 1)
        XCTAssertEqual(fake.pushCalls.count, 1, "自动重放必须真的调用 SyncClient.push")
        XCTAssertEqual(fake.pushCalls[0].count, 1)
        XCTAssertEqual(fake.pushCalls[0][0].id, "task_push")
        XCTAssertEqual(fake.pushCalls[0][0].payload?.title, "推我")
        XCTAssertEqual(fake.pushCalls[0][0].deleted, false)
        XCTAssertEqual(result.acceptedItems, 1)
    }

    func testReplayMakesNoRequestWhenNotSignedIn() async throws {
        try insertTask(id: "task_offline", title: "未登录")
        let fake = FakeSyncClient()
        fake.autoAccept = true
        let replayer = makeReplayer(client: fake, token: nil)

        let result = await replayer.replay(.appForeground, at: now)

        XCTAssertFalse(result.didRun)
        XCTAssertEqual(result.signInState, .notSignedIn)
        XCTAssertEqual(fake.totalCalls, 0, "未登录时不允许发起任何网络请求")
        XCTAssertEqual(try store.syncChangeCount(state: .pending), 1, "变更仍留在队列里，等登录后再推")
    }

    // MARK: - 3. 游标

    func testPullFailureDoesNotAdvanceCursor() async throws {
        try insertTask(id: "task_cursor", title: "游标")
        try store.setSyncCursor(scope: CloudSyncReplayer.cursorScope, cursor: "7")

        let fake = FakeSyncClient()
        fake.autoAccept = true
        fake.pullError = SyncClientError.retryable("offline")
        let scheduler = ManualCloudSyncScheduler()
        let replayer = makeReplayer(client: fake, scheduler: scheduler)

        let result = await replayer.replay(.manual, at: now)

        XCTAssertEqual(try store.syncCursor(scope: CloudSyncReplayer.cursorScope), "7", "pull 失败绝不推进游标")
        XCTAssertNotNil(result.retryScheduledIn)
        XCTAssertEqual(scheduler.scheduledDelays.count, 1, "失败后必须排一次退避重试")
    }

    func testPullAdvancesCursorOnSuccess() async throws {
        let fake = FakeSyncClient()
        fake.autoAccept = true
        fake.pullPages = [SyncPullPage(changes: [], cursor: "42")]
        let replayer = makeReplayer(client: fake)

        _ = await replayer.replay(.manual, at: now)

        XCTAssertEqual(try store.syncCursor(scope: CloudSyncReplayer.cursorScope), "42")
    }

    // MARK: - 4. 逐条结算

    func testPushPartialFailureDoesNotResendAcceptedItem() async throws {
        try insertTask(id: "task_ok", title: "成功", secondOffset: 0)
        try insertTask(id: "task_bad", title: "失败", secondOffset: 1)

        let fake = FakeSyncClient()
        // 服务端只回了 task_ok 的结算结果：task_bad 视为未结算，必须保留待重试。
        fake.pushResults = [SyncPushResult(type: "task", id: "task_ok", outcome: "accepted", version: 11)]
        let replayer = makeReplayer(client: fake)

        _ = await replayer.replay(.manual, at: now)

        XCTAssertEqual(try store.syncChange(entityType: .task, entityId: "task_ok")?.state, SyncChangeState.synced)
        let bad = try XCTUnwrap(try store.syncChange(entityType: .task, entityId: "task_bad"))
        XCTAssertEqual(bad.state, .pending)
        XCTAssertEqual(bad.attempt, 1)

        // 退避到点后重放：只应重发失败的那一条。
        fake.pushResults = [SyncPushResult(type: "task", id: "task_bad", outcome: "accepted", version: 12)]
        _ = await replayer.replay(.retry, at: now.addingTimeInterval(60))

        XCTAssertEqual(fake.pushCalls.count, 2)
        XCTAssertEqual(fake.pushCalls[1].map(\.id), ["task_bad"], "已成功的条目不得重发")
    }

    func testRejectedItemIsMarkedBlockedAndNotAutoRetried() async throws {
        try insertTask(id: "task_rej", title: "被拒")
        let fake = FakeSyncClient()
        fake.pushResults = [SyncPushResult(type: "task", id: "task_rej", outcome: "rejected", reason: "缺少实体类型")]
        let scheduler = ManualCloudSyncScheduler()
        let replayer = makeReplayer(client: fake, scheduler: scheduler)

        let result = await replayer.replay(.manual, at: now)

        XCTAssertEqual(result.rejectedItems, 1)
        XCTAssertEqual(try store.syncChange(entityType: .task, entityId: "task_rej")?.state, SyncChangeState.blocked)
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty, "明确拒绝不进入重试循环")
    }

    // MARK: - 5. 冲突

    func testConflictIsStoredForUserDecisionWithoutChoosingSide() async throws {
        try insertTask(id: "task_conf", title: "本地标题")
        let fake = FakeSyncClient()
        fake.pushResults = [SyncPushResult(
            type: "task",
            id: "task_conf",
            outcome: "conflict",
            serverVersion: 3,
            serverPayload: .object(["title": .string("服务端标题")]),
            reason: "版本冲突"
        )]
        let replayer = makeReplayer(client: fake)

        let result = await replayer.replay(.manual, at: now)

        XCTAssertEqual(result.conflictedItems, 1)
        XCTAssertEqual(try store.syncConflictCount(), 1)
        XCTAssertEqual(try store.syncChange(entityType: .task, entityId: "task_conf")?.state, SyncChangeState.conflict)
        XCTAssertEqual(try store.task(id: "task_conf")?.title, "本地标题", "冲突绝不能被自动选边")

        let conflict = try XCTUnwrap(try store.syncConflict(entityType: .task, entityId: "task_conf"))
        XCTAssertTrue(conflict.conflictingFields.contains(.title))
        XCTAssertEqual(conflict.serverVersion, 3)
        XCTAssertFalse(conflict.isFullyResolved)
    }

    func testConflictPlanUsesReconciliationTypesAndMarksEveryFieldConflicted() async throws {
        try insertTask(id: "task_plan", title: "本地")
        let fake = FakeSyncClient()
        fake.pushResults = [SyncPushResult(
            type: "task",
            id: "task_plan",
            outcome: "conflict",
            serverVersion: 2,
            serverPayload: .object(["title": .string("服务端")])
        )]
        let replayer = makeReplayer(client: fake)
        _ = await replayer.replay(.manual, at: now)

        let plan = SyncConflictPresenter.plan(conflicts: try store.syncConflicts(), generatedAt: nowISO)

        XCTAssertEqual(plan.conflictedEntityCount, 1)
        XCTAssertGreaterThan(plan.conflictedFieldCount, 0)
        let decision = try XCTUnwrap(plan.conflicts.first)
        XCTAssertEqual(decision.entityId, "task_plan")
        XCTAssertTrue(decision.conflictedDifferences.allSatisfy(\.isConflict), "每一项都必须交给用户裁决")
        XCTAssertTrue(decision.conflictedDifferences.allSatisfy { $0.preferredSource == nil })
    }

    func testConflictResolutionKeepingLocalRequeuesWithServerVersion() async throws {
        try insertTask(id: "task_res", title: "本地版")
        let fake = FakeSyncClient()
        fake.pushResults = [SyncPushResult(
            type: "task",
            id: "task_res",
            outcome: "conflict",
            serverVersion: 3,
            serverPayload: .object(["title": .string("服务端版")])
        )]
        let replayer = makeReplayer(client: fake)
        _ = await replayer.replay(.manual, at: now)

        let conflict = try XCTUnwrap(try store.syncConflict(entityType: .task, entityId: "task_res"))
        let resolver = CloudConflictResolver(store: store)
        var last: CloudConflictResolutionOutcome?
        for field in conflict.conflictingFields {
            last = try resolver.record(
                ReconciliationResolution(entityId: "task_res", field: field, source: .local),
                at: now
            )
        }

        XCTAssertEqual(last, .appliedKeptLocal)
        XCTAssertEqual(try store.task(id: "task_res")?.title, "本地版")
        XCTAssertNil(try store.syncConflict(entityType: .task, entityId: "task_res"))
        let row = try XCTUnwrap(try store.syncChange(entityType: .task, entityId: "task_res"))
        XCTAssertEqual(row.state, SyncChangeState.pending)
        XCTAssertEqual(row.baseVersion, 3, "裁决后必须用服务端版本作为新的基准，下一次推送才会被接受")
    }

    func testConflictResolutionAcceptingServerDeletionDeletesLocal() async throws {
        try insertTask(id: "task_gone", title: "服务端已删")
        let fake = FakeSyncClient()
        fake.pushResults = [SyncPushResult(
            type: "task",
            id: "task_gone",
            outcome: "conflict",
            serverVersion: 4,
            serverDeleted: true
        )]
        let replayer = makeReplayer(client: fake)
        _ = await replayer.replay(.manual, at: now)

        let conflict = try XCTUnwrap(try store.syncConflict(entityType: .task, entityId: "task_gone"))
        XCTAssertTrue(conflict.serverDeleted)

        let resolver = CloudConflictResolver(store: store)
        for field in conflict.conflictingFields {
            _ = try resolver.record(
                ReconciliationResolution(entityId: "task_gone", field: field, source: .external),
                at: now
            )
        }

        XCTAssertNotNil(try store.task(id: "task_gone")?.deletedAt)
        XCTAssertNil(try store.syncConflict(entityType: .task, entityId: "task_gone"))
    }

    // MARK: - 6. 删除传播 / 不复活

    func testLocalDeletionIsNotResurrectedByStaleServerPayload() async throws {
        try insertTask(id: "task_zombie", title: "会复活吗")
        let fake = FakeSyncClient()
        fake.autoAccept = true
        let replayer = makeReplayer(client: fake)

        // 先同步一次，建立服务端版本。
        _ = await replayer.replay(.manual, at: now)
        // 再本地删除并推墓碑。
        try store.softDeleteTask(id: "task_zombie")
        _ = await replayer.replay(.manual, at: now)
        XCTAssertEqual(try store.syncChange(entityType: .task, entityId: "task_zombie")?.operation, SyncChangeOperation.delete)

        // 服务端仍然返回旧版本的任务内容（模拟竞态/旧数据）。
        fake.pullPages = [SyncPullPage(
            changes: [SyncPullChange(
                type: "task",
                id: "task_zombie",
                version: 1,
                updatedAt: nowISO,
                payload: .object(["title": .string("旧标题")])
            )],
            cursor: "9"
        )]

        let result = await replayer.replay(.manual, at: now)

        XCTAssertEqual(result.skippedLocalDeletions, 1)
        XCTAssertNotNil(try store.task(id: "task_zombie")?.deletedAt, "用户删掉的数据绝不能被同步复活")
    }

    func testPullAppliesRemoteDeletionToLocal() async throws {
        try insertTask(id: "task_remote_del", title: "远端删我")
        let fake = FakeSyncClient()
        fake.autoAccept = true
        let replayer = makeReplayer(client: fake)
        _ = await replayer.replay(.manual, at: now)

        fake.pullPages = [SyncPullPage(
            changes: [SyncPullChange(type: "task", id: "task_remote_del", version: 8, updatedAt: nowISO, tombstone: true)],
            cursor: "8"
        )]
        _ = await replayer.replay(.manual, at: now)

        XCTAssertNotNil(try store.task(id: "task_remote_del")?.deletedAt, "服务端墓碑必须在本地生效")
    }

    // MARK: - 7. 拉取应用

    func testPullAppliesRemoteUpsertToLocal() async throws {
        let fake = FakeSyncClient()
        fake.autoAccept = true
        fake.pullPages = [SyncPullPage(
            changes: [SyncPullChange(
                type: "task",
                id: "task_remote_new",
                version: 5,
                updatedAt: nowISO,
                payload: .object(["title": .string("服务端新建"), "status": .string("open")])
            )],
            cursor: "5"
        )]
        let replayer = makeReplayer(client: fake)

        let result = await replayer.replay(.manual, at: now)

        XCTAssertEqual(result.appliedChanges, 1)
        XCTAssertEqual(try store.task(id: "task_remote_new")?.title, "服务端新建")
    }

    func testPullIgnoresUnknownEntityTypes() async throws {
        let fake = FakeSyncClient()
        fake.autoAccept = true
        fake.pullPages = [SyncPullPage(
            changes: [SyncPullChange(type: "place", id: "place_1", version: 1, updatedAt: nowISO, payload: .object(["name": .string("图书馆")]))],
            cursor: "1"
        )]
        let replayer = makeReplayer(client: fake)

        let result = await replayer.replay(.manual, at: now)

        XCTAssertEqual(result.appliedChanges, 0, "没建模的实体类型既不能删也不能覆盖")
        XCTAssertEqual(try store.syncCursor(scope: CloudSyncReplayer.cursorScope), "1", "跳过不代表不推进游标")
    }

    // MARK: - 8. 失败分类与退避

    func testRetryablePushFailureSchedulesBackoffAndKeepsItemPending() async throws {
        try insertTask(id: "task_retry", title: "重试")
        let fake = FakeSyncClient()
        fake.pushError = SyncClientError.retryable("offline")
        let scheduler = ManualCloudSyncScheduler()
        let replayer = makeReplayer(client: fake, scheduler: scheduler)

        let result = await replayer.replay(.manual, at: now)

        XCTAssertEqual(result.retryScheduledIn, 5, "第一次失败等 5 秒（base）")
        XCTAssertEqual(scheduler.scheduledDelays, [5])
        let row = try XCTUnwrap(try store.syncChange(entityType: .task, entityId: "task_retry"))
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.attempt, 1)
        XCTAssertNotNil(row.nextRetryAt)
    }

    func testBackoffGrowsAndIsCapped() {
        let backoff = CloudSyncBackoff(base: 5, maximum: 20)
        XCTAssertEqual(backoff.delay(attempt: 1), 5)
        XCTAssertEqual(backoff.delay(attempt: 2), 10)
        XCTAssertEqual(backoff.delay(attempt: 3), 20)
        XCTAssertEqual(backoff.delay(attempt: 9), 20, "必须封顶，不能无限增长")
    }

    func testUnauthorizedEntersReauthenticationWithoutSchedulingRetry() async throws {
        try insertTask(id: "task_401", title: "令牌失效")
        let fake = FakeSyncClient()
        fake.pushError = SyncClientError.unauthorized
        let scheduler = ManualCloudSyncScheduler()
        let replayer = makeReplayer(client: fake, scheduler: scheduler)

        let result = await replayer.replay(.manual, at: now)

        guard case .needsReauthentication = result.signInState else {
            return XCTFail("401 必须进入需要重新登录，实际是 \(result.signInState)")
        }
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty, "令牌失效不允许进入重试循环")
        XCTAssertEqual(try store.syncChange(entityType: .task, entityId: "task_401")?.state, SyncChangeState.pending, "内容保留，重新登录后可继续")
        guard case .needsReauthentication = await replayer.currentSignInState() else {
            return XCTFail("重放器的登录状态也必须是需要重新登录")
        }
    }

    func testSignInStateFollowsToken() async throws {
        let fake = FakeSyncClient()
        let signedOut = makeReplayer(client: fake, token: nil)
        XCTAssertEqual(await signedOut.currentSignInState(), .notSignedIn)

        let signedIn = makeReplayer(client: fake, token: "abc")
        XCTAssertEqual(await signedIn.currentSignInState(), .signedIn)
    }

    // MARK: - 9. 并发互斥

    func testConcurrentReplaysAllowOnlyOneWinner() async throws {
        try insertTask(id: "task_mutex", title: "互斥")
        let fake = FakeSyncClient()
        fake.autoAccept = true
        fake.holdPush = true
        let replayer = makeReplayer(client: fake)

        async let first = replayer.replay(.manual, at: now)
        // 等第一条真正进入 push（说明它已经持有互斥）。
        var spins = 0
        while fake.pushCalls.isEmpty, spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        let second = await replayer.replay(.manual, at: now)
        XCTAssertFalse(second.didRun, "同一时刻只允许一个重放")

        fake.releasePush()
        let firstResult = await first
        XCTAssertTrue(firstResult.didRun)
    }

    // MARK: - 10. 设备能力上报

    func testUnknownCapabilitiesAreOmittedFromWireFormat() {
        XCTAssertTrue(DeviceCapabilities.unknown.wire.isEmpty, "能力未知时如实省略，不能假装支持或假装不支持")
        let known = DeviceCapabilities(notifications: true, speechTranscription: false)
        XCTAssertEqual(known.wire, ["notifications": true, "speech_transcription": false])

        let decoded = DeviceCapabilities(wire: ["notifications": true])
        XCTAssertEqual(decoded.notifications, true)
        XCTAssertNil(decoded.preciseLocation, "没上报的能力必须是未知，而不是 false")
        XCTAssertTrue(decoded.displaySummary.contains("精确定位未知"))
    }

    func testDeviceRegistrationPersistsServerIDAndSkipsWhenUnchanged() async throws {
        let fake = FakeSyncClient()
        let capabilities = StubCapabilities(value: DeviceCapabilities(notifications: true))
        let service = DeviceRegistrationService(
            store: store,
            client: fake,
            identity: StubIdentity(deviceName: "测试机"),
            capabilities: capabilities
        )

        let response = try await service.register(at: now)
        XCTAssertEqual(fake.deviceCalls.count, 1)
        XCTAssertTrue(response.id.hasPrefix("dev_"))
        XCTAssertEqual(fake.deviceCalls[0].platform, "ios")
        XCTAssertEqual(fake.deviceCalls[0].capabilities, ["notifications": true])
        XCTAssertEqual(try store.localDeviceSnapshot()?.id, response.id)

        // 能力与令牌都没变：不重复登记，避免每次重放都打一次设备接口。
        let second = try await service.register(at: now)
        XCTAssertEqual(fake.deviceCalls.count, 1)
        XCTAssertEqual(second.id, response.id)
    }

    func testDeviceRegistrationRetriesWithSameIDAfterFailure() async throws {
        let fake = FakeSyncClient()
        fake.deviceError = SyncClientError.retryable("offline")
        let service = DeviceRegistrationService(
            store: store,
            client: fake,
            identity: StubIdentity(deviceName: "测试机"),
            capabilities: StubCapabilities(value: .unknown)
        )

        do {
            _ = try await service.register(at: now)
            XCTFail("网络失败应当抛出")
        } catch {
            // 预期：失败。
        }
        let firstID = try XCTUnwrap(try store.localDeviceSnapshot()?.id)

        fake.deviceError = nil
        _ = try await service.register(at: now)
        XCTAssertEqual(fake.deviceCalls.count, 2)
        XCTAssertEqual(fake.deviceCalls[0].id, firstID, "失败重试必须复用同一个设备 ID，避免留下幽灵设备")
        XCTAssertEqual(fake.deviceCalls[1].id, firstID)
    }

    func testUnauthenticatedReplayReportsNotSignedInRatherThanFailure() async throws {
        let fake = FakeSyncClient()
        let replayer = makeReplayer(client: fake, token: nil)
        let result = await replayer.replay(.manual, at: now)
        XCTAssertEqual(result.signInState.displayText, "未登录，云同步未启用")
        XCTAssertEqual(result.message, "未登录，云同步未启用。")
    }
}

// MARK: - 假客户端与桩

/// 可编排的假同步客户端：记录每一次调用，按需返回结果或抛错。
private final class FakeSyncClient: SyncClientProtocol {

    var autoAccept = false
    var nextVersion: Int64 = 1
    var pushResults: [SyncPushResult] = []
    var pushError: Error?
    var pullPages: [SyncPullPage] = []
    var pullError: Error?
    var deviceResponse: SyncDeviceResponse?
    var deviceError: Error?

    /// 阻断 push 直到测试放行，用来验证并发互斥。
    var holdPush = false
    private var pushGate: CheckedContinuation<Void, Never>?

    private(set) var pushCalls: [[SyncPushItem]] = []
    private(set) var pullCalls: [(cursor: String?, limit: Int)] = []
    private(set) var deviceCalls: [SyncDeviceRegistration] = []

    var totalCalls: Int { pushCalls.count + pullCalls.count + deviceCalls.count }

    func push(_ items: [SyncPushItem]) async throws -> [SyncPushResult] {
        pushCalls.append(items)
        if holdPush {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pushGate = continuation
            }
        }
        if let pushError { throw pushError }
        if autoAccept {
            return items.map { item in
                let version = nextVersion
                nextVersion += 1
                return SyncPushResult(type: item.type, id: item.id, outcome: "accepted", version: version)
            }
        }
        return pushResults
    }

    func releasePush() {
        pushGate?.resume()
        pushGate = nil
    }

    func pull(cursor: String?, limit: Int) async throws -> SyncPullPage {
        pullCalls.append((cursor, limit))
        if let pullError { throw pullError }
        guard !pullPages.isEmpty else {
            return SyncPullPage(changes: [], cursor: cursor ?? "0", hasMore: false)
        }
        return pullPages.removeFirst()
    }

    func registerDevice(_ registration: SyncDeviceRegistration) async throws -> SyncDeviceResponse {
        deviceCalls.append(registration)
        if let deviceError { throw deviceError }
        if let deviceResponse { return deviceResponse }
        return SyncDeviceResponse(
            id: registration.id ?? "dev_server_generated",
            platform: registration.platform,
            name: registration.name,
            capabilities: registration.capabilities,
            lastSeenAt: "2026-10-12T00:00:00Z",
            createdAt: "2026-10-12T00:00:00Z",
            updatedAt: "2026-10-12T00:00:00Z"
        )
    }
}

private final class StubIdentity: SyncDeviceIdentityProviding {
    let deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    var platform: SyncDevicePlatform { .ios }
    func pushToken() async -> String? { nil }
}

private final class StubCapabilities: DeviceCapabilityReporting {
    var value: DeviceCapabilities

    init(value: DeviceCapabilities) {
        self.value = value
    }

    func currentCapabilities() async -> DeviceCapabilities { value }
}
