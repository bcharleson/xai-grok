import Foundation
import Combine

/// Routes Build-mode agent runs through official Grok CLI (ACP) when available.
final class AgentOrchestrator: ObservableObject {
    static let shared = AgentOrchestrator()

    let store = WorkspaceStore.shared

    @Published var isACPActive = false
    @Published var acpStatus: String = ""
    @Published var lastError: String?
    @Published private(set) var isSessionReady = false
    @Published private(set) var isPrewarming = false
    @Published private(set) var prewarmFailed = false

    private var acpClient: GrokBuildACPClient?
    private var warmThreadId: UUID?
    private var warmProjectPath: String?
    private var warmMode: GrokBuildMode?
    private var isWarming = false
    private var isCreatingSession = false
    private var sessionWaitCompletions: [(Result<String, Error>) -> Void] = []
    private var activeThreadId: UUID?
    private var activeAssistantMessageId: UUID?
    private var onMessagesUpdate: ((UUID, (inout [ChatMessage]) -> Void) -> Void)?
    private var onComplete: (() -> Void)?
    private var onStatusChange: ((String) -> Void)?
    private var onFailure: (() -> Void)?

    /// Serializes warm + send so they never race on `session/new`.
    private let acpQueue = DispatchQueue(label: "com.grokchat.acp.lifecycle", qos: .userInitiated)

    private static let bootstrapStatusTitles: Set<String> = [
        "Starting Grok agent...",
        "Starting Grok CLI…",
        "Starting agent…",
        "Creating session...",
        "Preparing session…",
        "Waiting for Grok agent...",
        "Connecting…",
        "Grok CLI…"
    ]

    private struct PendingSend {
        let text: String
        let threadId: UUID
        let projectPath: URL
        let mode: GrokBuildMode
        let model: String?
        let assistantMessageId: UUID
    }

    private var pendingSend: PendingSend?
    private var bootstrapWatchdog: DispatchWorkItem?
    private var pendingSendWatchdog: DispatchWorkItem?
    private var turnWatchdog: DispatchWorkItem?

    private init() {}

