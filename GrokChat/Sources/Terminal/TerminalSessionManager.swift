import Foundation
import Combine
import AppKit
import UserNotifications

struct GrokTerminalSession: Identifiable, Equatable {
    let id: UUID
    let threadId: UUID
    let projectPath: String
    let executable: String
    let arguments: [String]
    let launchCommand: String
    let grokSessionId: String?

    static func == (lhs: GrokTerminalSession, rhs: GrokTerminalSession) -> Bool {
        lhs.id == rhs.id
    }
}

extension Notification.Name {
    /// Posted when a terminal session receives PTY output. `userInfo["sessionId"]` is a UUID.
    static let grokTerminalDidReceiveOutput = Notification.Name("GrokTerminalDidReceiveOutput")
    /// Posted when the embedded `grok` process exits (Ctrl+C / quit). Remount follows.
    static let grokTerminalProcessTerminated = Notification.Name("GrokTerminalProcessTerminated")
    /// Build harness actions from menu / global shortcuts.
    static let buildNewSession = Notification.Name("BuildNewSession")
    static let buildOpenSessionSwitcher = Notification.Name("BuildOpenSessionSwitcher")
    static let buildArchiveCurrentSession = Notification.Name("BuildArchiveCurrentSession")
    static let buildSelectNextProject = Notification.Name("BuildSelectNextProject")
    static let buildSelectPreviousProject = Notification.Name("BuildSelectPreviousProject")
    static let buildSelectNextThread = Notification.Name("BuildSelectNextThread")
    static let buildSelectPreviousThread = Notification.Name("BuildSelectPreviousThread")
}

@MainActor
final class TerminalSessionManager: ObservableObject {
    @Published private(set) var sessions: [UUID: GrokTerminalSession] = [:]
    /// Threads with a live terminal surface kept in the view hierarchy (cmux-style mount).
    @Published private(set) var mountedSessions: [GrokTerminalSession] = []
    @Published var activeThreadId: UUID?
    /// Background threads currently emitting terminal output (sidebar spinner).
    @Published private(set) var busyThreadIds: Set<UUID> = []
    /// Threads that hit a remount storm — show Restart instead of looping.
    @Published private(set) var remountPausedThreadIds: Set<UUID> = []
    /// Model used for relaunch / new mounts (kept in sync by BuildRootView).
    var preferredModel: String?

    private var idleWorkItems: [UUID: DispatchWorkItem] = [:]
    private var outputObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var sessionCaptureWork: [UUID: DispatchWorkItem] = [:]
    private var remountTimestamps: [UUID: [Date]] = [:]
    private var launchedAt: [UUID: Date] = [:]
    private let idleQuietInterval: TimeInterval = 2.0

