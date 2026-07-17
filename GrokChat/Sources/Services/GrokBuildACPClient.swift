import Foundation

enum GrokBuildACPError: LocalizedError {
    case cliNotFound
    case notRunning
    case processFailed(String)
    case invalidResponse
    case requestTimeout
    case sessionNotReady

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Grok CLI not found. Install from https://docs.x.ai/docs/grok-cli or run `grok login`."
        case .notRunning:
            return "ACP agent is not running."
        case .processFailed(let msg):
            return "ACP agent failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from Grok ACP agent."
        case .requestTimeout:
            return "Timed out waiting for Grok ACP agent."
        case .sessionNotReady:
            return "ACP session not initialized."
        }
    }
}

/// JSON-RPC client for `grok agent stdio` (Agent Client Protocol).
final class GrokBuildACPClient {
    typealias SessionUpdateHandler = ([String: Any]) -> Void
    typealias PermissionHandler = (_ request: [String: Any], _ respond: @escaping (Bool) -> Void) -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private let ioQueue = DispatchQueue(label: "grok.acp.io", qos: .userInitiated)
    private var readBuffer = ""
    private var stderrBuffer = ""
    private var requestId = 0
    private var pending: [Int: (Result<[String: Any]?, Error>) -> Void] = [:]
    private let lock = NSLock()

    private(set) var acpSessionId: String?
    private(set) var isRunning = false
    private(set) var isInitialized = false
    private var authMethods: Set<String> = []

    private var startedMode: GrokBuildMode?
    private var startedModel: String?
    private var startedCWD: URL?
    private var readThread: Thread?
    private var stderrThread: Thread?
    private var harness: GrokBuildACPHarness?
    private let stderrLock = NSLock()

    func attachSession(id: String) {
        acpSessionId = id
    }

    func matchesConfiguration(mode: GrokBuildMode, model: String?, cwd: URL) -> Bool {
        guard isRunning, isInitialized else { return false }
        let modelKey = model ?? "auto"
        return startedMode == mode
            && startedModel == modelKey
            && Self.normalizedPath(startedCWD) == Self.normalizedPath(cwd)
    }

    static func normalizedPath(_ url: URL?) -> String {
        guard let url else { return "" }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    var onSessionUpdate: SessionUpdateHandler?
    var onPermissionRequest: PermissionHandler? {
        didSet { harness?.onPermissionRequest = onPermissionRequest }
    }
    /// Called when the grok agent subprocess exits or stops responding.
    var onProcessTerminated: ((String) -> Void)?
    /// Fired when the agent reports a completed turn (`_x.ai/session/prompt_complete`).
    var onPromptComplete: (() -> Void)?

    // MARK: - Lifecycle

    func start(mode: GrokBuildMode, model: String?, cwd: URL) throws {
        stop()

        guard let executable = GrokCLIResolver.resolveExecutable() else {
            throw GrokBuildACPError.cliNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.currentDirectoryURL = cwd

        var args = ["--no-auto-update", "agent", "--no-leader"]
        if mode == .agentAuto {
            args.append("--always-approve")
        }
        if let model, model != "auto", !model.isEmpty {
            args.append(contentsOf: ["-m", model])
        }
        args.append("stdio")
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        if env["HOME"]?.isEmpty != false {
            env["HOME"] = NSHomeDirectory()
        }
        if env["PATH"]?.contains(".local/bin") != true {
            let home = env["HOME"] ?? NSHomeDirectory()
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        proc.environment = env

        startedMode = mode
        startedModel = model ?? "auto"
        startedCWD = cwd.standardizedFileURL.resolvingSymlinksInPath()
        harness = GrokBuildACPHarness(workspaceRoot: cwd)
        harness?.onPermissionRequest = onPermissionRequest
        isInitialized = false
        authMethods = []
        stderrBuffer = ""

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] p in
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = errMsg?.isEmpty == false
                ? errMsg!
                : "Grok agent exited (code \(p.terminationStatus))"
            self?.ioQueue.async {
                self?.failAllPending(GrokBuildACPError.processFailed(message))
                self?.isRunning = false
                self?.isInitialized = false
                let notify = self?.onProcessTerminated
                DispatchQueue.main.async {
                    notify?(message)
                }
            }
        }

        try proc.run()

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading
        isRunning = true
        acpSessionId = nil

        startReaderLoop(stdoutPipe.fileHandleForReading)
        startStderrLoop(stderrPipe.fileHandleForReading)
    }

    private func startReaderLoop(_ handle: FileHandle) {
        readThread = Thread { [weak self] in
            while self?.isRunning == true {
                let data = handle.availableData
                if data.isEmpty { break }
                self?.ioQueue.async {
                    self?.consumeStdout(data)
                }
            }
            self?.ioQueue.async {
                guard let self, self.isRunning else { return }
                let message = self.stderrBuffer.isEmpty
                    ? "Grok agent stopped responding"
                    : self.stderrBuffer
                self.failAllPending(GrokBuildACPError.processFailed(message))
                self.isRunning = false
                self.isInitialized = false
                let notify = self.onProcessTerminated
                DispatchQueue.main.async {
                    notify?(message)
                }
            }
        }
        readThread?.name = "grok.acp.stdout"
        readThread?.start()
    }

    private func startStderrLoop(_ handle: FileHandle) {
        stderrThread = Thread { [weak self] in
            while self?.isRunning == true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                self?.ioQueue.async {
                    self?.stderrLock.lock()
                    self?.stderrBuffer.append(chunk)
                    self?.stderrLock.unlock()
                }
            }
        }
        stderrThread?.name = "grok.acp.stderr"
        stderrThread?.start()
    }

