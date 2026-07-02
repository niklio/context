import Foundation

/// The distilled profile — the only artifact that ever leaves the extraction
/// pipeline. Stored as plain markdown the user can read, edit, and delete.
enum ProfileStore {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ContextLayer")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var profileURL: URL { directory.appendingPathComponent("profile.md") }

    static func load() -> String? {
        guard let text = try? String(contentsOf: profileURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func save(_ profile: String) {
        try? profile.write(to: profileURL, atomically: true, encoding: .utf8)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: profileURL)
    }

    static var pendingURL: URL { directory.appendingPathComponent("pending.md") }

    static func loadPending() -> String? {
        guard let text = try? String(contentsOf: pendingURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func savePending(_ profile: String) {
        try? profile.write(to: pendingURL, atomically: true, encoding: .utf8)
    }

    static func deletePending() {
        try? FileManager.default.removeItem(at: pendingURL)
    }

    /// The paste-ready injection block for assistants without an API path.
    static func injectionBlock(_ profile: String) -> String {
        """
        Please remember the following about me and use it as standing context \
        in our conversations. It was distilled from my own message history by \
        Context Layer, reviewed and approved by me.

        \(profile)
        """
    }
}
