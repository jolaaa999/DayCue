import Foundation

public extension Array where Element == ReviewDraft {

    /// 只有「被选中」且「类型是 task」的候选才会变成任务。
    ///
    /// 放在 Core 而不是视图里，是因为「笔记不能被算成任务」是一条产品约束，
    /// 需要能被单元测试直接验证，而不是靠读界面代码确认。
    var tasksToCreate: [ReviewDraft] {
        filter { $0.isSelected && $0.kind == .task }
    }

    /// 被选中、但只作为笔记保留的条目数。它们不写进苹果提醒事项。
    var selectedNoteCount: Int {
        filter { $0.isSelected && $0.kind == .note }.count
    }

    /// 全部被取消勾选时为 true —— 此时只保留记录，不创建任何任务。
    var createsNothing: Bool {
        tasksToCreate.isEmpty
    }
}
