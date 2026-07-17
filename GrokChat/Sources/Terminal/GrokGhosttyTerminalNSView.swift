import AppKit
import SwiftTerm

/// Hosts the official `grok` TUI inside a real VT100/xterm emulator (SwiftTerm).
final class GrokGhosttyTerminalNSView: NSView, LocalProcessTerminalViewDelegate {
    private static var registry: [UUID: WeakTerminalRef] = [:]
    private static let registryLock = NSLock()

    private let sessionId: UUID
    private let executable: String
    private let arguments: [String]
    private let workingDirectory: String?

    private var terminalView: LocalProcessTerminalView?
    private var didLaunch = false
    private var launchError: String?
    private var isRelaunching = false
    private var statusOverlay: NSTextField?

    init(
        sessionId: UUID,
        executable: String,
        arguments: [String],
        workingDirectory: String?
    ) {
        self.sessionId = sessionId
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = GrokTerminalTheme.backgroundColor.cgColor
        Self.register(self, for: sessionId)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        Self.unregister(sessionId)
        terminalView?.terminate()
    }

    @discardableResult
    static func send(to sessionId: UUID, text: String) -> Bool {
        registryLock.lock()
        let view = registry[sessionId]?.view
        registryLock.unlock()
        guard let view else { return false }
        view.sendInput(text)
        return true
    }

    @discardableResult
    static func focus(sessionId: UUID) -> Bool {
        registryLock.lock()
        let view = registry[sessionId]?.view
        registryLock.unlock()
        guard let view else { return false }
        view.focusTerminal()
        return true
    }

    static func prepareForReplacement(sessionId: UUID) {
        registryLock.lock()
        let view = registry[sessionId]?.view
        registryLock.unlock()
        view?.prepareForReplacement()
    }

    func sendInput(_ text: String) {
        guard !text.isEmpty else {
            focusTerminal()
            return
        }
        terminalView?.send(txt: text)
        focusTerminal()
    }

    func focusTerminal() {
        if let terminalView {
            window?.makeFirstResponder(terminalView)
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        isHidden = !visible
        if visible {
            focusTerminal()
            launchWhenReady()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            launchWhenReady()
        }
    }

    override func layout() {
        super.layout()
        terminalView?.frame = bounds
        launchWhenReady()
    }

    private func launchWhenReady() {
        guard !didLaunch else { return }
        guard window != nil, bounds.width > 40, bounds.height > 40 else { return }
        didLaunch = true

        if let workingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                showInlineError(
                    "Folder not found:\n\(workingDirectory)\n\nRelocate this project or open a different folder."
                )
                return
            }
        }

        guard FileManager.default.isExecutableFile(atPath: executable) else {
            let label = (executable as NSString).lastPathComponent.lowercased().contains("grok")
                ? "Grok CLI not found at:\n\(executable)"
                : "Executable not found:\n\(executable)"
            showInlineError(label)
            return
        }

        let term = GrokActivityAwareTerminalView(frame: bounds, sessionId: sessionId)
        term.autoresizingMask = [.width, .height]
        term.processDelegate = self
        term.nativeForegroundColor = GrokTerminalTheme.foregroundColor
        term.nativeBackgroundColor = GrokTerminalTheme.backgroundColor
        addSubview(term)
        terminalView = term

        var environment = Terminal.getEnvironmentVariables()
        // Ensure TUI sees a capable xterm.
        environment = environment.map { entry in
            if entry.hasPrefix("TERM=") { return "TERM=xterm-256color" }
            return entry
        }
        if !environment.contains(where: { $0.hasPrefix("TERM=") }) {
            environment.append("TERM=xterm-256color")
        }
        if !environment.contains(where: { $0.hasPrefix("COLORTERM=") }) {
            environment.append("COLORTERM=truecolor")
        }
        if !environment.contains(where: { $0.hasPrefix("TERM_PROGRAM=") }) {
            environment.append("TERM_PROGRAM=Grok")
        }

