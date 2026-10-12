import SwiftUI
import DayCueCore

/// 云同步设置页。
///
/// 为什么单独做一页，而不是把状态塞进设置页已有的某一节：
/// 云同步要回答的问题有五个维度（登录、连接、上一轮结果、冲突、设备能力），
/// 平铺进设置页会把「默认清单 / 权限」这些高频项挤到看不见的地方。
/// 这里只做展示与触发，所有重试、游标、冲突决策语义都在 CloudSyncService / DayCueCore，
/// 视图不重复实现任何同步规则。
struct CloudSyncSettingsView: View {

    /// 服务实例由 AppContainer 持有并注入。
    /// 视图内刻意不自己 new：CloudSyncService 内部有 NWPathMonitor、前台通知观察者
    /// 和 2 秒防抖任务，每个实例各持一套；自己 new 会导致「这一页看到的实例」
    /// 与「写路径调用 noteLocalChange 的实例」不是同一个，入队与重放对不上。
    @ObservedObject var service: CloudSyncService

    /// 地址与令牌都从 AppSettings 现读现写：与 AppContainer 里 DayCueAPIClient 的取值方式一致。
    @EnvironmentObject private var container: AppContainer

    /// 令牌草稿。
    /// 为什么不把 SecureField 直接绑到 settings.bearerToken：
    /// 直接绑定会让用户每敲一个字符就写一次 Keychain，并在半截令牌上触发同步。
    /// 登录 / 登出必须是显式动作，点按钮才把草稿写回设置。
    @State private var tokenDraft: String = ""
    /// 保证只在进入页面时把 Keychain 里的令牌读进草稿一次，避免每次重算 body 都读 Keychain。
    @State private var didLoadToken = false

    /// 本地待推送队列的计数，直接读库。
    /// 队列是写路径的产物，CloudSyncService 只负责触发重放、不负责统计；
    /// 因此这里自己读，而不是让服务多背一份可能与库不一致的缓存。
    @State private var queueCounts = SyncQueueCounts()

    struct SyncQueueCounts: Equatable {
        var pending = 0
        var conflict = 0
        var blocked = 0
    }

