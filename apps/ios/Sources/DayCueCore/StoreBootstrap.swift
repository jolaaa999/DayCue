import Foundation

/// 应用启动时打开本地库。
///
/// 单独抽出来的原因：这是唯一会抛错的启动步骤，把失败原因留在类型里，
/// 界面才能显示「本地库打不开」而不是静默崩溃或假装一切正常。
public enum StoreBootstrap {

    public enum Failure: Error, Equatable {
        case cannotOpen(String)

        public var userFacingMessage: String {
            switch self {
            case let .cannotOpen(message):
                return "本地数据库无法打开：\(message)"
            }
        }
    }

    public static func open(
        baseDirectory: URL = DayCueStore.defaultBaseDirectory(),
        fileManager: FileManager = .default
    ) throws -> DayCueStore {
        do {
            return try DayCueStore(baseDirectory: baseDirectory, fileManager: fileManager)
        } catch {
            throw Failure.cannotOpen(String(describing: error))
        }
    }
}

/// 端侧任务编号在外部系统里的稳定前缀。
/// 写进苹果提醒事项的 notes 里，用于崩溃后按稳定标识找回，而不是按标题模糊匹配。
public enum ExternalIdentifier {
    public static let notePrefix = "DayCue 任务 ID: "

    public static func noteBody(task: TaskRecord, deepLink: String?) -> String {
        var lines: [String] = []
        if let detail = task.detail, !detail.isEmpty {
            lines.append(detail)
        }
        lines.append(notePrefix + task.id)
        if let deepLink, !deepLink.isEmpty {
            lines.append(deepLink)
        }
        return lines.joined(separator: "\n")
    }

    /// 从 notes 里解析出任务 ID。解析不出来时返回 nil —— 绝不猜。
    public static func taskId(fromNotes notes: String?) -> String? {
        guard let notes else { return nil }
        for line in notes.components(separatedBy: .newlines) {
            if line.hasPrefix(notePrefix) {
                let value = String(line.dropFirst(notePrefix.count)).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
