import Foundation
import SQLite3

/// Thin wrapper over the system libsqlite3. Not thread-safe: owned by ClipStore on the main actor.
final class Database {
    enum Failure: Error { case open(String), exec(String) }
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db)); sqlite3_close(db); db = nil
            throw Failure.open(msg)
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"; sqlite3_free(err)
            throw Failure.exec(msg)
        }
    }

    /// Runs a statement with bound values; returns rows as arrays of column values.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.exec(lastError) }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure.exec(lastError) }
            rows.append((0..<sqlite3_column_count(stmt)).map { c in
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: String(cString: sqlite3_column_text(stmt, c))
                default: nil
                }
            })
        }
        return rows
    }

    var userVersion: Int {
        get { (try? run("PRAGMA user_version").first?.first as? Int) ?? 0 }
        set { try? exec("PRAGMA user_version=\(newValue)") }
    }

    var isIntact: Bool { (try? run("PRAGMA quick_check").first?.first as? String) == "ok" }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }
}
