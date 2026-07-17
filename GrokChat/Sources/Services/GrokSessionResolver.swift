import Foundation

/// Maps project folders → official Grok CLI session IDs under `~/.grok/sessions`.
/// Harness enhancements stay resilient across CLI updates by reading the on-disk layout
/// and only using stable flags (`-r`, `--continue`, `--cwd`, `--no-leader`).
enum GrokSessionResolver {
    private static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions", isDirectory: true)
    }

    /// Percent-encode the absolute path the same way the CLI stores project folders.
    static func encodedPathComponent(forProjectPath path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        var allowed = CharacterSet.alphanumerics
        // Encode everything else (including `/`) like `quote(path, safe='')`.
        allowed.insert(charactersIn: "-._~")
        return normalized.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? normalized.replacingOccurrences(of: "/", with: "%2F")
    }

    static func sessionsDirectory(forProjectPath path: String) -> URL {
        sessionsRoot.appendingPathComponent(encodedPathComponent(forProjectPath: path), isDirectory: true)
    }

    struct SessionRef: Equatable {
        let id: String
        let modifiedAt: Date
    }

    /// All session IDs for a project folder, newest first.
    static func listSessions(forProjectPath path: String) -> [SessionRef] {
        let dir = sessionsDirectory(forProjectPath: path)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let uuidLike = names.filter { looksLikeSessionID($0) }
        return uuidLike.compactMap { name -> SessionRef? in
            let url = dir.appendingPathComponent(name, isDirectory: true)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            return SessionRef(id: name, modifiedAt: modified)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func newestSessionID(forProjectPath path: String) -> String? {
        listSessions(forProjectPath: path).first?.id
    }

    /// Prefer a session created/updated after `since` (for binding a fresh TUI launch).
    static func newestSessionID(forProjectPath path: String, createdAfter since: Date) -> String? {
        listSessions(forProjectPath: path)
            .first(where: { $0.modifiedAt >= since.addingTimeInterval(-1) })?
            .id
    }

    static func looksLikeSessionID(_ value: String) -> Bool {
        // UUID (with or without hyphens) or grok-style 019e… ids.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
