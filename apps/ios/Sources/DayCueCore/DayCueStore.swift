import Foundation

public enum DayCueStoreError: Error, Equatable {
    case captureNotFound(String)
    case taskNotFound(String)
    case invalidStateTransition(from: ExternalWriteState, to: ExternalWriteState)
    case fileNotFound(String)
}

/// 本地库入口。
///
/// 只负责「打开库 + 迁移 + 给出目录」，具体读写按表拆到各个 extension 文件里，
/// 避免一个几千行的 God object。所有写入都是同步的，事务边界在方法内部。
public final class DayCueStore {

    public let database: SQLiteDatabase
    public let baseDirectory: URL

    public var databasePath: String { database.path }

    public var mediaDirectory: URL {
        baseDirectory.appendingPathComponent("media", isDirectory: true)
    }

    /// Application Support/DayCue。iOS 上这个目录不会被系统清理（Caches 会被清理），
    /// 用户的录音和任务不能因为系统清缓存而消失。
    public static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        let support: URL
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            support = url
        } else {
            support = fileManager.temporaryDirectory
        }
        return support.appendingPathComponent("DayCue", isDirectory: true)
    }

    public init(baseDirectory: URL, fileManager: FileManager = .default) throws {
        self.baseDirectory = baseDirectory
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: baseDirectory.appendingPathComponent("media", isDirectory: true),
            withIntermediateDirectories: true
        )
        let path = baseDirectory.appendingPathComponent("DayCue.sqlite").path
        self.database = try SQLiteDatabase(path: path)
        try DayCueSchema.migrate(database)
    }

    public convenience init(databasePath: String) throws {
        let url = URL(fileURLWithPath: databasePath)
        try self.init(baseDirectory: url.deletingLastPathComponent())
    }

    // MARK: - 数据管理

    /// 本地库文件（含 WAL / SHM）的总字节数，设置页展示用。
    public func storageSizeInBytes(fileManager: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        let candidates = ["DayCue.sqlite", "DayCue.sqlite-wal", "DayCue.sqlite-shm"]
        for name in candidates {
            let url = baseDirectory.appendingPathComponent(name)
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    /// 清空本地数据：先删媒体文件，再按外键顺序清表。
    /// 不删 schema_migrations，否则下次启动会重复执行建表脚本（虽然 IF NOT EXISTS 也不会错，
    /// 但保留版本号更符合「只清数据不清结构」的语义）。
    public func wipeAllData(fileManager: FileManager = .default) throws {
        if let contents = try? fileManager.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil) {
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }
        try database.transaction {
            for table in [
                "outbox_operation",
                "external_binding",
                "extraction_proposal",
                "attachment",
                "task",
                "capture_item",
                "memory_item",
                "app_setting"
            ] {
                try database.execute("DELETE FROM \(table);")
            }
        }
    }

    // MARK: - 设置（key/value）

    public func setSetting(_ key: String, value: String?) throws {
        if let value {
            let statement = try database.prepare(
                "INSERT INTO app_setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
            )
            try statement.bind([.text(key), .text(value)])
            try statement.run()
        } else {
            let statement = try database.prepare("DELETE FROM app_setting WHERE key = ?;")
            try statement.bind([.text(key)])
            try statement.run()
        }
    }

    public func setting(_ key: String) -> String? {
        guard let statement = try? database.prepare("SELECT value FROM app_setting WHERE key = ?;") else {
            return nil
        }
        try? statement.bind([.text(key)])
        guard let hasRow = try? statement.step(), hasRow else { return nil }
        return statement.string(0)
    }

    public func boolSetting(_ key: String, defaultValue: Bool) -> Bool {
        guard let raw = setting(key) else { return defaultValue }
        return raw == "1" || raw.lowercased() == "true"
    }

    /// 设置项统一走这里，避免各页面自己拼 key 拼错。
    public enum SettingKey {
        public static let apiBaseURL = "ai.base_url"
        public static let defaultReminderListId = "reminder.default_list_id"
        public static let defaultReminderListTitle = "reminder.default_list_title"
        public static let autoCreateEnabled = "capture.auto_create"
        public static let transcriptionLanguage = "asr.language"
        public static let preferredTimezone = "app.timezone"
    }

    public static let defaultAPIBaseURL = "http://127.0.0.1:8787"
}

/// 任务排序的唯一定义处。
///
/// 排序键优先用提醒时刻（用户最关心「什么时候响」），没有提醒才退回截止日；
/// 两者都没有的任务排在最后，而不是当成 1970 年排到最前面。
public enum TaskOrdering {
    public static func sortKey(_ task: TaskRecord) -> String {
        if let remind = task.remindLocal, !remind.isEmpty { return remind }
        if let due = task.dueLocal, !due.isEmpty { return due }
        return "9999-12-31T23:59:59"
    }

    public static func sorted(_ tasks: [TaskRecord]) -> [TaskRecord] {
        tasks.sorted { lhs, rhs in
            let a = sortKey(lhs)
            let b = sortKey(rhs)
            if a != b { return a < b }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }
}