    func stop() {
        isRunning = false
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        failAllPending(GrokBuildACPError.notRunning)
        stdinHandle?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        isInitialized = false
        authMethods = []
        startedMode = nil
        startedModel = nil
        startedCWD = nil
        acpSessionId = nil
        harness?.reset()
        harness = nil
        lock.lock()
        pending.removeAll()
        lock.unlock()
        readBuffer = ""
        stderrLock.lock()
        stderrBuffer = ""
        stderrLock.unlock()
    }

    /// Last stderr lines from the Grok agent subprocess (useful when RPC times out).
    func recentStderrSummary(maxCharacters: Int = 240) -> String? {
        stderrLock.lock()
        let trimmed = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        stderrLock.unlock()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxCharacters { return trimmed }
        return String(trimmed.suffix(maxCharacters))
    }

    private func respondToAgent(requestId: Int, result: [String: Any]) {
        sendRaw(json: [
            "jsonrpc": "2.0",
            "id": requestId,
            "result": result
        ])
    }

    // MARK: - ACP methods

    func initialize(completion: @escaping (Result<Void, Error>) -> Void) {
        sendRequest(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": true, "writeTextFile": true],
                "terminal": true
            ]
        ]) { [weak self] result in
            switch result {
            case .success(let json):
                if let methods = json?["authMethods"] as? [[String: Any]] {
                    self?.authMethods = Set(methods.compactMap { $0["id"] as? String })
                } else {
                    self?.authMethods = []
                }
                self?.isInitialized = true
                completion(.success(()))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    func authenticate(completion: @escaping (Result<Void, Error>) -> Void) {
        let methodId: String?
        if ProcessInfo.processInfo.environment["XAI_API_KEY"]?.isEmpty == false,
           authMethods.contains("xai.api_key") {
            methodId = "xai.api_key"
        } else if authMethods.contains("cached_token") {
            methodId = "cached_token"
        } else if authMethods.isEmpty {
            // Older CLI builds authenticated implicitly after initialize.
            completion(.success(()))
            return
        } else {
            completion(.failure(GrokBuildACPError.processFailed("Run `grok login` first, or set XAI_API_KEY.")))
            return
        }

        sendRequest(method: "authenticate", params: [
            "methodId": methodId!,
            "_meta": ["headless": true]
        ], timeout: 20) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    func createSession(cwd: URL, completion: @escaping (Result<String, Error>) -> Void) {
        sendRequest(method: "session/new", params: [
            "cwd": Self.normalizedPath(cwd),
            "mcpServers": [] as [Any]
        ]) { [weak self] result in
            switch result {
            case .success(let json):
                if let sessionId = json?["sessionId"] as? String {
                    self?.acpSessionId = sessionId
                    completion(.success(sessionId))
                } else {
                    completion(.failure(GrokBuildACPError.invalidResponse))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    func sendPrompt(text: String, sessionId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sendRequest(method: "session/prompt", params: [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]]
        ]) { result in
            switch result {
            case .success: completion(.success(()))
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    func respondPermission(requestId: Int, approved: Bool) {
        let result: [String: Any] = approved
            ? ["outcome": "approved"]
            : ["outcome": "denied"]
        sendRaw(json: [
            "jsonrpc": "2.0",
            "id": requestId,
            "result": result
        ])
    }

    // MARK: - JSON-RPC

    private func sendRequest(
        method: String,
        params: [String: Any],
        timeout: TimeInterval = 120,
        completion: @escaping (Result<[String: Any]?, Error>) -> Void
    ) {
        let effectiveTimeout = (method == "initialize" || method == "authenticate") ? 20 : (method == "session/new" ? 25 : timeout)
        ioQueue.async { [weak self] in
            guard let self, self.isRunning else {
                DispatchQueue.main.async { completion(.failure(GrokBuildACPError.notRunning)) }
                return
            }

            self.lock.lock()
            self.requestId += 1
            let id = self.requestId
            self.lock.unlock()

            var timedOut = false
            let timer = DispatchSource.makeTimerSource(queue: self.ioQueue)
            timer.schedule(deadline: .now() + effectiveTimeout)
            timer.setEventHandler { [weak self] in
                timedOut = true
                self?.lock.lock()
                self?.pending.removeValue(forKey: id)
                self?.lock.unlock()
                let stderr = self?.recentStderrSummary()
                let message = stderr.map { "Timed out waiting for Grok ACP agent (\(method)). \($0)" }
                    ?? GrokBuildACPError.requestTimeout.localizedDescription
                DispatchQueue.main.async {
                    completion(.failure(GrokBuildACPError.processFailed(message)))
                }
            }
            timer.resume()

            self.lock.lock()
            self.pending[id] = { result in
                timer.cancel()
                guard !timedOut else { return }
                DispatchQueue.main.async { completion(result) }
            }
            self.lock.unlock()

            self.sendRaw(json: [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ])
        }
    }

    private func sendRaw(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if let encoded = line.data(using: .utf8) {
            stdinHandle?.write(encoded)
            #if canImport(Darwin)
            try? stdinHandle?.synchronize()
            #endif
        }
    }

    private func consumeStdout(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        readBuffer.append(chunk)

        while let newlineRange = readBuffer.range(of: "\n") {
            let line = String(readBuffer[..<newlineRange.lowerBound])
            readBuffer.removeSubrange(..<newlineRange.upperBound)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            handleLine(trimmed)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Notification (no id, has method)
        if json["id"] == nil, let method = json["method"] as? String {
            if method == "session/update", let params = json["params"] as? [String: Any] {
                DispatchQueue.main.async { [weak self] in
                    self?.onSessionUpdate?(params)
                }
                return
            }

            if method == "_x.ai/session_notification", let params = json["params"] as? [String: Any] {
                DispatchQueue.main.async { [weak self] in
                    self?.onSessionUpdate?(params)
                }
                return
            }

            if method == "_x.ai/session/prompt_complete"
                || method == "_x.ai/session_prompt_complete"
                || method == "_x.ai/session/promptComplete"
                || method == "session/prompt_complete"
                || method == "session/promptComplete" {
                DispatchQueue.main.async { [weak self] in
                    self?.onPromptComplete?()
                }
                return
            }

            // Some agent builds emit extra notifications between initialize and session/new.
            if method.hasPrefix("_x.ai/") || method.hasPrefix("notifications/") {
                return
            }

            return
        }

        // Agent → client JSON-RPC request (terminal/*, fs/*, permissions)
        if let method = json["method"] as? String,
           json["result"] == nil,
           json["error"] == nil,
           let id = rpcId(from: json) {
            let params = json["params"] as? [String: Any] ?? [:]
            let respond: (_ requestId: Int, _ result: [String: Any]) -> Void = { [weak self] requestId, result in
                self?.respondToAgent(requestId: requestId, result: result)
            }
            if let harness {
                harness.handleAgentRequest(
                    method: method,
                    params: params,
                    requestId: id,
                    sendResult: respond
                )
            } else {
                respond(id, [:])
            }
            return
        }

        // Response to our request
        if json["method"] == nil, let id = rpcId(from: json) {
            lock.lock()
            let handler = pending.removeValue(forKey: id)
            lock.unlock()

            if let error = json["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unknown error"
                handler?(.failure(GrokBuildACPError.processFailed(msg)))
                return
            }

            handler?(.success(json["result"] as? [String: Any]))
        }
    }

    private func rpcId(from json: [String: Any]) -> Int? {
        if let id = json["id"] as? Int { return id }
        if let id = json["id"] as? NSNumber { return id.intValue }
        if let id = json["id"] as? String, let intId = Int(id) { return intId }
        return nil
    }

    private func failAllPending(_ error: Error) {
        lock.lock()
        let handlers = pending
        pending.removeAll()
        lock.unlock()
        for handler in handlers.values {
            DispatchQueue.main.async {
                handler(.failure(error))
            }
        }
    }
}

// MARK: - Harness probe

struct GrokBuildACPProbeResult {
    let success: Bool
    let initializeMs: Int
    let sessionNewMs: Int?
    let promptMs: Int?
    let sessionId: String?
    let responsePreview: String?
    let errorMessage: String?
    let stderr: String?
}

extension GrokBuildACPClient {
    /// Runs initialize → authenticate → session/new → short prompt to verify the CLI adapter works.
    static func probe(
        cwd: URL,
        mode: GrokBuildMode = .agentAuto,
        completion: @escaping (GrokBuildACPProbeResult) -> Void
    ) {
        let client = GrokBuildACPClient()
        let stderr = ""
        let t0 = CFAbsoluteTimeGetCurrent()

        func elapsedMs(from start: CFAbsoluteTime) -> Int {
            Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        do {
            try client.start(mode: mode, model: nil, cwd: cwd)
        } catch {
            completion(GrokBuildACPProbeResult(
                success: false,
                initializeMs: elapsedMs(from: t0),
                sessionNewMs: nil,
                promptMs: nil,
                sessionId: nil,
                responsePreview: nil,
                errorMessage: error.localizedDescription,
                stderr: stderr
            ))
            return
        }

        let initStart = CFAbsoluteTimeGetCurrent()
        client.initialize { initResult in
            let initMs = elapsedMs(from: initStart)
            switch initResult {
            case .failure(let err):
                client.stop()
                completion(GrokBuildACPProbeResult(
                    success: false,
                    initializeMs: initMs,
                    sessionNewMs: nil,
                    promptMs: nil,
                    sessionId: nil,
                    responsePreview: nil,
                    errorMessage: err.localizedDescription,
                    stderr: stderr
                ))
            case .success:
                client.authenticate { authResult in
                    switch authResult {
                    case .failure(let err):
                        client.stop()
                        completion(GrokBuildACPProbeResult(
                            success: false,
                            initializeMs: initMs,
                            sessionNewMs: nil,
                            promptMs: nil,
                            sessionId: nil,
                            responsePreview: nil,
                            errorMessage: err.localizedDescription,
                            stderr: stderr
                        ))
                    case .success:
                        let sessionStart = CFAbsoluteTimeGetCurrent()
                        client.createSession(cwd: cwd) { sessionResult in
                    let sessionMs = elapsedMs(from: sessionStart)
                    switch sessionResult {
                    case .failure(let err):
                        client.stop()
                        completion(GrokBuildACPProbeResult(
                            success: false,
                            initializeMs: initMs,
                            sessionNewMs: sessionMs,
                            promptMs: nil,
                            sessionId: nil,
                            responsePreview: nil,
                            errorMessage: err.localizedDescription,
                            stderr: stderr
                        ))
                    case .success(let sessionId):
                        var chunks = ""
                        client.onSessionUpdate = { params in
                            guard let update = params["update"] as? [String: Any],
                                  update["sessionUpdate"] as? String == "agent_message_chunk",
                                  let content = update["content"] as? [String: Any],
                                  let text = content["text"] as? String else { return }
                            chunks.append(text)
                        }
                        let promptStart = CFAbsoluteTimeGetCurrent()
                        client.sendPrompt(text: "Reply with exactly: pong", sessionId: sessionId) { promptResult in
                            let promptMs = elapsedMs(from: promptStart)
                            client.stop()
                            switch promptResult {
                            case .failure(let err):
                                completion(GrokBuildACPProbeResult(
                                    success: false,
                                    initializeMs: initMs,
                                    sessionNewMs: sessionMs,
                                    promptMs: promptMs,
                                    sessionId: sessionId,
                                    responsePreview: chunks.isEmpty ? nil : chunks,
                                    errorMessage: err.localizedDescription,
                                    stderr: stderr
                                ))
                            case .success:
                                completion(GrokBuildACPProbeResult(
                                    success: true,
                                    initializeMs: initMs,
                                    sessionNewMs: sessionMs,
                                    promptMs: promptMs,
                                    sessionId: sessionId,
                                    responsePreview: chunks.isEmpty ? "pong" : chunks,
                                    errorMessage: nil,
                                    stderr: stderr
                                ))
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
