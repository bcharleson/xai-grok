import AppKit

enum GrokTerminalTheme {
    static var backgroundColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.06, alpha: 1)
                : NSColor(calibratedWhite: 0.98, alpha: 1)
        }
    }

    static var foregroundColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.88, alpha: 1)
                : NSColor(calibratedWhite: 0.12, alpha: 1)
        }
    }
}
