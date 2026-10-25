import Foundation
import SQLite3
import Synchronization

/// An SQLite error, with the message from SQLite.
public struct SQLiteError: Error, CustomStringConvertible {
    public var code: Int32
    public var message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// A value to bind to a statement or read from a row.
enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var string: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    var int: Int? {
        if case .integer(let i) = self { return Int(i) }
        return nil
    }

    var double: Double? {
        switch self {
        case .real(let d): d
        case .integer(let i): Double(i)
        default: nil
        }
    }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .text(value) }
    init(integerLiteral value: Int64) { self = .integer(value) }
    init(nilLiteral: ()) { self = .null }

    init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
    init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// One SQLite connection, used by one caller at a time.
///
/// The connection handle is guarded by a mutex, so the type is `Sendable`.
/// It uses the system `SQLite3` module, which includes FTS5 on macOS.
final class Database: Sendable {
    private struct Handle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private let handle: Mutex<Handle>

    /// Opens or creates a database file.
    init(url: URL) throws {
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let pointer { sqlite3_close(pointer) }
            throw SQLiteError(code: code, message: message)
        }
        sqlite3_busy_timeout(pointer, 10_000)
        handle = Mutex(Handle(pointer: pointer))
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        handle.withLock { _ = sqlite3_close_v2($0.pointer) }
    }

    /// Runs SQL that returns no rows; it may hold several statements.
    func execute(_ sql: String) throws {
        try handle.withLock { h in
            var error: UnsafeMutablePointer<CChar>?
            let code = sqlite3_exec(h.pointer, sql, nil, nil, &error)
            if code != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw SQLiteError(code: code, message: message)
            }
        }
    }

    /// Runs one statement with parameters and returns its rows.
    @discardableResult
    func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [[SQLValue]] {
        try handle.withLock { h in try Self.run(h.pointer, sql, parameters) }
    }

    /// Runs `body` in a transaction, committing on success and rolling back on error.
    func transaction<T>(_ body: (Transaction) throws -> T) throws -> T {
        try handle.withLock { h in
            try Self.run(h.pointer, "BEGIN IMMEDIATE", [])
            do {
                let result = try body(Transaction(pointer: h.pointer))
                try Self.run(h.pointer, "COMMIT", [])
                return result
            } catch {
                _ = try? Self.run(h.pointer, "ROLLBACK", [])
                throw error
            }
        }
    }

    /// Statements inside a transaction, on the locked connection.
    /// Use it only inside the closure that receives it.
    struct Transaction {
        fileprivate let pointer: OpaquePointer

        @discardableResult
        func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [[SQLValue]] {
            try Database.run(pointer, sql, parameters)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    fileprivate static func run(_ db: OpaquePointer, _ sql: String, _ parameters: [SQLValue]) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        var code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (i, value) in parameters.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let v): code = sqlite3_bind_int64(statement, index, v)
            case .real(let v): code = sqlite3_bind_double(statement, index, v)
            case .text(let v): code = sqlite3_bind_text(statement, index, v, -1, transient)
            }
            guard code == SQLITE_OK else {
                throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(db)))
            }
        }
        var rows: [[SQLValue]] = []
        while true {
            code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(db)))
            }
            let count = sqlite3_column_count(statement)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(count))
            for column in 0 ..< count {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }
}
