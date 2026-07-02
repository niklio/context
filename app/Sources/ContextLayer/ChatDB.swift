import Foundation
import SQLite3

struct Message {
    let date: Date
    let isFromMe: Bool
    let sender: String?          // handle id (phone/email); nil when from me
    let text: String?
    let tapback: String?         // loved/liked/... when this row is a reaction
    let hasAttachment: Bool
    let isSystemEvent: Bool      // group renames, member changes, etc.
}

struct Chat {
    let identifier: String
    let displayName: String?
    let isGroup: Bool
    var participants: [String]
    var messages: [Message]
}

struct ExtractionResult {
    let chats: [Chat]
    let recoveredFromBlob: Int
}

enum ChatDBError: LocalizedError {
    case notFound(String)
    case notReadable(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "No Messages database at \(p)"
        case .notReadable(let p): return "Can't read \(p) — Full Disk Access is required"
        case .sqlite(let m): return "Database error: \(m)"
        }
    }
}

/// Reads a copy of chat.db. Never touches the live store: db+wal+shm are
/// copied to a temp dir, the WAL is checkpointed on the copy (so messages
/// still sitting in the WAL are included), and the copy is deleted after.
enum ChatDB {
    static let appleEpochOffset: TimeInterval = 978_307_200  // 2001-01-01 UTC

    static var defaultPath: String {
        NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
    }

    static let tapbacks: [Int: String] = [
        2000: "loved", 2001: "liked", 2002: "disliked",
        2003: "laughed", 2004: "emphasized", 2005: "questioned",
    ]

    /// Full Disk Access probe: the file exists for every iMessage user, but
    /// reads fail with EPERM until FDA is granted.
    static func canRead(path: String = defaultPath) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
            && (try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)).close()) != nil
    }

    static func extract(path: String = defaultPath) throws -> ExtractionResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw ChatDBError.notFound(path) }
        guard canRead(path: path) else { throw ChatDBError.notReadable(path) }

        let tmp = fm.temporaryDirectory.appendingPathComponent("cl-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let snap = tmp.appendingPathComponent("chat.db").path
        try fm.copyItem(atPath: path, toPath: snap)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: snap + suffix)
        }

        var db: OpaquePointer?
        guard sqlite3_open(snap, &db) == SQLITE_OK else {
            throw ChatDBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)

        var chats: [Int64: Chat] = [:]
        try query(db, """
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.style
            FROM chat c
            """) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            chats[rowid] = Chat(
                identifier: column(stmt, 1) ?? "",
                displayName: column(stmt, 2).flatMap { $0.isEmpty ? nil : $0 },
                isGroup: sqlite3_column_int(stmt, 3) == 43,
                participants: [],
                messages: [])
        }

        var participants: [Int64: [String]] = [:]
        try query(db, """
            SELECT chj.chat_id, h.id FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id ORDER BY h.id
            """) { stmt in
            let chatID = sqlite3_column_int64(stmt, 0)
            if let handle = column(stmt, 1) {
                participants[chatID, default: []].append(handle)
            }
        }
        for (id, p) in participants {
            chats[id]?.participants = p.removingDuplicates()
        }

        var recovered = 0
        try query(db, """
            SELECT cmj.chat_id, m.date, m.is_from_me, m.text, m.attributedBody,
                   m.associated_message_type, m.cache_has_attachments,
                   m.item_type, h.id
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            ORDER BY m.date
            """) { stmt in
            let chatID = sqlite3_column_int64(stmt, 0)
            guard chats[chatID] != nil else { return }

            var text = column(stmt, 3)
            if text == nil || text!.isEmpty,
               let blob = columnBlob(stmt, 4),
               let decoded = TypedStream.decodeText(blob) {
                text = decoded
                recovered += 1
            }

            let rawDate = sqlite3_column_int64(stmt, 1)
            // Pre-High-Sierra rows stored seconds, not nanoseconds.
            let secs = rawDate > 1_000_000_000_000 ? Double(rawDate) / 1e9 : Double(rawDate)
            let assoc = Int(sqlite3_column_int(stmt, 5))

            chats[chatID]!.messages.append(Message(
                date: Date(timeIntervalSince1970: secs + appleEpochOffset),
                isFromMe: sqlite3_column_int(stmt, 2) == 1,
                sender: column(stmt, 8),
                text: text,
                tapback: tapbacks[assoc],
                hasAttachment: sqlite3_column_int(stmt, 6) == 1,
                isSystemEvent: sqlite3_column_int(stmt, 7) != 0))
        }

        let sorted = chats.values
            .filter { !$0.messages.isEmpty }
            .sorted { $0.messages.count > $1.messages.count }
        return ExtractionResult(chats: sorted, recoveredFromBlob: recovered)
    }

    // MARK: - SQLite helpers

    private static func query(_ db: OpaquePointer?, _ sql: String,
                              _ row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ChatDBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func column(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private static func columnBlob(_ stmt: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
