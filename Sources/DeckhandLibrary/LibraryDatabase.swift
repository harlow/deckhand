import CSQLCipher
import Darwin
import Foundation

public enum DeckhandLibraryError: Error, LocalizedError {
    case database(String), busy, conflict(String), invalid(String)
    public var errorDescription: String? {
        switch self {
        case .database(let text): "Couldn't save the Deckhand library: \(text)"
        case .busy: "This Deckhand library is already open in another app. Close that app and try again."
        case .conflict(let text), .invalid(let text): text
        }
    }
}

/// SQLCipher provides SQLite here; this database is local, unencrypted and unrelated to the USB database.
/// One app owns writes; CLI readers use SQLite's normal transaction snapshot, including the WAL.
final class LibraryDatabase {
    private var handle: OpaquePointer?
    private var owner: Int32 = -1
    init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            owner = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
            guard owner >= 0 else { throw DeckhandLibraryError.database("Couldn't open the library lock.") }
            guard flock(owner, LOCK_EX | LOCK_NB) == 0 else { close(); throw DeckhandLibraryError.busy }
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = error; close(); throw DeckhandLibraryError.database(message)
        }
        do {
            sqlite3_busy_timeout(handle, 5000)
            let version = try scalar("PRAGMA user_version") ?? "0"
            guard version == "0" || version == "1" else { throw DeckhandLibraryError.invalid("This library was saved by a newer Deckhand. Update the app to open it.") }
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                try execute("""
                    CREATE TABLE IF NOT EXISTS metadata (id TEXT PRIMARY KEY, body TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS tracks (id TEXT PRIMARY KEY, body TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS playlists (id TEXT PRIMARY KEY, body TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS sources (id TEXT PRIMARY KEY, body TEXT NOT NULL);
                    PRAGMA user_version=1;
                    """)
            }
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() {
        if let handle { sqlite3_close(handle); self.handle = nil }
        if owner >= 0 { flock(owner, LOCK_UN); Darwin.close(owner); owner = -1 }
    }
    private var error: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Library is closed." }
    func execute(_ sql: String) throws {
        guard handle != nil else { throw DeckhandLibraryError.database(error) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw DeckhandLibraryError.database(error) }
    }
    func put<T: Encodable>(_ value: T, id: String, table: String) throws {
        let body = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try statement("INSERT INTO \(table)(id,body) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body", [id, body]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DeckhandLibraryError.database(error) }
        }
    }
    func records<T: Decodable>(_ type: T.Type, table: String) throws -> [String: T] {
        var result: [String: T] = [:]
        try statement("SELECT id,body FROM \(table)", []) { stmt in
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw DeckhandLibraryError.database(error) }
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let data = Data(String(cString: sqlite3_column_text(stmt, 1)).utf8)
                result[id] = try JSONDecoder().decode(type, from: data)
            }
        }
        return result
    }
    func delete(id: String, table: String) throws {
        try statement("DELETE FROM \(table) WHERE id=?", [id]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DeckhandLibraryError.database(error) }
        }
    }
    func scalar(_ sql: String) throws -> String? {
        try statement(sql, []) { stmt in
            let status = sqlite3_step(stmt)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw DeckhandLibraryError.database(error) }
            return status == SQLITE_ROW ? String(cString: sqlite3_column_text(stmt, 0)) : nil
        }
    }
    private func statement<T>(_ sql: String, _ values: [String], _ work: (OpaquePointer?) throws -> T) throws -> T {
        guard handle != nil else { throw DeckhandLibraryError.database(error) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw DeckhandLibraryError.database(error) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw DeckhandLibraryError.database(error) }
        }
        return try work(stmt)
    }
}
