import AppKit
import os

/// Terminal logging channel. The type name is kept so existing Build shell
/// callsites do not care whether Ghostty or the native fallback is backing it.
let grokGhosttyLog = Logger(subsystem: "com.xai.Grok", category: "terminal")

enum GrokGhosttyBootstrap {
    static func bootstrapProcess() {
        configureEnvironment()
    }

    static func configureEnvironment() {
        if getenv("TERM") == nil {
            setenv("TERM", "xterm-256color", 1)
        }
        if getenv("COLORTERM") == nil {
            setenv("COLORTERM", "truecolor", 1)
        }
        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "Grok", 1)
        }
    }
}

final class GrokGhosttyApp {
    static let shared = GrokGhosttyApp()

    private init() {}

    func initializeIfNeeded() {
        GrokGhosttyBootstrap.configureEnvironment()
    }
}
