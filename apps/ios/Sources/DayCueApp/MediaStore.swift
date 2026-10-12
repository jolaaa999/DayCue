import Foundation
import UIKit
import DayCueCore

/// 媒体落盘。
///
/// 核心约束：任何上传/识别之前，音频和图片必须已经在本地目录里。
/// 上传失败、识别失败、进程被杀都不能让用户的录音消失。
struct StoredMedia {
    let url: URL
    let byteSize: Int
    let sha256: String
    let mediaType: String
}

enum MediaStoreError: LocalizedError {
    case invalidImageData
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImageData: return "图片数据无法读取。"
        case let .writeFailed(message): return "媒体文件写入失败：\(message)"
        }
    }
}

struct MediaStore {

    let directory: URL

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 录音的临时落点。用 m4a：体积小、Speech 与后端都能直接吃。
    func makeAudioURL(captureId: String) -> URL {
        directory.appendingPathComponent("audio-\(captureId).m4a")
    }

    /// 把录音从临时位置搬进媒体目录，返回落盘信息。
    func storeAudio(at temporaryURL: URL, captureId: String, fileManager: FileManager = .default) throws -> StoredMedia {
        let destination = makeAudioURL(captureId: captureId)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            // 跨卷移动会失败，退化成复制；仍然失败才向上报错。
            do {
                try fileManager.copyItem(at: temporaryURL, to: destination)
                try? fileManager.removeItem(at: temporaryURL)
            } catch {
                throw MediaStoreError.writeFailed(error.localizedDescription)
            }
        }
        return try describe(url: destination, mediaType: "audio/mp4")
    }

    func storeImage(_ image: UIImage, captureId: String) throws -> StoredMedia {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw MediaStoreError.invalidImageData
        }
        let url = directory.appendingPathComponent("image-\(captureId).jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw MediaStoreError.writeFailed(error.localizedDescription)
        }
        return StoredMedia(
            url: url,
            byteSize: data.count,
            sha256: SHA256Hex.digest(data),
            mediaType: "image/jpeg"
        )
    }

    func describe(url: URL, mediaType: String) throws -> StoredMedia {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MediaStoreError.writeFailed(error.localizedDescription)
        }
        return StoredMedia(
            url: url,
            byteSize: data.count,
            sha256: SHA256Hex.digest(data),
            mediaType: mediaType
        )
    }

    func delete(url: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}
