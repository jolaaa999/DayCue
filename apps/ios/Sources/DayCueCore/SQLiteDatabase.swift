import Foundation
import SQLite3

// SQLite3 是 iOS/macOS 自带的 C 库（libsqlite3），不引入任何第三方依赖。
// 这里只包一层最小可用的 API：语句、绑定、取值、事务。ORM 级别的抽象留到 Store 里按表写。

/// SQLITE_TRANSIENT 的 Swift 写法。
///
/// SQLite C API 用函数指针 (void(*)(void*))-1 表示「绑定后请复制一份」，
/// Swift 无法直接写出这个函数指针，所以用位模式构造。这是官方 C 宏在 Swift 里的等价物。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, Equatable, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case execFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String)
    case bindFailed(code: Int32, message: String, index: Int)
    case stepFailed(code: Int32, message: String)
    case uniqueConstraintViolation(message: String)

    public var description: String {
        switch self {
        case let .openFailed(code, message): return "打开数据库失败(\(code)): \(message)"
        case let .execFailed(code, message): return "执行 SQL 失败(\(code)): \(message)"
        case let .prepareFailed(code, message): return "准备语句失败(\(code)): \(message)"
        case let .bindFailed(code, message, index): return "绑定第 \(index) 个参数失败(\(code)): \(message)"
        case let .stepFailed(code, message): return "语句执行失败(\(code)): \(message)"
        case let .uniqueConstraintViolation(message): return "唯一约束冲突: \(message)"
        }
    }

    /// 唯一约束冲突要能被上层识别，因为它同时承担「幂等去重」的语义，不是单纯的错误。
    public var isUniqueConstraintViolation: Bool {
        if case .uniqueConstraintViolation = self { return true }
        return false
    }
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }

    public static func optionalText(_ value: String?) -> SQLiteValue {
        guard let value else { return .null }
        return .text(value)
    }
}

/// 一条已准备好的语句。持有期间必须保证连接仍然存活，所以只在 Store 方法内部短生命周期使用。
public final class SQLiteStatement {
    private let handle: OpaquePointer
    private let connection: OpaquePointer

    fileprivate init(connection: OpaquePointer, sql: String) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(code: rc, message: SQLiteDatabase.lastErrorMessage(connection))
        }
        self.handle = stmt
        self.connection = connection
    }

    deinit {
        _ = sqlite3_finalize(handle)
    }

    public func bind(_ values: [SQLiteValue]) throws {
        _ = sqlite3_reset(handle)
        _ = sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(handle, index)
            case .integer(let number):
                rc = sqlite3_bind_int64(handle, index, number)
            case .real(let number):
                rc = sqlite3_bind_double(handle, index, number)
            case .text(let string):
                // 用 withCString 明确生命周期，再让 SQLite 复制一份（TRANSIENT）。
                rc = string.withCString { sqlite3_bind_text(handle, index, $0, -1, SQLITE_TRANSIENT) }
            case .blob(let data):
                rc = data.withUnsafeBytes { buffer -> Int32 in
                    guard let base = buffer.baseAddress else {
                        return sqlite3_bind_zeroblob(handle, index, 0)
                    }
                    return sqlite3_bind_blob(handle, index, base, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError.bindFailed(code: rc, message: SQLiteDatabase.lastErrorMessage(connection), index: offset + 1)
            }
        }
    }

    /// 返回 true 表示还有一行（SQLITE_ROW），false 表示语句结束（SQLITE_DONE）。
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let message = SQLiteDatabase.lastErrorMessage(connection)
            // 只有 UNIQUE 冲突要翻译成「已存在」；CHECK 约束失败是真正的数据错误，不能混淆。
            if rc == SQLITE_CONSTRAINT, message.contains("UNIQUE constraint failed") {
                throw SQLiteError.uniqueConstraintViolation(message: message)
            }
            throw SQLiteError.stepFailed(code: rc, message: message)
        }
    }

    /// 执行到结束，用于 INSERT/UPDATE/DELETE。
    public func run() throws {
        while try step() {}
    }

    public func columnCount() -> Int { Int(sqlite3_column_count(handle)) }

    public func isNull(_ index: Int) -> Bool {
        sqlite3_column_type(handle, Int32(index)) == SQLITE_NULL
    }

    public func int64(_ index: Int) -> Int64 {
        sqlite3_column_int64(handle, Int32(index))
    }

    public func int(_ index: Int) -> Int {
        Int(sqlite3_column_int64(handle, Int32(index)))
    }

    public func bool(_ index: Int) -> Bool {
        sqlite3_column_int64(handle, Int32(index)) != 0
    }

    public func double(_ index: Int) -> Double {
        sqlite3_column_double(handle, Int32(index))
    }

    /// 故意不走 String(cString:)，直接用字节长度构造 UTF-8。
    /// 原因是 sqlite3_column_text 的返回类型在不同 SDK 上有 CChar / UInt8 两种形态，
    /// 用原始字节可以完全避开这个重载问题，也顺手支持了文本里内嵌 NUL 的情况。
    public func string(_ index: Int) -> String? {
        guard let pointer = sqlite3_column_text(handle, Int32(index)) else { return nil }
        let byteCount = Int(sqlite3_column_bytes(handle, Int32(index)))
        guard byteCount > 0 else { return "" }
        let buffer = UnsafeRawBufferPointer(start: pointer, count: byteCount)
        return String(decoding: Array(buffer), as: UTF8.self)
    }

    public func data(_ index: Int) -> Data? {
        guard let pointer = sqlite3_column_blob(handle, Int32(index)) else { return nil }
        let byteCount = Int(sqlite3_column_bytes(handle, Int32(index)))
        guard byteCount > 0 else { return Data() }
        return Data(bytes: pointer, count: byteCount)
    }
}

/// 一个同步的 SQLite 连接。
///
/// 设计取舍：不做连接池、不做 async。本地库体积小、语句短，
/// 同步调用反而让「事务边界」和「顺序」在代码里一眼可见，避免出现半提交状态。
public final class SQLiteDatabase {
    private let handle: OpaquePointer
    public let path: String

    public init(path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &connection, flags, nil)
        guard rc == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建数据库连接"
            if let connection { _ = sqlite3_close_v2(connection) }
            throw SQLiteError.openFailed(code: rc, message: message)
        }
        self.handle = connection
        self.path = path

        // busy_timeout 让并发写入（例如后台上传线程回写状态）自动等待，而不是直接返回 SQLITE_BUSY。
        sqlite3_busy_timeout(connection, 5_000)
        try execute("PRAGMA foreign_keys = ON;")
        // WAL 模式下读不阻塞写，录完音立刻写入不会卡住今天页的读取。
        try execute("PRAGMA journal_mode = WAL;")
    }

    deinit {
        _ = sqlite3_close_v2(handle)
    }

    static func lastErrorMessage(_ connection: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(connection))
    }

    /// 允许一次执行多条以分号分隔的语句，用于建表脚本。
    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errorPointer)
            throw SQLiteError.execFailed(code: rc, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(connection: handle, sql: sql)
    }

    /// 事务。用 IMMEDIATE 而不是默认的 DEFERRED：本地写入是「先写库再对外动作」，
    /// 立刻拿写锁能避免在事务中途才发现锁冲突。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}