    var body: some View {
        List {
            accountSection
            runSection
            conflictSection
            queueSection
            capabilitySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("云同步")
        .task {
            // 进入页面时启动一次：注册「回前台重放」与「网络恢复重放」。
            // start() 自身幂等（observers 非空即返回），重复进入不会重复注册。
            service.start()
            if !didLoadToken {
                tokenDraft = container.settings.bearerToken
                didLoadToken = true
            }
            refreshQueueCounts()
            await service.refreshDeviceCapabilitySummary()
        }
        .onChange(of: service.lastResult) { _, _ in
            // 手动、回前台、网络恢复、退避到点这四条触发都会更新 lastResult，
            // 队列状态随之可能变化，所以在这里统一刷新一次计数。
            refreshQueueCounts()
        }
    }

    // MARK: - 账号与后端

    private var accountSection: some View {
        Section {
            HStack {
                Text("登录状态")
                Spacer()
                Text(service.signInState.displayText)
                    .foregroundStyle(service.signInState.isUsable ? Color.green : Color.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if case let .needsReauthentication(reason) = service.signInState {
                // 令牌失效必须单独说明：不写的话用户会以为是网络问题，反复点同步也没用。
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            TextField("后端地址", text: baseURLBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            SecureField("Bearer Token", text: $tokenDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack(spacing: 12) {
                Button("登录并使用该令牌") {
                    Task { await signIn() }
                }
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("登出", role: .destructive) {
                    Task { await signOut() }
                }
                .disabled(container.settings.bearerToken.isEmpty)
            }
        } header: {
            Text("账号与后端")
        } footer: {
            Text("未登录时云同步一个请求都不发，本地功能不受影响。令牌保存在系统钥匙串（Keychain）。地址改完立即生效，不需要重启 App。")
                .font(.caption)
        }
    }

    /// 地址直接双向绑定：它只是一个普通偏好，不存在「半截地址」的中间态问题。
    private var baseURLBinding: Binding<String> {
        Binding(
            get: { container.settings.apiBaseURL },
            set: { container.settings.apiBaseURL = $0 }
        )
    }

    /// 登录：把草稿写回 AppSettings（真实改变 Keychain 里的令牌），再刷新登录状态。
    ///
    /// 为什么用 syncNow() 刷新而不是调一个专门的方法：
    /// CloudSyncService 目前没有「只改令牌、不跑一轮」的公开入口，
    /// signInState 只在内部 run() 里由 replayer.currentSignInState() 重算。
    /// 这里只调用已有的公开方法，不臆造方法名；
    /// 更干净的做法是给服务加 setToken(_:)（见交付报告里的建议签名）。
    private func signIn() async {
        container.settings.bearerToken = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        await service.syncNow()
    }

    /// 登出：清空令牌后同样刷新一次状态。
    /// 未登录时重放的第一道判断就是「没有令牌 -> 直接返回」，不会产生任何网络副作用。
    private func signOut() async {
        container.settings.bearerToken = ""
        tokenDraft = ""
        await service.syncNow()
    }

    // MARK: - 同步状态

    private var runSection: some View {
        Section {
            HStack {
                Button {
                    Task { await service.syncNow() }
                } label: {
                    if service.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("立即同步")
                    }
                }
                // 同步中禁用：CloudSyncService 内部虽然有互斥，
                // 但按钮不禁用会让用户以为没点上、反复点。
                .disabled(service.isSyncing)

                Spacer()

                if service.isSyncing {
                    Text("正在同步…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text(service.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            resultRows
        } header: {
            Text("同步状态")
        } footer: {
            Text("同步也会在 App 回到前台、网络恢复、以及本地写入后 2 秒自动触发；手动点只是把等待提前。")
                .font(.caption)
        }
    }

    /// 上一轮结果。
    /// 三种「没跑成」必须区分开，任何一种都不能显示成成功：
    ///   1. 没配后端地址 —— 连请求都发不出去；
    ///   2. 未登录 / 登录失效 —— 按设计完全不跑；
    ///   3. didRun = false —— 已有同步在跑或本轮被跳过。
    @ViewBuilder
    private var resultRows: some View {
        if !container.settings.hasUsableBaseURL {
            Label("未配置后端地址，同步不会发起任何请求。", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if !service.signInState.isUsable {
            Text("没有可用的登录状态，同步未运行。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let result = service.lastResult {
            resultDetail(result)
        } else {
            Text("还没有运行过同步。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultDetail(_ result: CloudSyncRunResult) -> some View {
        if !result.didRun {
            // didRun = false 表示这一轮什么都没做。原样展示 message，不套「成功」的外壳。
            Text("本轮未执行：\(result.message)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                resultLine("触发方式", result.trigger.displayName)
                resultLine("推送", "\(result.pushedItems) 条待推，\(result.acceptedItems) 条被接受，\(result.conflictedItems) 条冲突，\(result.rejectedItems) 条被拒")
                resultLine("拉取", "\(result.pulledChanges) 条变更，\(result.appliedChanges) 条已应用")
                if result.skippedLocalDeletions > 0 {
                    // 删除传播的关键结论：服务端的旧数据没有把用户已删除的条目复活。
                    resultLine("删除传播", "本地已删除的 \(result.skippedLocalDeletions) 条没有被服务端旧数据复活")
                }
                if let retry = result.retryScheduledIn {
                    resultLine("自动重试", "\(Int(retry.rounded())) 秒后")
                }
                if result.cursor != nil {
                    resultLine("拉取游标", "已推进")
                }
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    // MARK: - 冲突

    private var conflictSection: some View {
        Section {
            HStack {
                Text("待裁决冲突")
                Spacer()
                Text(service.conflictCount == 0 ? "无" : "\(service.conflictCount) 条")
                    .foregroundStyle(service.conflictCount == 0 ? Color.secondary : Color.orange)
            }

            if let plan = service.conflictPlan, service.conflictCount > 0 {
                NavigationLink {
                    // 复用既有的逐字段裁决页：云同步冲突被 SyncConflictPresenter 转成了同一种
                    // ReconciliationPlan，所以不需要第二套冲突界面。
                    ReconciliationView(
                        plan: plan,
                        taskTitle: { conflictTitle(for: $0) },
                        submit: { await service.resolve($0) }
                    )
                } label: {
                    Label("逐字段选择保留哪一边", systemImage: "arrow.left.arrow.right")
                }
            } else {
                Text("同一字段在本地和云端都被改过时才会出现在这里；单方修改按改过的一方自动处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("冲突")
        } footer: {
            Text("云同步没有可用的三方基线，谁改过无从归因，因此每条冲突都要你逐字段裁决，DayCue 不会替你自动选边。")
                .font(.caption)
        }
    }

    /// 冲突里只有实体 ID，直接显示 UUID 用户看不懂。
    /// 按实体类型回查本地内容取一个可读标题；查不到就如实显示 ID，不编造。
    private func conflictTitle(for entityId: String) -> String {
        guard let conflicts = try? container.store.syncConflicts(),
              let conflict = conflicts.first(where: { $0.entityId == entityId }),
              let local = try? container.store.cloudLocalEntity(
                  entityType: conflict.entityType,
                  entityId: entityId
              ),
              let title = Self.displayTitle(local.payload) else {
            return entityId
        }
        return title
    }

    /// 各实体「最像标题」的字段顺序。记录类没有标题，退回正文首行。
    static func displayTitle(_ payload: SyncEntityPayload) -> String? {
        func cleaned(_ raw: String?) -> String? {
            let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let title = cleaned(payload.title) { return title }
        if let name = cleaned(payload.name) { return name }
        if let statement = cleaned(payload.statement) { return statement }
        if let text = cleaned(payload.rawText) { return text }
        if let transcript = cleaned(payload.transcript) { return transcript }
        return cleaned(payload.ocrText)
    }

    // MARK: - 本地变更队列

    private var queueSection: some View {
        Section {
            queueLine("待推送", queueCounts.pending)
            queueLine("等待裁决", queueCounts.conflict)
            queueLine("被服务端拒绝", queueCounts.blocked)
        } header: {
            Text("本地变更队列")
        } footer: {
            Text("本地写入完成后入队，2 秒内的连续编辑合并成一次推送。被拒绝与等待裁决的条目不会自动重试，需要你处理后才会重新排入。")
                .font(.caption)
        }
    }

    private func queueLine(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count) 条")
                .foregroundStyle(count == 0 ? Color.secondary : Color.primary)
        }
    }

    /// 刷新队列计数。
    /// 读失败时保留上一次的值，而不是清零：清零会让界面谎称「没有待推送」，
    /// 而这个页面存在的意义就是如实反映队列。
    private func refreshQueueCounts() {
        var counts = queueCounts
        if let pending = try? container.store.syncChangeCount(state: .pending) {
            counts.pending = pending
        }
        if let conflict = try? container.store.syncChangeCount(state: .conflict) {
            counts.conflict = conflict
        }
        if let blocked = try? container.store.syncChangeCount(state: .blocked) {
            counts.blocked = blocked
        }
        queueCounts = counts
    }

    // MARK: - 设备能力

    private var capabilitySection: some View {
        Section {
            Text(service.deviceCapabilitySummary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Button("重新探测设备能力") {
                Task { await service.refreshDeviceCapabilitySummary() }
            }
        } header: {
            Text("设备能力上报")
        } footer: {
            Text("这就是登记设备时上报给服务端的内容。「未知」与「不可用」是两回事：还没问过权限时是未知，不会为了让内容看起来完整而谎报成不可用。")
                .font(.caption)
        }
    }
}
