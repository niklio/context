import Foundation
import SQLite3

/// Resolves message handles (phone numbers / emails) to real names using the
/// local Contacts store — Full Disk Access already covers it, and resolution
/// happens entirely on-device. Best-effort: falls back to raw handles.
enum Contacts {
    static func nameMap() -> [String: String] {
        var map: [String: String] = [:]
        let fm = FileManager.default
        let abRoot = NSHomeDirectory() + "/Library/Application Support/AddressBook"
        var dbs = [abRoot + "/AddressBook-v22.abcddb"]
        if let sources = try? fm.contentsOfDirectory(atPath: abRoot + "/Sources") {
            dbs += sources.map { abRoot + "/Sources/\($0)/AddressBook-v22.abcddb" }
        }
        for path in dbs where fm.isReadableFile(atPath: path) {
            readAddressBook(path, into: &map)
        }
        return map
    }

    /// Look up a chat handle in the map (email as-is, phones by last-10 digits).
    static func resolve(_ handle: String, in map: [String: String]) -> String? {
        if handle.contains("@") { return map[handle.lowercased()] }
        return map[normalize(handle)]
    }

    static func normalize(_ phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    private static func readAddressBook(_ path: String, into map: inout [String: String]) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let snap = tmp.appendingPathComponent("ab.db").path
        guard (try? fm.copyItem(atPath: path, toPath: snap)) != nil else { return }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: snap + suffix)
        }

        var db: OpaquePointer?
        guard sqlite3_open(snap, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)

        var names: [Int64: String] = [:]
        query(db, """
            SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD
            """) { stmt in
            let pk = sqlite3_column_int64(stmt, 0)
            let first = text(stmt, 1), last = text(stmt, 2), org = text(stmt, 3)
            let full = [first, last].compactMap { $0 }.joined(separator: " ")
            if !full.isEmpty { names[pk] = full }
            else if let org, !org.isEmpty { names[pk] = org }
        }

        query(db, "SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER") { stmt in
            let owner = sqlite3_column_int64(stmt, 0)
            guard let number = text(stmt, 1), let name = names[owner] else { return }
            let key = normalize(number)
            if key.count >= 7, map[key] == nil { map[key] = name }
        }

        query(db, "SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS") { stmt in
            let owner = sqlite3_column_int64(stmt, 0)
            guard let addr = text(stmt, 1), let name = names[owner] else { return }
            let key = addr.lowercased()
            if map[key] == nil { map[key] = name }
        }
    }

    private static func query(_ db: OpaquePointer?, _ sql: String,
                              _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}
