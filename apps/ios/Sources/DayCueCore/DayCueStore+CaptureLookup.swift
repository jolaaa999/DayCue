import Foundation

/// 记录浏览需要的「反向查询」：从一条原始记录出发，看它产出了什么。
///
/// 单开一个文件而不是塞进 DayCueStore+Capture.swift / +Task.swift：
/// 那两个文件已经冻结（并行会话还在用），而「按来源反查」属于浏览侧的新需求，
/// 不是捕获写入或任务写入的一部分。
public extension DayCueStore {

    /// 某条记录产出的任务，按创建时间正序。
    ///
    /// 默认不返回已软删除的任务：笔记那条规则（deletedAt 非空即不可见）在任务上同样成立，
    /// 详情页不需要为「已删除的任务」单独设计一种展示状态。
    func tasks(originCaptureId: String, includeDeleted: Bool = false) throws -> [TaskRecord] {
        var sql = "SELECT \(taskColumns) FROM task WHERE origin_capture_id = ?"
        if !includeDeleted { sql += " AND deleted_at IS NULL" }
        sql += " ORDER BY created_at ASC, id ASC;"

        let statement = try database.prepare(sql)
        try statement.bind([.text(originCaptureId)])
        var result: [TaskRecord] = []
        while try statement.step() {
            result.append(Self.makeTask(statement))
        }
        return result
    }
}
