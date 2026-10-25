import Foundation
import SQLite3

/// A thin wrapper over the system SQLite library: one connection, prepared
/// statements cached by their SQL text, typed binds and columns. Not
/// thread-safe; each connection stays on the thread (or actor) that opened it.
final class BrowserSQLite {
    struct Failure: Error, CustomStringConvertible {
        var code: Int32
        var message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    /// A value to bind to a `?` parameter.
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `path` is a file path or `:memory:`.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(db)
            throw Failure(code: code, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements without results.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw Failure(code: code, message: message)
        }
    }

    /// Runs `sql` once per call with `values` bound; returns the changed row count.
    @discardableResult
    func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure(code) }
        return Int(sqlite3_changes(handle))
    }

    /// Steps through every result row of `sql`.
    func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure(code) }
            try row(Row(statement: statement))
        }
    }

    /// The first column of the first row, as an integer.
    func scalar(_ sql: String, _ values: [Value] = []) throws -> Int64? {
        var result: Int64?
        try query(sql, values) { row in
            if result == nil, !row.isNull(0) { result = row.int(0) }
        }
        return result
    }

    /// Runs `body` in one transaction; rolls back when it throws.
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

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
        func text(_ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: pointer)
        }
    }

    // MARK: Private

    private var lastMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: lastMessage)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepared(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var created: OpaquePointer?
            let code = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &created, nil)
            guard code == SQLITE_OK, let created else { throw failure(code) }
            statements[sql] = created
            statement = created
        }
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case let .int(number): code = sqlite3_bind_int64(statement, index, number)
            case let .double(number): code = sqlite3_bind_double(statement, index, number)
            case let .text(text): code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw failure(code) }
        }
        return statement
    }
}
