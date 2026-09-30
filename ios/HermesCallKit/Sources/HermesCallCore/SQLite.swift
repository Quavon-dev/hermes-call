import Foundation
import SQLite3

/// A value bound to or read from a statement.
enum SQLiteValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite \(code): \(message)" }
}

/// One row of a result.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// A short-lived connection (the system SQLite, no dependency). Opened per operation by `ChatStore`
/// so no process holds a lock on the shared file while it is suspended.
final class SQLiteConnection {
    private let handle: OpaquePointer
    /// SQLITE_TRANSIENT: SQLite copies bound text and blobs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opened with iOS data protection "until first unlock" for the database and its WAL/SHM files.
    init(path: String, busyTimeoutMs: Int32 = 5000) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
            | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        let status = sqlite3_open_v2(path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: status, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, busyTimeoutMs)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw error(status) }
    }

    /// Runs a statement; returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        try query(sql, values) { _ in }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let statement = prepared else { throw error(status) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, at: Int32(index + 1), in: statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw error(step) }
            try row(SQLiteRow(statement: statement))
        }
    }

    /// A write transaction that takes the lock at once (`BEGIN IMMEDIATE`), so concurrent writers from
    /// other processes wait (busy timeout) instead of failing half-way.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ value: SQLiteValue, at index: Int32, in statement: OpaquePointer) throws {
        let status: Int32
        switch value {
        case .null: status = sqlite3_bind_null(statement, index)
        case .int(let number): status = sqlite3_bind_int64(statement, index, number)
        case .real(let number): status = sqlite3_bind_double(statement, index, number)
        case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, Self.transient)
        case .blob(let data):
            status = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
            }
        }
        guard status == SQLITE_OK else { throw error(status) }
    }

    private func error(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }
}
