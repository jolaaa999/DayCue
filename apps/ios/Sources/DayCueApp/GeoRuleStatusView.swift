import SwiftUI
import DayCueCore

/// 地点规则的「当前会不会触发」诊断列表。
///
/// 存在的理由：没有定位权限或定位服务关闭时，规则列表不能把它们显示成正常运行。
/// 这里把位置能力与每条规则的 blockingReason 原样摊开，用户能自己判断该去开权限，
/// 还是该先确认地点。
///
/// 谁使用它：地点列表页（PlaceListView）或主动提醒设置页把它作为一个 Section 嵌入。
/// 由于主会话统一改 AppContainer/RootTabView/ProactiveSettingsView，
/// 这里只提供视图本体，接入方式写在交付说明里。
struct GeoRuleStatusView: View {

    let capability: LocationCapability
    let readiness: [GeoRuleReadiness]
    let ruleTitle: (String) -> String

    var body: some View {
        Section {
            HStack {
                Text("定位能力")
                Spacer()
                Text(capability.displayName)
                    .foregroundStyle(capability.isUsable ? Color.secondary : Color.red)
            }

            if let reason = capability.unavailableReason {
                Text("地点规则当前都不会触发：\(reason)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let limitation = capability.limitationReason {
                Text(limitation)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if readiness.isEmpty {
                Text("还没有地点规则。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(readiness, id: \.ruleId) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ruleTitle(status.ruleId))
                        Text(status.displayText)
                            .font(.footnote)
                            .foregroundStyle(status.isActive ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("地点规则状态")
        } footer: {
            Text("DayCue 不会为了地点提醒持续取你的位置：只在系统给出区域变化时判断，位置太旧或精度不足时直接丢弃，不会用旧坐标触发提醒。")
                .font(.caption)
        }
    }
}
