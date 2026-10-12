import Foundation

/// 一次解析请求所对应的「输入版本」。
///
/// 为什么需要它：解析是异步的，用户在等待期间可以再发起一次解析，
/// 将来也可能修改正文。晚到的结果如果没有绑定输入版本，
/// 就会被当成「当前输入的可执行结果」展示出来，用户一确认就把过期内容写成了任务。
public struct CaptureInputVersion: Equatable, Sendable {

    public let captureId: String
    /// 覆盖真正送出的正文、录入时间与用户编辑标记的摘要。
    public let fingerprint: String
    public let isUserEdited: Bool

    public init(captureId: String, fingerprint: String, isUserEdited: Bool) {
        self.captureId = captureId
        self.fingerprint = fingerprint
        self.isUserEdited = isUserEdited
    }

    /// 指纹必须覆盖「会影响解析结果的全部输入」：
    /// 正文（含用户编辑优先的取值）、录入时间（相对日期以它为基准）、编辑标记。
    /// 任何一项变了就是另一个输入版本，旧结果不能再被确认。
    public static func make(from capture: CaptureRecord) -> CaptureInputVersion {
        let material = ExtractionRequestBuilder.contentFingerprint(of: capture)
            + "|" + capture.recordedAt
            + "|" + (capture.userEdited ? "edited" : "raw")
        return CaptureInputVersion(
            captureId: capture.id,
            fingerprint: SHA256Hex.digest(material),
            isUserEdited: capture.userEdited
        )
    }
}

/// 迟到结果的处置结论。
public enum ExtractionFreshness: String, Equatable, Sendable {
    /// 仍然对应当前输入，可以作为可执行结果。
    case current
    /// 已经有更新的解析请求发出，这条结果整体作废。
    case superseded
    /// 输入在请求期间变了，结果不能作为当前输入的可执行结果。
    case inputChanged

    /// 只有 current 才允许进入预览页并被确认。
    public var isActionable: Bool { self == .current }

    /// 给用户看的原因。current 返回 nil。
    public var rejectionMessage: String? {
        switch self {
        case .current:
            return nil
        case .superseded:
            return "这条解析结果已经被更新的解析取代，已丢弃。"
        case .inputChanged:
            return "记录内容在解析期间发生了变化，这份结果不再对应当前内容，已丢弃。"
        }
    }
}

public enum ExtractionFreshnessPolicy {

    /// 判断一份迟到的解析结果能否被采用。
    ///
    /// - Parameters:
    ///   - request: 发起请求时记录的输入版本。
    ///   - current: 结果到达时该记录的实际输入版本；记录已被删除时传 nil。
    ///   - generation: 发起请求时的序号。
    ///   - latestGeneration: 结果到达时最新的序号。
    public static func evaluate(
        request: CaptureInputVersion,
        current: CaptureInputVersion?,
        generation: Int,
        latestGeneration: Int
    ) -> ExtractionFreshness {
        // 先比序号：更新的请求已经把这次解析取代了，无论输入有没有变都要丢弃。
        guard generation == latestGeneration else { return .superseded }
        guard let current else { return .inputChanged }
        guard current == request else { return .inputChanged }
        return .current
    }
}
