import Foundation
import SQLite3

/// Write a Dash-compatible SQLite database
public func writeSQLite(to path: String, data: [[String: Any]]) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    // Remove existing file
    try? FileManager.default.removeItem(atPath: path)

    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else {
        fatal("Failed to open SQLite database at \(path)")
    }
    defer { sqlite3_close(db) }

    // Create table
    let createTable = """
        CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT);
        """
    var errMsg: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, createTable, nil, nil, &errMsg) != SQLITE_OK {
        let error = errMsg.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(errMsg)
        fatal("Failed to create table: \(error)")
    }

    // Create unique index
    let createIndex = "CREATE UNIQUE INDEX anchor ON searchIndex (name, type, path);"
    if sqlite3_exec(db, createIndex, nil, nil, &errMsg) != SQLITE_OK {
        let error = errMsg.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(errMsg)
        fatal("Failed to create index: \(error)")
    }

    // Prepare insert statement
    let insertSQL = "INSERT INTO searchIndex VALUES(NULL, ?, ?, ?);"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
        fatal("Failed to prepare insert statement")
    }
    defer { sqlite3_finalize(stmt) }

    // Begin transaction
    sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)

    for module in data {
        guard let modname = module["name"] as? String else { continue }

        // Insert module
        sqlite3_bind_text(stmt, 1, (modname as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, ("Module" as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, ("\(modname).html" as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            fatal("Failed to insert module \(modname)")
        }
        sqlite3_reset(stmt)

        // Insert items
        guard let items = module["items"] as? [[String: Any]] else { continue }
        for item in items {
            guard let itemname = item["name"] as? String,
                  let itemtype = item["type"] as? String else { continue }

            let fullName = "\(modname).\(itemname)"
            let itemPath = "\(modname).html#\(itemname)"

            sqlite3_bind_text(stmt, 1, (fullName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (itemtype as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (itemPath as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) != SQLITE_DONE {
                fatal("DB Insert failed on \(modname):\(itemname)(\(itemtype))")
            }
            sqlite3_reset(stmt)
        }
    }

    // Commit
    sqlite3_exec(db, "COMMIT;", nil, nil, nil)

    // Vacuum
    sqlite3_exec(db, "VACUUM;", nil, nil, nil)
}
