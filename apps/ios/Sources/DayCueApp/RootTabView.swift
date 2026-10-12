import SwiftUI
import DayCueCore

/// 底栏。
///
/// 四个标签固定为 今天 / 记录 / 记忆 / 设置。
/// 记录入口用实心加号图标，是三个入口里视觉权重最高的一个——
/// 捕获是这个产品的主路径，首页不做成聊天界面。
struct RootTabView: View {

    enum Tab: Hashable {
        case today
        case capture
        case memory
        case settings
    }

    @EnvironmentObject private var container: AppContainer
    @State private var selection: Tab = .today

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                TodayView()
            }
            .tabItem {
                Label("今天", systemImage: "sun.max")
            }
            .tag(Tab.today)

            NavigationStack {
                CaptureView()
            }
            .tabItem {
                Label("记录", systemImage: "plus.circle.fill")
            }
            .tag(Tab.capture)

            NavigationStack {
                MemoryView()
            }
            .tabItem {
                Label("记忆", systemImage: "brain")
            }
            .tag(Tab.memory)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .tint(.accentColor)
        .safeAreaInset(edge: .top) {
            if let warning = container.startupWarning {
                StartupWarningBanner(message: warning)
            }
        }
    }
}

private struct StartupWarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}
