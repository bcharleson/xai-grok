import AppKit
import Foundation

/// Locates the `grok` CLI binary (same install as Terminal / VS Code extension).
enum GrokCLIResolver {
    private static let candidatePaths: [String] = [
        "/usr/local/bin/grok",
        "/opt/homebrew/bin/grok",
        "\(NSHomeDirectory())/.local/bin/grok",
        "\(NSHomeDirectory())/.grok/bin/grok",
    ]

    static let installDocsURL = URL(string: "https://x.ai/cli")!
    static let installCommand = "curl -fsSL https://x.ai/cli/install.sh | bash"

    /// Opens Terminal and runs the official install script from x.ai/cli.
    @discardableResult
    static func launchInstall() -> Bool {
        let escaped = installCommand.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil { return true }
        }
        NSWorkspace.shared.open(installDocsURL)
        return false
    }

    static func resolveExecutable() -> String? {
        if let env = ProcessInfo.processInfo.environment["GROK_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }

        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return which("grok")
    }

    static var isAvailable: Bool {
        resolveExecutable() != nil
    }

    static func version() -> String? {
        guard let executable = resolveExecutable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Poll until the CLI appears (or timeout). Used after kicking off install.
    static func waitUntilAvailable(
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 1.5,
        onTick: ((TimeInterval) -> Void)? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            if isAvailable {
                DispatchQueue.main.async { completion(true) }
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                DispatchQueue.main.async { completion(false) }
                return
            }
            onTick?(timeout - remaining)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pollInterval) {
                tick()
            }
        }
        DispatchQueue.global(qos: .utility).async { tick() }
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        // Login shell PATH so ~/.local/bin and Homebrew are visible.
        process.arguments = ["-lc", "which \(name)"]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty,
                  FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }
}
