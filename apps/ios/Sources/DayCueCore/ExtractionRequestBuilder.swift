import Foundation

public enum ExtractionRequestBuildError: Error, Equatable {
    case emptyText
}

/// 把本地捕获记录翻译成契约请求。
///
/// 单独成文件是因为这里的字段映射（capture kind -> source.type、字数上限、时区来源）
/// 是客户端唯一「对外表达用户输入」的地方，必须集中且可测。
public enum ExtractionRequestBuilder {

    /// 契约里 source.text 的上限是 8000。
    public static let maxSourceTextLength = 8000

    public static func build(
        capture: CaptureRecord,
        clientContext: ExtractionClientContext? = nil,
        timezone: String? = nil
    ) throws -> ExtractionRequest {
        // 用户编辑过的文本优先：raw_text 是用户直接输入或修改后的正文，
        // transcript / ocr_text 只有在 raw_text 为空时才顶上。
        let text = capture.effectiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionRequestBuildError.emptyText }

        let truncated = String(text.prefix(maxSourceTextLength))

        return ExtractionRequest(
            captureId: capture.id,
            source: ExtractionRequestSource(
                type: sourceType(for: capture.kind),
                text: truncated,
                language: nil
            ),
            recordedAt: capture.recordedAt,
            // 时区必须用「录入当时」的时区，而不是解析时刻的当前时区：
            // 用户跨时区旅行时，后者会把「明晚八点」算错。
            timezone: capture.recordedTimezone.isEmpty
                ? (timezone ?? TimeZone.current.identifier)
                : capture.recordedTimezone,
            clientContext: clientContext
        )
    }

    public static func sourceType(for kind: CaptureKind) -> ExtractionRequestSource.SourceType {
        switch kind {
        case .text: return .text
        case .audio: return .asr
        case .image: return .ocr
        }
    }

    /// 内容指纹参与幂等键计算，因此这里必须是稳定摘要而不是哈希表地址之类的随机值。
    public static func contentFingerprint(of capture: CaptureRecord) -> String {
        let material = capture.kind.rawValue + "|" + capture.effectiveText
        return IdempotencyKey.truncatedDigest(material)
    }
}
