import SwiftUI

@main
struct DayCueApp: App {

    // 容器在应用生命周期内只有一个：本地库是单写者，多处打开会直接抢锁。
    @StateObject private var container = AppContainer.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(container)
                .task {
                    await container.refreshPermissions()
                    // 进程上次可能被杀在"外部已写入、本地回执未落库"的中途，
                    // 重启后先做一次恢复：pending 的安全重试，unknown 的转为待对账。
                    await container.writer.recoverInterruptedWrites()
                    // 启动时恢复地点监控注册：系统会在重启后丢掉区域监控，
                    // 不重建的话用户设的地点提醒会静默失效。
                    await container.proactiveGeo.start()
                    // 课后追问通知同理：安排是"提前算好"的，重启后必须重算一次。
                    await container.followUpNotifications.reapplyFromSettings()
                    // 云同步：注册回前台重放与网络恢复监听。
                    // 放在启动而不是设置页出现时，保证用户没打开过设置页也会自动重放。
                    container.cloudSync.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // 回到前台时重新读权限：用户可能在系统设置里改过，
                    // 而 iOS 不会主动通知我们这件事。
                    guard newPhase == .active else { return }
                    Task {
                        await container.refreshPermissions()
                        // 回前台也做一次：用户可能刚在系统设置里授权或撤销了权限。
                        await container.writer.recoverInterruptedWrites()
                        // 权限可能刚变过：该停的监控要停，该起的要起。
                        await container.proactiveGeo.refreshRegistrations()
                        await container.followUpNotifications.reapplyFromSettings()
                    }
                }
        }
    }
}
