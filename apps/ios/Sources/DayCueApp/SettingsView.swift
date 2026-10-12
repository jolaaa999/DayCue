import SwiftUI
import DayCueCore

/// 设置页。
///
/// 顺序按"用户最可能需要修的"排：默认清单与权限在前，数据管理在后。
/// Bearer Token 只进 Keychain，界面上也说明这一点。
struct SettingsView: View {

    @EnvironmentObject private var container: AppContainer
    @StateObject private var model = SettingsViewModel()

#if DEBUG
    /// 故障注入开关的状态。Release 构建里这个符号根本不存在。
    @State private var faultInjectionEnabled = DebugWriteFaultInjection.isEnabled
#endif

    var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            reminderSection
            permissionSection
            aiSection
            behaviorSection
            dataSection
            contentSection
            proactiveSection
            cloudSyncSection
#if DEBUG
            debugSection
#endif
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .task {
            model.attach(container)
            await container.refreshPermissions()
        }
        .onChange(of: container.permissionSnapshot) { _, _ in
            model.reload()
        }
        .confirmationDialog(
            "确定清空本地数据？",
            isPresented: $model.showWipeConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空所有本地数据", role: .destructive) {
                model.wipeAllData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除全部记录、任务、附件与本地设置。苹果提醒事项里的条目不会被删除。这个操作无法撤销。")
        }
    }

    // MARK: - 默认清单

    private var reminderSection: some View {
        Section {
            PermissionRow(
                title: "提醒事项权限",
                detail: "写入苹果提醒事项需要完整访问权限。",
                status: container.permissionSnapshot.reminders,
                action: { PermissionCenter.openSystemSettings() }
            )

            if !container.permissionSnapshot.remindersGranted {
                Button {
                    Task { await model.requestReminderAccess() }
                } label: {
                    if model.isRequestingReminders {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("请求提醒事项权限")
                    }
                }
            }

            if container.permissionSnapshot.remindersGranted {
                Picker("默认清单", selection: defaultListBinding) {
                    Text("不选择").tag("")
                    ForEach(model.reminderLists) { list in
                        Text(list.isWritable ? list.title : list.title + "（不可写）")
                            .tag(list.id)
                    }
                }
                if model.reminderLists.isEmpty {
                    Text("设备上还没有提醒事项清单，可以先去「提醒事项」App 建一个。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("提醒事项")
        } footer: {
            Text("只有在你的清单可写时才会写入。未授权时任务仍然保存在 App，并显示为「等待写入苹果提醒事项」。")
                .font(.caption)
        }
    }

    private var defaultListBinding: Binding<String> {
        Binding(
            get: { container.settings.defaultListId ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    container.settings.setDefaultList(id: nil, title: nil)
                } else {
                    let list = model.reminderLists.first { $0.id == newValue }
                    container.settings.setDefaultList(id: list?.id, title: list?.title)
                }
            }
        )
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section {
            PermissionRow(
                title: "麦克风",
                detail: "录音需要。拒绝后仍可输入文字或选图。",
                status: container.permissionSnapshot.microphone,
                action: { PermissionCenter.openSystemSettings() }
            )
            if !container.permissionSnapshot.microphone.isGranted {
                Button("请求麦克风权限") {
                    Task { await model.requestMicrophoneAccess() }
                }
            }

            PermissionRow(
                title: "语音识别",
                detail: "系统转写需要。不可用时可以退回后端转写。",
                status: container.permissionSnapshot.speech,
                action: { PermissionCenter.openSystemSettings() }
            )
            if !container.permissionSnapshot.speech.isGranted {
                Button("请求语音识别权限") {
                    Task { await model.requestSpeechAccess() }
                }
            }

            PermissionRow(
                title: "通知",
                detail: "仅在任务没有交给苹果提醒事项时使用。",
                status: container.permissionSnapshot.notifications,
                action: { PermissionCenter.openSystemSettings() }
            )
            if !container.permissionSnapshot.notifications.isGranted {
                Button("请求通知权限") {
                    Task { await model.requestNotificationAccess() }
                }
            }
        } header: {
            Text("权限状态")
        } footer: {
            Text("拒绝任何一项权限都不会让 App 无法使用。缺少的能力会在对应位置显示降级状态。")
                .font(.caption)
        }
    }

    // MARK: - AI 服务

    private var aiSection: some View {
        Section {
            TextField("服务地址", text: baseURLBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            SecureField("Bearer Token（可选）", text: tokenBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await model.testConnection() }
            } label: {
                if model.isTestingConnection {
                    ProgressView().controlSize(.small)
                } else {
                    Text("测试连接")
                }
            }

            if let result = model.connectionResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("AI 服务")
        } footer: {
            Text("默认地址 http://127.0.0.1:8787。Token 保存在系统钥匙串（Keychain），不写入 UserDefaults。")
                .font(.caption)
        }
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { container.settings.apiBaseURL },
            set: { container.settings.apiBaseURL = $0 }
        )
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: { container.settings.bearerToken },
            set: { container.settings.bearerToken = $0 }
        )
    }

    // MARK: - 行为

    private var behaviorSection: some View {
        Section {
            Toggle("解析完成后自动创建任务", isOn: Binding(
                get: { container.settings.autoCreateEnabled },
                set: { container.settings.autoCreateEnabled = $0 }
            ))
        } header: {
            Text("执行方式")
        } footer: {
            Text("默认关闭：先看解析结果再确认。打开后，字段完整且不需要澄清的候选会直接创建；笔记永远不会自动写入系统。")
                .font(.caption)
        }
    }

    // MARK: - 云同步

    /// 云同步入口。
    /// 后端地址仍可在「AI 服务」那节修改（同一个 AppSettings 字段），
    /// 但登录状态、冲突与设备能力上报只有这一页看得到。
    private var cloudSyncSection: some View {
        Section {
            NavigationLink {
                CloudSyncSettingsView(service: container.cloudSync)
            } label: {
                Label("云同步", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
        } header: {
            Text("云同步")
        } footer: {
            Text("未登录或未配置后端地址时，同步一个请求都不会发；本地功能不受影响。")
                .font(.caption)
        }
    }

    // MARK: - 调试

#if DEBUG
    /// 仅 Debug 存在的故障注入开关。
    ///
    /// 为什么放在设置页而不是编译期开关：中断窗口只有几十毫秒，
    /// 测试者必须能在不重新构建的前提下反复开关它，
    /// 否则「可重复的中断测试」无从谈起。
    private var debugSection: some View {
        Section {
            Toggle("故障注入：外部写入后立即中断", isOn: $faultInjectionEnabled)
                .onChange(of: faultInjectionEnabled) { _, newValue in
                    DebugWriteFaultInjection.isEnabled = newValue
                }
        } header: {
            Text("调试（仅 Debug 构建）")
        } footer: {
            Text("打开后，每次「苹果提醒事项已写入、本地绑定与回执尚未落库」时会立刻退出进程，"
                 + "用来稳定复现那个中断窗口。验收步骤见 docs/phase-1-device-acceptance.md 第 3 节。")
                .font(.caption)
        }
    }
#endif

    // MARK: - 数据

    private var dataSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("本地数据库")
                    .font(.subheadline)
                Text(model.databasePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("当前大小：\(model.databaseSizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("清空本地数据", role: .destructive) {
                model.showWipeConfirmation = true
            }
        } header: {
            Text("数据管理")
        } footer: {
            Text("清空只影响本机数据，不会删除苹果提醒事项里的条目，也不会删除服务器上的内容。")
                .font(.caption)
        }
    }

    // MARK: - 内容入口（笔记 / 原始记录 / 课表 / 追问）

    /// 这些页面是"回头看"的内容，入口放在设置里而不是再往底栏加标签。
    /// 底栏固定四个是刻意的：捕获是主路径，标签越多主路径越不突出；
    /// 而这些页面不是高频入口，放这里既够用又不喧宾夺主。
    private var contentSection: some View {
        Section {
            NavigationLink {
                NoteListView()
            } label: {
                Label("笔记", systemImage: "note.text")
            }

            NavigationLink {
                CaptureListView()
            } label: {
                Label("原始记录", systemImage: "tray.full")
            }

            NavigationLink {
                ScheduleView()
            } label: {
                Label("课表", systemImage: "calendar")
            }

            NavigationLink {
                FollowUpView()
            } label: {
                Label("课后追问", systemImage: "questionmark.bubble")
            }
        } header: {
            Text("内容")
        } footer: {
            Text("原始记录保留你当时输入的文字、转写、图片和来源，删掉笔记不会连带删掉记录。课表里的预计结束时间不等于实际下课，也不代表出勤。")
                .font(.caption)
        }
    }

    // MARK: - 地点与主动提醒

    private var proactiveSection: some View {
        Section {
            NavigationLink {
                PlaceListView()
            } label: {
                Label("地点", systemImage: "mappin.and.ellipse")
            }

            NavigationLink {
                ProactiveSettingsView()
            } label: {
                Label("主动提醒设置", systemImage: "bell.badge")
            }

            // 这里是带编排的容器视图：它自己去取 EventKit 快照、跑三方比较、
            // 把基线与游标写回存储，并把"需要用户确认的删除"单独列出来。
            // 删除类决策永远不自动执行 —— 因为分不清"用户在苹果侧真删了"
            // 和"用户手改备注把标识行弄没了"。
            NavigationLink {
                ReconciliationCoordinatorView()
            } label: {
                Label("提醒事项对账", systemImage: "arrow.triangle.2.circlepath")
            }
        } header: {
            Text("地点与主动提醒")
        } footer: {
            Text("地点提醒只在你确认过的地点生效，默认不记录移动轨迹。主动提醒受每日预算与静默时段限制，静默时段内的消息会被推迟而不是丢弃。")
                .font(.caption)
        }
    }
}
