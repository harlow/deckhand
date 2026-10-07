import CSQLCipher
import Foundation

/// Thin wrapper over SQLCipher's SQLite API.
final class SQLiteDatabase {
    private var db: OpaquePointer?

    /// `readOnly` opens the file as immutable: no locks, and no -wal/-shm side files on the drive.
    init(path: String, key: String?, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let target = readOnly
            ? "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro&immutable=1"
            : path
        guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw OneLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        if let key {
            let bytes = Array(key.utf8)
            guard sqlite3_key(db, bytes, Int32(bytes.count)) == SQLITE_OK else {
                throw OneLibraryError.database("Failed to set database key")
            }
        }
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw OneLibraryError.database("\(message) — in: \(sql.prefix(120))")
        }
    }

    enum Value {
        case int(Int64)
        case text(String)
        case null
    }

    func insert(_ table: String, _ row: [(String, Value)]) throws {
        let columns = row.map { "\"\($0.0)\"" }.joined(separator: ",")
        let placeholders = Array(repeating: "?", count: row.count).joined(separator: ",")
        try run("INSERT INTO \"\(table)\" (\(columns)) VALUES (\(placeholders))", row.map(\.1))
    }

    func run(_ sql: String, _ params: [Value] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OneLibraryError.database("\(String(cString: sqlite3_errmsg(db))) — in: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw OneLibraryError.database("\(String(cString: sqlite3_errmsg(db))) — in: \(sql)")
        }
    }

    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OneLibraryError.database("\(String(cString: sqlite3_errmsg(db))) — in: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        var rows: [[String: Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw OneLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: Value] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_NULL: row[name] = .null
                default: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [Value]) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }
}

public enum OneLibraryError: Error, CustomStringConvertible {
    case database(String)
    case validation([String])

    public var description: String {
        switch self {
        case .database(let m): return "OneLibrary database error: \(m)"
        case .validation(let issues): return "OneLibrary validation failed:\n" + issues.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}
