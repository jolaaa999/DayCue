import Foundation

/// 「按稳定标识查重」的结论。
///
/// 为什么不能只用 Optional：把「查到了没有」「没有权限」「查询失败」「只查了一部分」
/// 全都折叠成 nil，调用方就只能把后三种当成「没找到」然后继续创建，
/// 结果是外部出现第二条提醒，而用户毫不知情。
public enum ReminderLookupOutcome: String, Equatable, Sendable, CaseIterable {
    case found
    case notFound
    case notAuthorized
    case queryFailed
    case incompleteScope

    /// 只有「查询成功、范围完整、确实没有」才允许继续创建。
    public var allowsCreatingNew: Bool { self == .notFound }

    /// 必须停下来交给用户处理，而不是自动继续写。
    public var requiresUserAttention: Bool {
        switch self {
        case .found, .notFound: return false
        case .notAuthorized, .queryFailed, .incompleteScope: return true
        }
    }

    /// 给人看的诊断说明，用于写入失败提示与同步异常说明。
    public var diagnosticName: String {
        switch self {
        case .found: return "已存在同一条任务的外部提醒"
        case .notFound: return "确认不存在"
        case .notAuthorized: return "没有提醒事项权限"
        case .queryFailed: return "查询提醒事项失败"
        case .incompleteScope: return "查询范围不完整"
        }
    }
}

public enum ReminderLookupPolicy {

    /// 一段查询的结果。
    public struct Fetch: Equatable, Sendable {
        /// 查询本身是否成功返回（EventKit 用 nil 表示失败）。
        public let succeeded: Bool
        /// 命中项的稳定外部标识；没命中为 nil。
        public let matchExternalId: String?

        public init(succeeded: Bool, matchExternalId: String? = nil) {
            self.succeeded = succeeded
            self.matchExternalId = matchExternalId
        }

        public static let failed = Fetch(succeeded: false)
        public static func ok(match: String?) -> Fetch {
            Fetch(succeeded: true, matchExternalId: match)
        }
    }

    /// 综合两段查询给出结论。
    ///
    /// 之所以要分两段：EventKit 的「未完成」与「已完成」是两个不同的谓词。
    /// 只查未完成项，会把用户在苹果侧勾掉的那条当成「不存在」，然后重建一条。
    public static func classify(
        authorized: Bool,
        incomplete: Fetch,
        completed: Fetch
    ) -> ReminderLookupOutcome {
        guard authorized else { return .notAuthorized }

        // 命中是确定的事实，不受另一段查询是否成功影响。
        if incomplete.matchExternalId != nil || completed.matchExternalId != nil {
            return .found
        }

        switch (incomplete.succeeded, completed.succeeded) {
        case (true, true):
            // 只有两段都成功、且都没有命中，才能断言「确实没有」。
            return .notFound
        case (false, false):
            return .queryFailed
        default:
            // 一段成功一段失败：范围不完整，不能据此创建。
            return .incompleteScope
        }
    }
}