        term.startProcess(
            executable: executable,
            args: arguments,
            environment: environment,
            execName: nil,
            currentDirectory: workingDirectory
        )

        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
        }
    }

    private func showInlineError(_ message: String) {
        launchError = message
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private static func register(_ view: GrokGhosttyTerminalNSView, for sessionId: UUID) {
        registryLock.lock()
        registry[sessionId] = WeakTerminalRef(view: view)
        registryLock.unlock()
    }

    private static func unregister(_ sessionId: UUID) {
        registryLock.lock()
        registry.removeValue(forKey: sessionId)
        registryLock.unlock()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let isGrokAgent = (executable as NSString).lastPathComponent.lowercased().contains("grok")
        if isGrokAgent {
            // Harness remounts via TerminalSessionManager with fresh CLI path + resume args.
            showStatusOverlay("Session ended — restoring…")
        } else {
            let code = exitCode.map { String($0) } ?? "?"
            showStatusOverlay("Shell exited (\(code)) — use Restart to open a new shell")
        }
        NotificationCenter.default.post(
            name: .grokTerminalProcessTerminated,
            object: nil,
            userInfo: [
                "sessionId": sessionId,
                "exitCode": exitCode as Any
            ]
        )
    }

    /// Tear down the dead PTY surface (SwiftUI will mount a replacement session).
    func prepareForReplacement() {
        isRelaunching = true
        terminalView?.terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
        didLaunch = false
        clearInlineErrorViews()
        hideStatusOverlay()
    }

    private func showStatusOverlay(_ message: String) {
        if statusOverlay == nil {
            let label = NSTextField(labelWithString: message)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.alignment = .center
            label.drawsBackground = true
            label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
            label.wantsLayer = true
            label.layer?.cornerRadius = 8
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
            ])
            statusOverlay = label
        }
        statusOverlay?.stringValue = "  \(message)  "
        statusOverlay?.isHidden = false
    }

    private func hideStatusOverlay() {
        statusOverlay?.isHidden = true
    }

    private func clearInlineErrorViews() {
        for sub in subviews where sub is NSTextField && sub !== statusOverlay {
            sub.removeFromSuperview()
        }
        launchError = nil
    }
}

private final class WeakTerminalRef {
    weak var view: GrokGhosttyTerminalNSView?
    init(view: GrokGhosttyTerminalNSView) { self.view = view }
}

/// Posts PTY output notifications so the sidebar can show busy/unread state.
private final class GrokActivityAwareTerminalView: LocalProcessTerminalView {
    private let sessionId: UUID
    private var lastPost: CFAbsoluteTime = 0

    init(frame: CGRect, sessionId: UUID) {
        self.sessionId = sessionId
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        // Ignore cursor blink / pure CSI redraws — those were keeping project
        // spinners stuck forever on idle Grok Build TUIs.
        guard Self.looksLikeAgentActivity(slice) else { return }
        // Throttle: real agent streams are chatty; ~5Hz is enough for spinner UX.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPost >= 0.2 else { return }
        lastPost = now
        NotificationCenter.default.post(
            name: .grokTerminalDidReceiveOutput,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    /// True when the chunk contains enough printable text to imply agent work,
    /// not just ANSI cursor/style housekeeping.
    private static func looksLikeAgentActivity(_ slice: ArraySlice<UInt8>) -> Bool {
        var printable = 0
        var i = slice.startIndex
        while i < slice.endIndex {
            let byte = slice[i]
            i = slice.index(after: i)

            if byte == 0x1B { // ESC — skip CSI / OSC-ish sequences
                while i < slice.endIndex {
                    let c = slice[i]
                    i = slice.index(after: i)
                    // CSI/OSC final byte in the ASCII @–~ range.
                    if (0x40...0x7E).contains(c) { break }
                }
                continue
            }

            // Whitespace / BEL / backspace — not activity by themselves.
            if byte == 7 || byte == 8 || byte == 9 || byte == 10 || byte == 13 {
                continue
            }

            if (32..<127).contains(byte) || byte >= 0xC0 {
                printable += 1
                if printable >= 4 { return true }
            }
        }
        return false
    }
}
