import Foundation
import Combine

/// Checks for and installs Grok CLI updates via `grok update --check/--json`.
@MainActor
final class GrokCLIUpdateService: ObservableObject {
    static let shared = GrokCLIUpdateService()

    struct UpdateCheck: Equatable {
        let currentVersion: String
        let latestVersion: String
        let updateAvailable: Bool
        let channel: String
        let error: String?
    }

    @Published private(set) var latestCheck: UpdateCheck?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published var statusMessage: String?
    @Published var lastError: String?

    private let dismissedVersionKey = "grok_update_dismissed_version"
    private var lastCheckAt: Date?
    private let minCheckInterval: TimeInterval = 60 * 30 // 30 minutes

    private var dismissedVersion: String {
        get { UserDefaults.standard.string(forKey: dismissedVersionKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: dismissedVersionKey) }
    }

    private init() {}

    var shouldPrompt: Bool {
        guard let check = latestCheck, check.updateAvailable, check.error == nil else { return false }
        return dismissedVersion != check.latestVersion && !isUpdating
    }

    func dismissPrompt() {
        if let latest = latestCheck?.latestVersion {
            dismissedVersion = latest
        }
    }

    /// Soft check used when entering Build. Skips if checked recently unless `force`.
    func checkIfNeeded(force: Bool = false) {
        if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < minCheckInterval {
            return
        }
        Task { await checkForUpdates() }
    }

    func checkForUpdates() async {
        guard !isChecking, !isUpdating else { return }
        guard let executable = GrokCLIResolver.resolveExecutable() else {
            lastError = "Grok CLI not found"
            return
        }

        isChecking = true
        lastError = nil
        defer { isChecking = false }

        do {
            let output = try await run(executable: executable, arguments: ["update", "--check", "--json"])
            let check = try Self.parseCheck(output)
            latestCheck = check
            lastCheckAt = Date()
            if check.updateAvailable {
                statusMessage = "Update available: \(check.currentVersion) → \(check.latestVersion)"
            } else {
                statusMessage = "Grok Build is up to date (\(check.currentVersion))"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs `grok update`, then invokes `onRestart` so Build can remount sessions.
    func performUpdateAndRestart(onRestart: @escaping () -> Void) async {
        guard !isUpdating else { return }
        guard let executable = GrokCLIResolver.resolveExecutable() else {
            lastError = "Grok CLI not found"
            return
        }

        isUpdating = true
        lastError = nil
        statusMessage = "Updating Grok Build…"
        defer { isUpdating = false }

        do {
            let output = try await run(executable: executable, arguments: ["update"])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = trimmed.isEmpty ? "Update complete — restarting…" : String(trimmed.suffix(240))
            await checkForUpdates()
            if let latest = latestCheck?.latestVersion {
                dismissedVersion = latest
            }
            onRestart()
        } catch {
            lastError = error.localizedDescription
            statusMessage = nil
        }
    }

    // MARK: - Process helpers

    private func run(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if process.terminationStatus != 0 {
                        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(
                            throwing: NSError(
                                domain: "GrokCLIUpdate",
                                code: Int(process.terminationStatus),
                                userInfo: [
                                    NSLocalizedDescriptionKey: message.isEmpty
                                        ? "grok update failed (exit \(process.terminationStatus))"
                                        : message
                                ]
                            )
                        )
                        return
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func parseCheck(_ raw: String) throws -> UpdateCheck {
        // CLI may print logs before JSON — take the last JSON object line.
        let line = raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") })
            ?? raw

        guard let data = line.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(
                domain: "GrokCLIUpdate",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not parse update check response"]
            )
        }

        let current = json["currentVersion"] as? String ?? "unknown"
        let latest = json["latestVersion"] as? String ?? current
        let available = json["updateAvailable"] as? Bool ?? false
        let channel = json["channel"] as? String ?? "stable"
        let error = json["error"] as? String
        return UpdateCheck(
            currentVersion: current,
            latestVersion: latest,
            updateAvailable: available,
            channel: channel,
            error: error
        )
    }
}
