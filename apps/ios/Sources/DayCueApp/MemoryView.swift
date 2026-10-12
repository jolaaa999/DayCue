import SwiftUI
import DayCueCore

/// 记忆标签页的根视图。
///
/// 第一阶段这里只有一个空状态，因为当时还没有记忆功能。
/// 现在记忆已经落库（candidate / confirmed / conflict / retired 四态），
/// 所以这里直接托管真正的列表页；本文件保留一层薄包装，
/// 是为了让底栏的四个入口保持稳定，不随功能演进被反复改动。
///
/// 「推断出来的内容一律先落候选、必须用户确认才能当事实用」
/// 这条规则的界面体现（来源徽标、状态徽标）在 MemoryListView 里。
struct MemoryView: View {

    var body: some View {
        MemoryListView()
    }
}
