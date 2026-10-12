import SwiftUI

/// 记忆页。
///
/// 第一阶段只做空状态，并且要说清楚"为什么这里是空的"：
/// 现在不做推断式记忆，所以不展示任何未经用户确认的内容，也不造样例数据。
struct MemoryView: View {

    var body: some View {
        List {
            Section {
                EmptyStateView(
                    systemImage: "brain",
                    title: "本阶段还不做推断式记忆",
                    message: "DayCue 现在还不会从你的记录里推断偏好或长期状态。等你确认过的内容才会出现在这里。"
                )
            }

            Section {
                Text("已确认事实")
                    .font(.subheadline.weight(.semibold))
                Text("暂时没有已确认事实。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("任务和笔记不会被自动写成「你记得的事」。只有你明确确认过的内容才会进入这里。")
                    .font(.caption)
            }

            Section {
                Text("以后你可以在这里查看、修改、删除记忆。删除某条记忆时，DayCue 不会连带删除你的原始笔记。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("记忆")
    }
}
