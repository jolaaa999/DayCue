import Foundation
import UIKit
import Vision

enum OCRError: LocalizedError {
    case invalidImage
    case noTextFound
    case visionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "图片无法解析。"
        case .noTextFound:
            return "没有在图片里找到文字。图片已保存，可以手动输入内容。"
        case let .visionFailed(message):
            return "文字识别失败：\(message)"
        }
    }
}

/// 端侧 OCR。
///
/// 识别结果永远允许用户编辑：白板照片、通知截图的光线和对焦都很差，
/// 把 OCR 结果当成"用户说的"直接落库会产生错误的截止日期。
struct OCRService {

    func recognizeText(in image: UIImage) async throws -> String {
        let normalized = image.normalizedForRecognition()
        guard let cgImage = normalized.cgImage else {
            throw OCRError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let guardOnce = OCRContinuationGuard(continuation: continuation)

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    guardOnce.fail(with: OCRError.visionFailed(error.localizedDescription))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // 只取每个观察框的最优候选：第二、第三候选噪声很大，
                // 混进正文反而会让用户更难改。
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    guardOnce.fail(with: OCRError.noTextFound)
                } else {
                    guardOnce.succeed(with: text)
                }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                guardOnce.fail(with: OCRError.visionFailed(error.localizedDescription))
            }
        }
    }

    /// 对本地图片文件做 OCR，供「重新识别」使用。
    func recognizeText(at url: URL) async throws -> String {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw OCRError.invalidImage
        }
        return try await recognizeText(in: image)
    }
}

/// Vision 的完成回调与 perform 抛错可能同时发生，重复 resume continuation 会直接崩溃。
private final class OCRContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func succeed(with value: String) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: value)
    }

    func fail(with error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(throwing: error)
    }
}

extension UIImage {
    /// 把图片重绘成 orientation = .up，避免 Vision 在竖拍照片上把文字读成横排。
    /// 直接用 imageOrientation 传参也能做，但后续存盘/上传还要再处理一次，不如一次归一化。
    func normalizedForRecognition() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 上传/保存前压缩，控制内存与体积。长边限制在 2048。
    func resizedForUpload(maxDimension: CGFloat = 2048) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let ratio = maxDimension / longest
        let target = CGSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
