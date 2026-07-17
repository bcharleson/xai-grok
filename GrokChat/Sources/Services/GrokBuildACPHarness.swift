import Foundation

/// Executes ACP client-side capabilities the Grok agent calls back into the harness:
/// terminal commands and workspace file I/O.
final class GrokBuildACPHarness {
    typealias PermissionHandler = (_ request: [String: Any], _ respond: @escaping (Bool) -> Void) -> Void

    private struct TerminalSession {
        let id: String
        var exitCode: Int32
        var output: String
    }

    private var terminals: [String: TerminalSession] = [:]
    private let lock = NSLock()
    private let workspaceRoot: URL
    var onPermissionRequest: PermissionHandler?

    init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    func reset() {
        lock.lock()
        terminals.removeAll()
        lock.unlock()
    }

    func handleAgentRequest(
        method: String,
        params: [String: Any],
        requestId: Int,
        sendResult: @escaping (_ requestId: Int, _ result: [String: Any]) -> Void
    ) {
        switch method {
        case "terminal/create":
            handleTerminalCreate(params: params, requestId: requestId, sendResult: sendResult)
        case "terminal/wait_for_exit":
            handleTerminalWait(params: params, requestId: requestId, sendResult: sendResult)
        case "terminal/output":
            handleTerminalOutput(params: params, requestId: requestId, sendResult: sendResult)
        case "terminal/kill", "terminal/release":
            if let terminalId = params["terminalId"] as? String {
                lock.lock()
                terminals.removeValue(forKey: terminalId)
                lock.unlock()
            }
            sendResult(requestId, [:])
        case "fs/read_text_file", "fs/readTextFile":
            handleReadTextFile(params: params, requestId: requestId, sendResult: sendResult)
        case "fs/write_text_file", "fs/writeTextFile":
            handleWriteTextFile(params: params, requestId: requestId, sendResult: sendResult)
        default:
            if method.lowercased().contains("permission") {
                handlePermission(json: ["method": method, "params": params, "id": requestId], sendResult: sendResult)
            } else {
                sendResult(requestId, [:])
            }
        }
    }

    // MARK: - Terminal

    private func handleTerminalCreate(
        params: [String: Any],
        requestId: Int,
        sendResult: @escaping (_ requestId: Int, _ result: [String: Any]) -> Void
    ) {
        let command = params["command"] as? String ?? ""
        let cwd = resolvePath(params["cwd"] as? String) ?? workspaceRoot
        let byteLimit = params["outputByteLimit"] as? Int ?? 200_000
        let terminalId = UUID().uuidString

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (exitCode, output) = Self.runShell(command, cwd: cwd, byteLimit: byteLimit)
            let session = TerminalSession(id: terminalId, exitCode: exitCode, output: output)
            self.lock.lock()
            self.terminals[terminalId] = session
            self.lock.unlock()
            sendResult(requestId, ["terminalId": terminalId])
        }
    }

    private func handleTerminalWait(
        params: [String: Any],
        requestId: Int,
        sendResult: @escaping (_ requestId: Int, _ result: [String: Any]) -> Void
    ) {
        let terminalId = params["terminalId"] as? String ?? ""
        lock.lock()
        let exitCode = terminals[terminalId]?.exitCode ?? 0
        lock.unlock()
        sendResult(requestId, ["exitCode": exitCode, "signal": NSNull()])
    }

    private func handleTerminalOutput(
        params: [String: Any],
        requestId: Int,
        sendResult: @escaping (_ requestId: Int, _ result: [String: Any]) -> Void
    ) {
        let terminalId = params["terminalId"] as? String ?? ""
        lock.lock()
        let session = terminals[terminalId]
        lock.unlock()
        sendResult(requestId, [
            "output": session?.output ?? "",
            "exitStatus": ["exitCode": session?.exitCode ?? 0]
        ])
    }

    private static func runShell(_ command: String, cwd: URL, byteLimit: Int) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            var combined = ""
            if let out = String(data: outData, encoding: .utf8) { combined += out }
            if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
                if !combined.isEmpty { combined += "\n" }
                combined += err
            }
            if combined.utf8.count > byteLimit {
                combined = String(combined.prefix(byteLimit))
            }
            return (process.terminationStatus, combined)
        } catch {
            return (1, error.localizedDescription)
        }
    }

    // MARK: - Filesystem

    private func handleReadTextFile(
        params: [String: Any],
        requestId: Int,
        sendResult: @escaping (_ requestId: Int, _ result: [String: Any]) -> Void
    ) {
        guard let path = params["path"] as? String else {
            sendResult(requestId, ["content": ""])
            return
        }
        let url = resolvePath(path) ?? workspaceRoot.appendingPathComponent(path)
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            sendResult(requestId, ["content": content])
        } catch {
            sendResult(requestId, ["content": "", "error": error.localizedDescription])
        }
    }

    private func handleWriteTextFile(
        params: [String: Any],
        requestId: Int,
        sendResult: @escaping (_ requestId: Int, _ result: [String: Any]) -> Void
    ) {
        guard let path = params["path"] as? String else {
            sendResult(requestId, [:])
            return
        }
        let content = params["content"] as? String ?? ""
        let url = resolvePath(path) ?? workspaceRoot.appendingPathComponent(path)
        do {
            let parent = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            sendResult(requestId, [:])
        } catch {
            sendResult(requestId, ["error": error.localizedDescription])
        }
    }

    private func resolvePath(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
        return workspaceRoot.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Permissions

    private func handlePermission(
        json: [String: Any],
        sendResult: @escaping (_ requestId: Int, _ result: [String: Any]) -> Void
    ) {
        guard let requestId = json["id"] as? Int ?? (json["id"] as? NSNumber)?.intValue else { return }
        if let handler = onPermissionRequest {
            DispatchQueue.main.async {
                handler(json) { approved in
                    sendResult(requestId, ["outcome": approved ? "approved" : "denied"])
                }
            }
        } else {
            sendResult(requestId, ["outcome": "approved"])
        }
    }
}