    init() {
        outputObserver = NotificationCenter.default.addObserver(
            forName: .grokTerminalDidReceiveOutput,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessionId = note.userInfo?["sessionId"] as? UUID else { return }
            Task { @MainActor in
                self?.noteOutput(forSessionId: sessionId)
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: .grokTerminalProcessTerminated,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessionId = note.userInfo?["sessionId"] as? UUID else { return }
            let code = note.userInfo?["exitCode"] as? Int32
            Task { @MainActor in
                self?.handleProcessTerminated(sessionId: sessionId, exitCode: code)
            }
        }
    }

    deinit {
        if let outputObserver {
            NotificationCenter.default.removeObserver(outputObserver)
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    func session(for threadId: UUID) -> GrokTerminalSession? {
        sessions.values.first { $0.threadId == threadId }
    }

    @discardableResult
    func ensureSession(
        threadId: UUID,
        projectPath: String,
        grokSessionId: String? = nil,
        model: String? = nil
    ) -> GrokTerminalSession? {
        // Never create a dead session while CLI is missing — it sticks as /usr/bin/false.
        guard GrokCLIResolver.isAvailable else { return nil }

        if let existing = session(for: threadId) {
            // Repair dead placeholder / deleted binary; CLI updates remount via `remount` / clearAll.
            if existing.executable == "/usr/bin/false"
                || !FileManager.default.isExecutableFile(atPath: existing.executable) {
                removeSession(for: threadId)
            } else {
                return existing
            }
        }

        let launch = Self.buildLaunch(
            projectPath: projectPath,
            grokSessionId: grokSessionId,
            model: model ?? preferredModel,
            continueMostRecent: false
        )
        guard launch.executable != "/usr/bin/false" else { return nil }

        let session = GrokTerminalSession(
            id: UUID(),
            threadId: threadId,
            projectPath: projectPath,
            executable: launch.executable,
            arguments: launch.arguments,
            launchCommand: launch.displayCommand,
            grokSessionId: grokSessionId
        )
        sessions[session.id] = session
        launchedAt[threadId] = Date()
        return session
    }

    /// Lazily create session metadata and mount a persistent terminal view for this thread.
    @discardableResult
    func ensureMounted(
        threadId: UUID,
        projectPath: String,
        grokSessionId: String? = nil,
        model: String? = nil
    ) -> GrokTerminalSession? {
        remountPausedThreadIds.remove(threadId)
        guard let session = ensureSession(
            threadId: threadId,
            projectPath: projectPath,
            grokSessionId: grokSessionId,
            model: model
        ) else { return nil }
        if !mountedSessions.contains(where: { $0.threadId == threadId }) {
            mountedSessions.append(session)
        }
        scheduleSessionCapture(threadId: threadId, projectPath: projectPath)
        return session
    }

    /// Tear down and remount with the latest CLI binary + resume args (update-safe).
    @discardableResult
    func remount(
        threadId: UUID,
        projectPath: String,
        grokSessionId: String?,
        model: String? = nil,
        continueMostRecent: Bool = false
    ) -> GrokTerminalSession? {
        if let existing = session(for: threadId) {
            GrokGhosttyTerminalNSView.prepareForReplacement(sessionId: existing.id)
        }
        removeSession(for: threadId)

        let resumeID = grokSessionId
            ?? GrokSessionResolver.newestSessionID(forProjectPath: projectPath)
        let launch = Self.buildLaunch(
            projectPath: projectPath,
            grokSessionId: resumeID,
            model: model ?? preferredModel,
            continueMostRecent: continueMostRecent && (resumeID == nil || resumeID?.isEmpty == true)
        )
        guard launch.executable != "/usr/bin/false" else { return nil }

        let session = GrokTerminalSession(
            id: UUID(),
            threadId: threadId,
            projectPath: projectPath,
            executable: launch.executable,
            arguments: launch.arguments,
            launchCommand: launch.displayCommand,
            grokSessionId: resumeID
        )
        sessions[session.id] = session
        mountedSessions.append(session)
        launchedAt[threadId] = Date()
        if let resumeID, !resumeID.isEmpty {
            WorkspaceStore.shared.setGrokSessionId(resumeID, for: threadId)
        }
        scheduleSessionCapture(threadId: threadId, projectPath: projectPath)
        return session
    }

    func manualRemount(threadId: UUID) {
        remountPausedThreadIds.remove(threadId)
        guard let existing = session(for: threadId)
                ?? mountedSessions.first(where: { $0.threadId == threadId }) else { return }
        let stored = WorkspaceStore.shared.allThreadsFlat().first(where: { $0.id == threadId })?.grokSessionId
        _ = remount(
            threadId: threadId,
            projectPath: existing.projectPath,
            grokSessionId: stored ?? existing.grokSessionId,
            continueMostRecent: true
        )
        activate(threadId: threadId)
    }

    func activate(threadId: UUID) {
        activeThreadId = threadId
        // Viewing a thread clears busy chrome for that row.
        if busyThreadIds.contains(threadId) {
            busyThreadIds.remove(threadId)
        }
        idleWorkItems[threadId]?.cancel()
        idleWorkItems[threadId] = nil
    }

    func removeSession(for threadId: UUID) {
        mountedSessions.removeAll { $0.threadId == threadId }
        if let session = session(for: threadId) {
            GrokGhosttyTerminalNSView.prepareForReplacement(sessionId: session.id)
            sessions.removeValue(forKey: session.id)
        }
        busyThreadIds.remove(threadId)
        idleWorkItems[threadId]?.cancel()
        idleWorkItems[threadId] = nil
        sessionCaptureWork[threadId]?.cancel()
        sessionCaptureWork[threadId] = nil
        launchedAt[threadId] = nil
        if activeThreadId == threadId {
            activeThreadId = mountedSessions.last?.threadId
        }
    }

    func removeSessions(forProjectPath path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let threadIds = sessions.values
            .filter { URL(fileURLWithPath: $0.projectPath).standardizedFileURL.path == normalized }
            .map(\.threadId)
        for threadId in threadIds {
            removeSession(for: threadId)
        }
    }

    func clearAllSessions() {
        for item in idleWorkItems.values { item.cancel() }
        idleWorkItems.removeAll()
        for item in sessionCaptureWork.values { item.cancel() }
        sessionCaptureWork.removeAll()
        busyThreadIds.removeAll()
        remountPausedThreadIds.removeAll()
        remountTimestamps.removeAll()
        launchedAt.removeAll()
        mountedSessions.removeAll()
        sessions.removeAll()
        activeThreadId = nil
    }

    /// Send text into the active Grok Build session. When `submit` is true, appends newline.
    @discardableResult
    func sendToActiveSession(_ text: String, submit: Bool) -> Bool {
        guard let threadId = activeThreadId,
              let session = session(for: threadId) else { return false }
        var payload = text
        if submit, !payload.hasSuffix("\n") {
            payload += "\n"
        }
        return GrokGhosttyTerminalNSView.send(to: session.id, text: payload)
    }

    func focusActiveSession() {
        guard let threadId = activeThreadId,
              let session = session(for: threadId) else { return }
        _ = GrokGhosttyTerminalNSView.focus(sessionId: session.id)
    }

    /// Drop any placeholder sessions once the real CLI becomes available.
    func invalidatePlaceholderSessions() {
        let brokenThreadIds = sessions.values
            .filter { $0.executable == "/usr/bin/false" || !FileManager.default.isExecutableFile(atPath: $0.executable) }
            .map(\.threadId)
        for threadId in brokenThreadIds {
            removeSession(for: threadId)
        }
    }

    // MARK: - PTY activity → busy / unread

    private func noteOutput(forSessionId sessionId: UUID) {
        guard let session = sessions[sessionId] else { return }
        let threadId = session.threadId

        // Active (viewed) thread: no spinner/unread for itself.
        guard threadId != activeThreadId else {
            idleWorkItems[threadId]?.cancel()
            idleWorkItems[threadId] = nil
            busyThreadIds.remove(threadId)
            return
        }

        let wasBusy = busyThreadIds.contains(threadId)
        if !wasBusy {
            busyThreadIds.insert(threadId)
        }

        idleWorkItems[threadId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.busyThreadIds.contains(threadId) else { return }
            self.busyThreadIds.remove(threadId)
            // Background work went quiet → ready badge.
            if self.activeThreadId != threadId {
                WorkspaceStore.shared.setThreadUnread(threadId, unread: true)
                Self.postReadyNotificationIfNeeded(threadId: threadId)
            }
            self.idleWorkItems[threadId] = nil
        }
        idleWorkItems[threadId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleQuietInterval, execute: work)
    }

    // MARK: - Terminate → resume remount

    private func handleProcessTerminated(sessionId: UUID, exitCode: Int32?) {
        guard let session = sessions[sessionId] else { return }
        let threadId = session.threadId
        let projectPath = session.projectPath

        // Capture session id from disk before remount when possible.
        if let newest = GrokSessionResolver.newestSessionID(forProjectPath: projectPath) {
            WorkspaceStore.shared.setGrokSessionId(newest, for: threadId)
        }

        // Crash-loop guard: >3 exits in 20s → pause auto-remount.
        let now = Date()
        var stamps = (remountTimestamps[threadId] ?? []).filter { now.timeIntervalSince($0) < 20 }
        stamps.append(now)
        remountTimestamps[threadId] = stamps
        if stamps.count > 3 {
            remountPausedThreadIds.insert(threadId)
            return
        }

        // Fresh launch that dies immediately — don't spin forever.
        if let launched = launchedAt[threadId], now.timeIntervalSince(launched) < 1.2,
           exitCode != nil, exitCode != 0, exitCode != 130 {
            remountPausedThreadIds.insert(threadId)
            return
        }

        let stored = WorkspaceStore.shared.allThreadsFlat().first(where: { $0.id == threadId })?.grokSessionId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            guard !self.remountPausedThreadIds.contains(threadId) else { return }
            _ = self.remount(
                threadId: threadId,
                projectPath: projectPath,
                grokSessionId: stored,
                continueMostRecent: stored == nil
            )
            if self.activeThreadId == nil || self.activeThreadId == threadId {
                self.activate(threadId: threadId)
            }
        }
    }

    private func scheduleSessionCapture(threadId: UUID, projectPath: String) {
        sessionCaptureWork[threadId]?.cancel()
        let started = launchedAt[threadId] ?? Date()
        // Poll ~/.grok/sessions for a new/updated ID and bind it to the thread.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.captureSessionID(threadId: threadId, projectPath: projectPath, since: started, attempt: 0)
        }
        sessionCaptureWork[threadId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func captureSessionID(threadId: UUID, projectPath: String, since: Date, attempt: Int) {
        let existing = WorkspaceStore.shared.allThreadsFlat().first(where: { $0.id == threadId })?.grokSessionId
        if let id = GrokSessionResolver.newestSessionID(forProjectPath: projectPath, createdAfter: since)
            ?? GrokSessionResolver.newestSessionID(forProjectPath: projectPath),
           existing != id {
            WorkspaceStore.shared.setGrokSessionId(id, for: threadId)
            return
        }
        guard attempt < 8 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.captureSessionID(threadId: threadId, projectPath: projectPath, since: since, attempt: attempt + 1)
        }
        sessionCaptureWork[threadId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    static func buildLaunch(
        projectPath: String,
        grokSessionId: String?,
        model: String?,
        continueMostRecent: Bool = false
    ) -> (executable: String, arguments: [String], displayCommand: String) {
        // Always resolve at launch time so CLI updates never stick us to a stale path.
        guard let executable = GrokCLIResolver.resolveExecutable() else {
            return ("/usr/bin/false", [], "/usr/bin/false")
        }

        // Stable public CLI flags only — safe across grok updates.
        var arguments = ["--no-leader"]
        if let model, model != "auto", !model.isEmpty {
            arguments.append(contentsOf: ["-m", model])
        }
        if let grokSessionId, !grokSessionId.isEmpty {
            arguments.append(contentsOf: ["-r", grokSessionId])
        } else if continueMostRecent {
            arguments.append("--continue")
        }
        arguments.append(contentsOf: ["--cwd", projectPath])

        let display = ([executable] + arguments.map(shellQuote)).joined(separator: " ")
        return (executable, arguments, display)
    }

    /// Kept for call sites that still want a shell-quoted one-liner.
    static func buildLaunchCommand(
        projectPath: String,
        grokSessionId: String?,
        model: String?
    ) -> String {
        buildLaunch(projectPath: projectPath, grokSessionId: grokSessionId, model: model).displayCommand
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func postReadyNotificationIfNeeded(threadId: UUID) {
        guard !NSApp.isActive else { return }
        let projectName = WorkspaceStore.shared.allProjectsSorted()
            .first(where: { $0.threads.contains(where: { $0.id == threadId }) })?
            .name ?? "Grok Build"
        let threadTitle = WorkspaceStore.shared.allThreadsFlat()
            .first(where: { $0.id == threadId })?
            .title ?? "Chat"
        let content = UNMutableNotificationContent()
        content.title = "Agent ready"
        content.body = "\(threadTitle) · \(projectName)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "build-ready-\(threadId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}