    private func setStatus(_ status: String) {
        acpStatus = status
        guard !status.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStatusChange?(status)
            guard let messageId = self.activeAssistantMessageId else { return }
            let icon: String
            if status.localizedCaseInsensitiveContains("session") {
                icon = "point.3.connected.trianglepath.dotted"
            } else if status.localizedCaseInsensitiveContains("think") {
                icon = "brain.head.profile"
            } else if status.localizedCaseInsensitiveContains("tool") || status.localizedCaseInsensitiveContains("command") {
                icon = "wrench.and.screwdriver"
            } else if status.localizedCaseInsensitiveContains("start") {
                icon = "bolt.horizontal.circle"
            } else {
                icon = "gearshape"
            }
            self.onMessagesUpdate?(messageId) { msgs in
                guard let idx = msgs.firstIndex(where: { $0.id == messageId }) else { return }
                if Self.bootstrapStatusTitles.contains(status),
                   var last = msgs[idx].activityLines.last,
                   last.isInProgress,
                   Self.bootstrapStatusTitles.contains(last.title) {
                    last.title = status
                    last.icon = icon
                    msgs[idx].activityLines[msgs[idx].activityLines.count - 1] = last
                    return
                }
                Self.appendActivityLine(
                    to: &msgs[idx],
                    icon: icon,
                    title: status,
                    detail: nil,
                    inProgress: true
                )
            }
        }
    }

    func hasWarmSession(threadId: UUID, projectPath: URL, mode: GrokBuildMode, model: String? = nil) -> Bool {
        let normalizedPath = GrokBuildACPClient.normalizedPath(projectPath)
        guard isSessionReady,
              let client = acpClient,
              client.matchesConfiguration(mode: mode, model: model, cwd: projectPath),
              client.acpSessionId != nil,
              warmProjectPath == normalizedPath,
              warmMode == mode else {
            return false
        }
        return true
    }

    private func markSessionReady(threadId: UUID, projectPath: URL, mode: GrokBuildMode) {
        warmThreadId = threadId
        warmProjectPath = GrokBuildACPClient.normalizedPath(projectPath)
        warmMode = mode
        DispatchQueue.main.async {
            self.isSessionReady = true
            self.isPrewarming = false
            self.prewarmFailed = false
        }
    }

    private func clearSessionReady() {
        DispatchQueue.main.async {
            self.isSessionReady = false
        }
    }

    /// Pre-start the Grok agent in the background so the first tool request is fast.
    func warmSession(projectPath: URL, mode: GrokBuildMode, threadId: UUID, model: String? = nil) {
        guard mode != .chat else { return }
        acpQueue.async { [weak self] in
            self?.warmSessionOnQueue(projectPath: projectPath, mode: mode, threadId: threadId, model: model)
        }
    }

    /// Runs initialize → session/new → short prompt to verify the CLI adapter.
    func runHarnessProbe(
        projectPath: URL,
        mode: GrokBuildMode = .agentAuto,
        completion: @escaping (GrokBuildACPProbeResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            GrokBuildACPClient.probe(cwd: projectPath, mode: mode, completion: completion)
        }
    }

    /// Use ACP when the session is already warm or the message needs local tools/agent work.
    func shouldUseACP(
        auth: GrokBuildAuthManager,
        threadId: UUID,
        projectPath: URL,
        mode: GrokBuildMode,
        text: String,
        model: String? = nil
    ) -> Bool {
        guard mode != .chat else { return false }
        guard GrokCLIResolver.isAvailable,
              auth.isUsingGrokBuildSession || auth.detectGrokBuildCLISession() != nil else {
            return false
        }
        if hasWarmSession(threadId: threadId, projectPath: projectPath, mode: mode, model: model) {
            return true
        }
        return Self.messageLikelyNeedsAgent(text)
    }

    static func messageLikelyNeedsAgent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = [
            "what's in", "what is in", "this folder", "this directory", "this project",
            "run ", "execute", "create ", "write ", "delete", "fix ", "implement", "build ",
            "refactor", "grep", "terminal", "npm ", "git ", "xcode", "mkdir", "deploy",
            "debug", "compile", "install", "codebase", "read file", "edit ", "modify ",
            "update ", "add ", "remove ", "open ", "search ", "find ", "list ", "scan ",
            "folder", "directory", "file", "files", "workspace", "repo", "project"
        ]
        if text.contains("/") || text.contains(".swift") || text.contains(".ts")
            || text.contains(".py") || text.contains(".json") {
            return true
        }
        let followUps = ["what's there", "what is there", "whats there", "show me", "anything there", "what do you see"]
        if followUps.contains(where: { lower.contains($0) }) { return true }
        return keywords.contains { lower.contains($0) }
    }

    func bootstrap(projectPath: URL) {
        store.ensureDefaultWorkspace(projectPath: projectPath)
        store.pruneDuplicateEmptyThreads()
    }

    func syncThreadFromUI(threadId: UUID, messages: [ChatMessage], title: String?) {
        guard var thread = store.selectedThread, thread.id == threadId else { return }
        thread.messages = messages
        thread.lastModified = Date()
        if let title, !title.isEmpty, thread.title == "New Chat" || thread.title == "New Thread" {
            thread.title = title
        }
        store.updateThread(thread)
    }

    func sendPrompt(
        text: String,
        threadId: UUID,
        projectPath: URL,
        mode: GrokBuildMode,
        model: String?,
        assistantMessageId: UUID,
        onUpdate: @escaping (UUID, (inout [ChatMessage]) -> Void) -> Void,
        onComplete: @escaping () -> Void,
        onStatusChange: ((String) -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        self.activeThreadId = threadId
        self.activeAssistantMessageId = assistantMessageId
        self.onMessagesUpdate = onUpdate
        self.onComplete = onComplete
        self.onStatusChange = onStatusChange
        self.onFailure = onFailure

        isACPActive = true
        lastError = nil
        startBootstrapWatchdog(assistantMessageId: assistantMessageId)

        acpQueue.async { [weak self] in
            self?.sendPromptOnQueue(
                text: text,
                threadId: threadId,
                projectPath: projectPath,
                mode: mode,
                model: model,
                assistantMessageId: assistantMessageId
            )
        }
    }

    func stop() {
        cancelAllWatchdogs()
        acpQueue.async { [weak self] in
            guard let self else { return }
            self.acpClient?.stop()
            self.acpClient = nil
            self.warmThreadId = nil
            self.isWarming = false
            self.isCreatingSession = false
            self.sessionWaitCompletions.removeAll()
            self.pendingSend = nil
            self.clearSessionReady()
            DispatchQueue.main.async {
                self.isACPActive = false
                self.acpStatus = ""
                self.onComplete = nil
                self.onMessagesUpdate = nil
                self.onStatusChange = nil
                self.onFailure = nil
            }
        }
    }

    // MARK: - Private queue work

    private func warmSessionOnQueue(projectPath: URL, mode: GrokBuildMode, threadId: UUID, model: String?) {
        if hasWarmSession(threadId: threadId, projectPath: projectPath, mode: mode, model: model) {
            return
        }

        if let client = acpClient {
            if !client.matchesConfiguration(mode: mode, model: model, cwd: projectPath) {
                client.stop()
                acpClient = nil
                clearSessionReady()
            } else if client.isInitialized, !isCreatingSession {
                setStatus("Creating session...")
                requestSession(projectPath: projectPath, threadId: threadId, mode: mode) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.markSessionReady(threadId: threadId, projectPath: projectPath, mode: mode)
                        self.flushPendingSendIfNeeded()
                    case .failure:
                        self.markPrewarmFailed()
                    }
                }
                return
            }
        }

        guard !isWarming, !isCreatingSession else { return }
        guard acpClient == nil || acpClient?.isRunning != true else { return }

        isWarming = true
        DispatchQueue.main.async {
            self.isPrewarming = true
            self.prewarmFailed = false
        }
        bootstrapClient(
            projectPath: projectPath,
            mode: mode,
            model: model,
            threadId: threadId,
            assistantMessageId: nil,
            text: nil,
            onReady: { [weak self] in
                self?.isWarming = false
                DispatchQueue.main.async {
                    self?.isPrewarming = false
                }
                self?.flushPendingSendIfNeeded()
            }
        )
    }

    private func markPrewarmFailed() {
        DispatchQueue.main.async {
            self.isPrewarming = false
            self.prewarmFailed = true
        }
    }

    private func sendPromptOnQueue(
        text: String,
        threadId: UUID,
        projectPath: URL,
        mode: GrokBuildMode,
        model: String?,
        assistantMessageId: UUID
    ) {
        if hasWarmSession(threadId: threadId, projectPath: projectPath, mode: mode, model: model),
           let client = acpClient,
           let sessionId = client.acpSessionId {
            wireClientHandlers(client, mode: mode, assistantMessageId: assistantMessageId)
            submitPrompt(
                text: text,
                sessionId: sessionId,
                client: client,
                threadId: threadId,
                assistantMessageId: assistantMessageId
            )
            return
        }

        if isWarming || isCreatingSession {
            pendingSend = PendingSend(
                text: text,
                threadId: threadId,
                projectPath: projectPath,
                mode: mode,
                model: model,
                assistantMessageId: assistantMessageId
            )
            setStatus(isCreatingSession ? "Creating session..." : "Starting Grok CLI…")
            startPendingSendWatchdog(assistantMessageId: assistantMessageId)
            return
        }

        if let client = acpClient,
           client.matchesConfiguration(mode: mode, model: model, cwd: projectPath),
           client.isInitialized {
            wireClientHandlers(client, mode: mode, assistantMessageId: assistantMessageId)
            setStatus("Preparing session…")
            requestSession(projectPath: projectPath, threadId: threadId, mode: mode) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    self.finishWithError(err.localizedDescription, assistantMessageId: assistantMessageId)
                case .success(let sessionId):
                    guard let client = self.acpClient else { return }
                    self.submitPrompt(
                        text: text,
                        sessionId: sessionId,
                        client: client,
                        threadId: threadId,
                        assistantMessageId: assistantMessageId
                    )
                }
            }
            return
        }

        setStatus("Starting Grok CLI…")
        isWarming = true
        DispatchQueue.main.async {
            self.isPrewarming = true
            self.prewarmFailed = false
        }
        bootstrapClient(
            projectPath: projectPath,
            mode: mode,
            model: model,
            threadId: threadId,
            assistantMessageId: assistantMessageId,
            text: text,
            onReady: { [weak self] in
                self?.isWarming = false
            }
        )
    }

    private func startPendingSendWatchdog(assistantMessageId: UUID) {
        cancelPendingSendWatchdog()
        let item = DispatchWorkItem { [weak self] in
            self?.acpQueue.async {
                guard let self,
                      self.pendingSend?.assistantMessageId == assistantMessageId else { return }
                self.finishWithError(
                    "Agent connection timed out.",
                    assistantMessageId: assistantMessageId
                )
            }
        }
        pendingSendWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func cancelPendingSendWatchdog() {
        pendingSendWatchdog?.cancel()
        pendingSendWatchdog = nil
    }

    private func flushPendingSendIfNeeded() {
        guard let pending = pendingSend else { return }
        cancelPendingSendWatchdog()
        pendingSend = nil
        sendPromptOnQueue(
            text: pending.text,
            threadId: pending.threadId,
            projectPath: pending.projectPath,
            mode: pending.mode,
            model: pending.model,
            assistantMessageId: pending.assistantMessageId
        )
    }

    private func requestSession(
        projectPath: URL,
        threadId: UUID,
        mode: GrokBuildMode,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if let client = acpClient,
           client.acpSessionId != nil,
           warmProjectPath == GrokBuildACPClient.normalizedPath(projectPath) {
            completion(.success(client.acpSessionId!))
            return
        }

        sessionWaitCompletions.append(completion)
        guard !isCreatingSession else { return }

        guard let client = acpClient, client.isInitialized else {
            flushSessionWaiters(with: .failure(GrokBuildACPError.sessionNotReady))
            return
        }

        isCreatingSession = true
        warmThreadId = threadId
        client.createSession(cwd: projectPath) { [weak self] result in
            guard let self else { return }
            self.acpQueue.async {
                self.isCreatingSession = false
                switch result {
                case .success(let sessionId):
                    self.store.setACPSessionId(sessionId, for: threadId)
                    self.markSessionReady(threadId: threadId, projectPath: projectPath, mode: mode)
                    self.flushSessionWaiters(with: .success(sessionId))
                    self.flushPendingSendIfNeeded()
                case .failure(let error):
                    self.flushSessionWaiters(with: .failure(error))
                }
            }
        }
    }

    private func flushSessionWaiters(with result: Result<String, Error>) {
        let waiters = sessionWaitCompletions
        sessionWaitCompletions.removeAll()
        for waiter in waiters {
            DispatchQueue.main.async {
                waiter(result)
            }
        }
    }

    private func wireClientHandlers(_ client: GrokBuildACPClient, mode: GrokBuildMode, assistantMessageId: UUID) {
        client.onSessionUpdate = { [weak self] params in
            self?.handleSessionUpdate(params, assistantMessageId: assistantMessageId)
        }
        client.onPermissionRequest = { [weak self] request, respond in
            guard let self else { respond(false); return }
            DispatchQueue.main.async {
                self.handlePermissionRequest(request, mode: mode, respond: respond)
            }
        }
    }

    private func handleProcessTerminated(_ message: String, assistantMessageId: UUID?) {
        isWarming = false
        isCreatingSession = false
        sessionWaitCompletions.removeAll()
        clearSessionReady()
        acpClient = nil

        guard let assistantMessageId else {
            pendingSend = nil
            return
        }

        if pendingSend != nil {
            pendingSend = nil
        }

        finishWithError("Grok agent stopped: \(message)", assistantMessageId: assistantMessageId)
    }

    private func startBootstrapWatchdog(assistantMessageId: UUID) {
        cancelBootstrapWatchdog()
        let item = DispatchWorkItem { [weak self] in
            self?.acpQueue.async {
                guard let self,
                      self.activeAssistantMessageId == assistantMessageId,
                      self.isACPActive else { return }
                self.finishWithError(
                    "Agent startup timed out. Falling back to local tools.",
                    assistantMessageId: assistantMessageId
                )
            }
        }
        bootstrapWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func cancelBootstrapWatchdog() {
        bootstrapWatchdog?.cancel()
        bootstrapWatchdog = nil
    }

    private func startTurnWatchdog(assistantMessageId: UUID, timeout: TimeInterval = 90) {
        cancelTurnWatchdog()
        let item = DispatchWorkItem { [weak self] in
            self?.acpQueue.async {
                guard let self,
                      self.activeAssistantMessageId == assistantMessageId,
                      self.isACPActive else { return }
                self.finishWithError(
                    "Timed out waiting for Grok Build to finish this turn. The agent process was restarted; send the message again if needed.",
                    assistantMessageId: assistantMessageId
                )
            }
        }
        turnWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func cancelTurnWatchdog() {
        turnWatchdog?.cancel()
        turnWatchdog = nil
    }

    private func cancelAllWatchdogs() {
        cancelBootstrapWatchdog()
        cancelPendingSendWatchdog()
        cancelTurnWatchdog()
    }

    private func bootstrapClient(
        projectPath: URL,
        mode: GrokBuildMode,
        model: String?,
        threadId: UUID,
        assistantMessageId: UUID?,
        text: String?,
        onReady: (() -> Void)?
    ) {
        acpClient?.stop()
        clearSessionReady()
        let client = GrokBuildACPClient()
        acpClient = client
        warmThreadId = threadId
        warmProjectPath = GrokBuildACPClient.normalizedPath(projectPath)
        warmMode = mode

        client.onProcessTerminated = { [weak self] message in
            self?.acpQueue.async {
                guard self?.acpClient === client else { return }
                self?.handleProcessTerminated(
                    message,
                    assistantMessageId: assistantMessageId ?? self?.activeAssistantMessageId
                )
            }
        }

        if let assistantMessageId {
            wireClientHandlers(client, mode: mode, assistantMessageId: assistantMessageId)
        }

        do {
            try client.start(mode: mode, model: model, cwd: projectPath)
        } catch {
            isWarming = false
            if let assistantMessageId {
                finishWithError(error.localizedDescription, assistantMessageId: assistantMessageId)
            } else {
                onReady?()
            }
            return
        }

        client.initialize { [weak self] initResult in
            guard let self else { return }
            self.acpQueue.async {
                guard self.acpClient === client else { return }
                switch initResult {
                case .failure(let err):
                    self.isWarming = false
                    let detail = self.acpClient?.recentStderrSummary() ?? err.localizedDescription
                    if let assistantMessageId {
                        self.finishWithError(detail, assistantMessageId: assistantMessageId)
                    } else {
                        self.acpClient?.stop()
                        self.acpClient = nil
                        self.warmThreadId = nil
                        self.markPrewarmFailed()
                        onReady?()
                    }
                case .success:
                    if assistantMessageId != nil {
                        self.setStatus("Authenticating...")
                    }
                    client.authenticate { [self] authResult in
                        self.acpQueue.async {
                            guard self.acpClient === client else { return }
                            switch authResult {
                            case .failure(let err):
                                self.isWarming = false
                                let detail = self.acpClient?.recentStderrSummary() ?? err.localizedDescription
                                if let assistantMessageId {
                                    self.finishWithError(detail, assistantMessageId: assistantMessageId)
                                } else {
                                    self.acpClient?.stop()
                                    self.acpClient = nil
                                    self.warmThreadId = nil
                                    self.clearSessionReady()
                                    self.markPrewarmFailed()
                                    onReady?()
                                }
                            case .success:
                                if assistantMessageId != nil {
                                    self.setStatus("Creating session...")
                                }
                                self.requestSession(projectPath: projectPath, threadId: threadId, mode: mode) { [self] sessionResult in
                                    self.acpQueue.async {
                                        guard self.acpClient === client else { return }
                                        self.isWarming = false
                                        switch sessionResult {
                                        case .failure(let err):
                                            let detail = self.acpClient?.recentStderrSummary() ?? err.localizedDescription
                                            if let assistantMessageId {
                                                self.finishWithError(detail, assistantMessageId: assistantMessageId)
                                            } else {
                                                self.acpClient?.stop()
                                                self.acpClient = nil
                                                self.warmThreadId = nil
                                                self.clearSessionReady()
                                                self.markPrewarmFailed()
                                                if self.pendingSend != nil {
                                                    self.acpQueue.asyncAfter(deadline: .now() + 0.1) {
                                                        self.flushPendingSendIfNeeded()
                                                    }
                                                } else {
                                                    onReady?()
                                                }
                                            }
                                        case .success(let sessionId):
                                            if let assistantMessageId, let text, let client = self.acpClient {
                                                self.submitPrompt(
                                                    text: text,
                                                    sessionId: sessionId,
                                                    client: client,
                                                    threadId: threadId,
                                                    assistantMessageId: assistantMessageId
                                                )
                                            } else {
                                                onReady?()
                                                self.flushPendingSendIfNeeded()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func submitPrompt(
        text: String,
        sessionId: String,
        client: GrokBuildACPClient,
        threadId: UUID,
        assistantMessageId: UUID
    ) {
        warmThreadId = threadId
        setStatus("Thinking...")
        var turnFinished = false

        let finishTurn: () -> Void = { [weak self] in
            guard let self, !turnFinished else { return }
            turnFinished = true
            client.onPromptComplete = nil
            self.cancelBootstrapWatchdog()
            self.cancelTurnWatchdog()
            self.setStatus("")
            self.isACPActive = false
            self.markAssistantDone(assistantMessageId: assistantMessageId)
            self.completeActivityLines(assistantMessageId: assistantMessageId)
            self.onComplete?()
            self.onComplete = nil
        }

        client.onPromptComplete = {
            self.acpQueue.async { finishTurn() }
        }

        startTurnWatchdog(assistantMessageId: assistantMessageId)

        client.sendPrompt(text: text, sessionId: sessionId) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                client.onPromptComplete = nil
                self.finishWithError(err.localizedDescription, assistantMessageId: assistantMessageId)
            case .success:
                // Turn completion is driven by `_x.ai/session/prompt_complete`, not RPC ack.
                break
            }
        }
    }

    private func handleSessionUpdate(_ params: [String: Any], assistantMessageId: UUID) {
        guard let update = params["update"] as? [String: Any] else { return }
        let kind = update["sessionUpdate"] as? String ?? ""

        if kind == "agent_message_chunk" {
            if let content = update["content"] as? [String: Any],
               let text = content["text"] as? String {
                onMessagesUpdate?(assistantMessageId) { msgs in
                    guard let idx = msgs.firstIndex(where: { $0.id == assistantMessageId }) else { return }
                    msgs[idx].content.append(text)
                    msgs[idx].isThinking = false
                    msgs[idx].activityLines.removeAll { $0.isTransient }
                }
            }
            return
        }

        if kind == "available_commands_update" {
            return
        }

        if kind == "agent_thought_chunk", let text = Self.extractText(from: update), !text.isEmpty {
            setStatus("Thinking…")
            onMessagesUpdate?(assistantMessageId) { msgs in
                guard let idx = msgs.firstIndex(where: { $0.id == assistantMessageId }) else { return }
                msgs[idx].isThinking = false
                if var last = msgs[idx].activityLines.last,
                   last.title == "Thinking",
                   last.isInProgress {
                    let combined = (last.detail ?? "") + text
                    last.detail = combined.count > 160 ? String(combined.suffix(160)) : combined
                    msgs[idx].activityLines[msgs[idx].activityLines.count - 1] = last
                } else {
                    Self.appendActivityLine(
                        to: &msgs[idx],
                        icon: "brain.head.profile",
                        title: "Thinking",
                        detail: text,
                        inProgress: true
                    )
                }
            }
            return
        }

        guard let parsed = Self.parseActivity(from: update, kind: kind) else { return }
        setStatus(parsed.title)

        onMessagesUpdate?(assistantMessageId) { msgs in
            guard let idx = msgs.firstIndex(where: { $0.id == assistantMessageId }) else { return }
            msgs[idx].isThinking = false
            Self.appendActivityLine(
                to: &msgs[idx],
                icon: parsed.icon,
                title: parsed.title,
                detail: parsed.detail,
                inProgress: parsed.inProgress
            )

            if !parsed.inProgress, parsed.toolName != nil {
                msgs[idx].toolAction = parsed.toolName
            }
            if let output = parsed.outputPreview {
                msgs[idx].toolOutput = output
            }
        }
    }

    private static func appendActivityLine(
        to message: inout ChatMessage,
        icon: String,
        title: String,
        detail: String?,
        inProgress: Bool
    ) {
        if inProgress, var last = message.activityLines.last, last.isInProgress {
            last.isInProgress = false
            message.activityLines[message.activityLines.count - 1] = last
        }
        if let last = message.activityLines.last,
           last.title == title,
           last.detail == detail,
           last.isInProgress == inProgress {
            return
        }
        message.activityLines.append(
            AgentActivityLine(icon: icon, title: title, detail: detail, isInProgress: inProgress)
        )
    }

    private struct ParsedActivity {
        let icon: String
        let title: String
        let detail: String?
        let inProgress: Bool
        let toolName: String?
        let outputPreview: String?
    }

    private static func parseActivity(from update: [String: Any], kind: String) -> ParsedActivity? {
        let status = (update["status"] as? String)?.lowercased()
        let inProgress = status.map { !["completed", "complete", "done", "success", "failed", "error"].contains($0) } ?? true

        switch kind {
        case "tool_call_delta_chunk":
            return nil
        case "agent_thought_chunk":
            guard let text = extractText(from: update), !text.isEmpty else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ParsedActivity(
                icon: "brain.head.profile",
                title: "Thinking",
                detail: trimmed.count <= 120 ? trimmed : nil,
                inProgress: true,
                toolName: nil,
                outputPreview: nil
            )

        case "tool_call", "tool_call_update", "tool_call_start", "tool_call_progress", "tool_start":
            let toolName = firstString(in: update, keys: ["title", "name", "toolName", "tool", "kind"])
                ?? "Tool"
            let detail = extractToolDetail(from: update)
            let completed = status == "completed"
            return ParsedActivity(
                icon: iconForTool(toolName),
                title: completed ? "Finished \(toolName)" : toolName,
                detail: detail,
                inProgress: !completed,
                toolName: "🔧 \(toolName)",
                outputPreview: completed ? extractToolOutput(from: update) : nil
            )

        case "tool_result", "tool_output", "tool_call_result":
            let toolName = firstString(in: update, keys: ["title", "name", "toolName", "tool"]) ?? "Tool"
            let output = extractText(from: update) ?? extractToolDetail(from: update)
            return ParsedActivity(
                icon: "checkmark.circle",
                title: "Tool result",
                detail: output.map { String($0.prefix(240)) },
                inProgress: false,
                toolName: "🔧 \(toolName)",
                outputPreview: output.map { String($0.prefix(800)) }
            )

        case "plan", "plan_update", "step_start", "step_update", "step_finish":
            let title = firstString(in: update, keys: ["title", "name", "step", "message"]) ?? kind.replacingOccurrences(of: "_", with: " ")
            let detail = extractText(from: update) ?? extractToolDetail(from: update)
            return ParsedActivity(
                icon: "list.bullet.rectangle",
                title: title.capitalized,
                detail: detail,
                inProgress: inProgress,
                toolName: nil,
                outputPreview: nil
            )

        default:
            if let title = firstString(in: update, keys: ["title", "message", "name", "status"]) {
                return ParsedActivity(
                    icon: "ellipsis.circle",
                    title: title,
                    detail: extractToolDetail(from: update),
                    inProgress: inProgress,
                    toolName: nil,
                    outputPreview: nil
                )
            }
            guard !kind.isEmpty else { return nil }
            return ParsedActivity(
                icon: "gearshape",
                title: kind.replacingOccurrences(of: "_", with: " ").capitalized,
                detail: nil,
                inProgress: inProgress,
                toolName: nil,
                outputPreview: nil
            )
        }
    }

    private static func extractText(from update: [String: Any]) -> String? {
        if let content = update["content"] as? [String: Any],
           let text = content["text"] as? String,
           !text.isEmpty {
            return text
        }
        if let text = update["text"] as? String, !text.isEmpty { return text }
        if let text = update["message"] as? String, !text.isEmpty { return text }
        return nil
    }

    private static func extractToolDetail(from update: [String: Any]) -> String? {
        if let rawInput = update["rawInput"] as? [String: Any] {
            if let command = rawInput["command"] as? String, !command.isEmpty { return command }
            if let dir = rawInput["target_directory"] as? String, !dir.isEmpty { return dir }
            if let json = compactJSON(rawInput) { return json }
        }
        if let input = update["input"] as? [String: Any] {
            if let json = compactJSON(input) { return json }
        }
        if let args = update["arguments"] as? [String: Any],
           let json = compactJSON(args) {
            return json
        }
        for key in ["path", "command", "cwd", "query", "url", "description", "summary"] {
            if let value = update[key] as? String, !value.isEmpty {
                return value
            }
        }
        if let locations = update["locations"] as? [[String: Any]] {
            let paths = locations.compactMap { $0["path"] as? String ?? $0["uri"] as? String }
            if !paths.isEmpty { return paths.prefix(3).joined(separator: ", ") }
        }
        return extractText(from: update).map { String($0.prefix(240)) }
    }

    private static func extractToolOutput(from update: [String: Any]) -> String? {
        if let rawOutput = update["rawOutput"] as? [String: Any] {
            if let content = rawOutput["Content"] as? [String: Any],
               let text = content["content"] as? String {
                return String(text.prefix(800))
            }
            if let json = compactJSON(rawOutput) { return json }
        }
        return extractText(from: update).map { String($0.prefix(800)) }
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func compactJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return String(string.prefix(240))
    }

    private static func iconForTool(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("read") || lower.contains("file") || lower.contains("ls") || lower.contains("list") {
            return "doc.text.magnifyingglass"
        }
        if lower.contains("write") || lower.contains("edit") || lower.contains("patch") {
            return "square.and.pencil"
        }
        if lower.contains("terminal") || lower.contains("bash") || lower.contains("shell") || lower.contains("command") {
            return "terminal"
        }
        if lower.contains("search") || lower.contains("grep") || lower.contains("find") {
            return "magnifyingglass"
        }
        if lower.contains("web") || lower.contains("fetch") || lower.contains("http") {
            return "globe"
        }
        return "wrench.and.screwdriver"
    }

    private func handlePermissionRequest(
        _ request: [String: Any],
        mode: GrokBuildMode,
        respond: @escaping (Bool) -> Void
    ) {
        switch mode {
        case .agentAuto:
            respond(true)
        case .chat:
            respond(false)
            setStatus("Chat mode — tool blocked")
        case .agent:
            respond(true)
        }
    }

    private func markAssistantDone(assistantMessageId: UUID) {
        onMessagesUpdate?(assistantMessageId) { msgs in
            if let idx = msgs.firstIndex(where: { $0.id == assistantMessageId }) {
                msgs[idx].isThinking = false
            }
        }
    }

    private func completeActivityLines(assistantMessageId: UUID) {
        onMessagesUpdate?(assistantMessageId) { msgs in
            guard let idx = msgs.firstIndex(where: { $0.id == assistantMessageId }) else { return }
            msgs[idx].activityLines.removeAll { line in
                AgentActivityLine.transientTitles.contains(line.title)
            }
            guard !msgs[idx].activityLines.isEmpty else { return }
            var last = msgs[idx].activityLines[msgs[idx].activityLines.count - 1]
            if last.isInProgress {
                last.isInProgress = false
                msgs[idx].activityLines[msgs[idx].activityLines.count - 1] = last
            }
        }
    }

    private func finishWithError(_ message: String, assistantMessageId: UUID) {
        cancelAllWatchdogs()
        lastError = message
        setStatus("")
        isACPActive = false
        acpClient?.stop()
        acpClient = nil
        warmThreadId = nil
        warmProjectPath = nil
        warmMode = nil
        clearSessionReady()
        isWarming = false
        isCreatingSession = false
        sessionWaitCompletions.removeAll()
        pendingSend = nil

        let failure = onFailure
        onFailure = nil

        if let failure {
            DispatchQueue.main.async {
                failure()
            }
            onComplete = nil
            onMessagesUpdate = nil
            return
        }

        onMessagesUpdate?(assistantMessageId) { msgs in
            if let idx = msgs.firstIndex(where: { $0.id == assistantMessageId }) {
                msgs[idx].content = "❌ \(message)"
                msgs[idx].isThinking = false
            }
        }
        onComplete?()
        onComplete = nil
    }
}
