//
//  GrokBuildTools.swift
//  Grok for Mac
//
//  Agentic tool system for the Grok Build tab (</>).
//  This powers the full coding agent experience, similar to the Grok Build CLI and VS Code extension.
//  Tools can read/write files, run commands, explore projects, etc.
//

import Foundation

// MARK: - Tool Definition

struct GrokTool {
    let name: String
    let description: String
    let parameters: [String: String]  // name -> description
    let requiresConfirmation: Bool
    let execute: ([String: Any]) async throws -> String
}

// MARK: - Tool Registry

final class GrokBuildToolRegistry {
    static let shared = GrokBuildToolRegistry()
    
    private(set) var tools: [GrokTool] = []
    
    private init() {
        registerCoreTools()
    }
    
    private func registerCoreTools() {
        // list_directory
        tools.append(GrokTool(
            name: "list_directory",
            description: "List files and directories in a given path. Use this to explore the project structure.",
            parameters: ["path": "Relative or absolute path to list (default: working directory)"],
            requiresConfirmation: false,
            execute: { params in
                let path = (params["path"] as? String) ?? FileManager.default.currentDirectoryPath
                let url = URL(fileURLWithPath: path).standardized
                
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError.directoryNotFound(path)
                }
                
                let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                
                var result = "Directory: \(url.path)\n\n"
                for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    result += isDir ? "📁 \(item.lastPathComponent)/\n" : "📄 \(item.lastPathComponent)\n"
                }
                return result
            }
        ))
        
        // read_file
        tools.append(GrokTool(
            name: "read_file",
            description: "Read the contents of a file. Use this when you need to see existing code or configuration.",
            parameters: ["path": "Path to the file to read"],
            requiresConfirmation: false,
            execute: { params in
                guard let path = params["path"] as? String else {
                    throw ToolError.missingParameter("path")
                }
                
                let url = URL(fileURLWithPath: path).standardized
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError.fileNotFound(path)
                }
                
                let content = try String(contentsOf: url, encoding: .utf8)
                return "File: \(url.path)\n\n\(content)"
            }
        ))
        
        // write_file
        tools.append(GrokTool(
            name: "write_file",
            description: "Write or overwrite a file with new content. Use this to create or edit code files.",
            parameters: ["path": "Path to the file", "content": "The new content to write"],
            requiresConfirmation: true,
            execute: { params in
                guard let path = params["path"] as? String,
                      let content = params["content"] as? String else {
                    throw ToolError.missingParameter("path or content")
                }
                
                let url = URL(fileURLWithPath: path).standardized
                try content.write(to: url, atomically: true, encoding: .utf8)
                return "Successfully wrote to \(url.path)"
            }
        ))
        
        // run_command
        tools.append(GrokTool(
            name: "run_command",
            description: "Execute a shell command in the current working directory. Use for building, testing, git, etc.",
            parameters: ["command": "The shell command to run"],
            requiresConfirmation: true,
            execute: { params in
                guard let command = params["command"] as? String else {
                    throw ToolError.missingParameter("command")
                }
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                try process.run()
                process.waitUntilExit()
                
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let error = String(data: errorData, encoding: .utf8) ?? ""
                
                var result = "Command: \(command)\nExit code: \(process.terminationStatus)\n\n"
                if !output.isEmpty { result += "STDOUT:\n\(output)\n" }
                if !error.isEmpty { result += "STDERR:\n\(error)" }
                
                return result
            }
        ))
        
        // create_directory
        tools.append(GrokTool(
            name: "create_directory",
            description: "Create a new folder in the project. Creates parent folders if needed.",
            parameters: ["path": "Relative or absolute path for the new directory"],
            requiresConfirmation: true,
            execute: { params in
                guard let path = params["path"] as? String else {
                    throw ToolError.missingParameter("path")
                }
                let url = URL(fileURLWithPath: path).standardized
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return "Created directory: \(url.path)"
            }
        ))
        
        // get_working_directory
        tools.append(GrokTool(
            name: "get_working_directory",
            description: "Get the current working directory the agent is operating in.",
            parameters: [:],
            requiresConfirmation: false,
            execute: { _ in
                return FileManager.default.currentDirectoryPath
            }
        ))
    }
    
    func getTool(named name: String) -> GrokTool? {
        return tools.first { $0.name == name }
    }
    
    func allToolDescriptions() -> String {
        return tools.map { tool in
            let params = tool.parameters.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return "- \(tool.name): \(tool.description)\n  Parameters: \(params)"
        }.joined(separator: "\n\n")
    }
}

// MARK: - Tool Errors

enum ToolError: Error, LocalizedError {
    case missingParameter(String)
    case fileNotFound(String)
    case directoryNotFound(String)
    case executionFailed(String)
    case unsupportedTool(String)
    
    var errorDescription: String? {
        switch self {
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .executionFailed(let reason):
            return "Tool execution failed: \(reason)"
        case .unsupportedTool(let name):
            return "Unsupported tool: \(name)"
        }
    }
}

// MARK: - Tool JSON Parser (shared with tests)

enum GrokBuildToolParser {
    struct Payload: Decodable {
        let tool: String
        let command: String?
        let path: String?
        let content: String?
        let url: String?
        let query: String?
        let port: Int?
        let arguments: [String: GrokJSONValue]?
    }

    enum GrokJSONValue: Decodable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode(Int.self) { self = .int(value); return }
            if let value = try? container.decode(Double.self) { self = .double(value); return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            throw DecodingError.typeMismatch(GrokJSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }

        var stringValue: String? {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            }
        }

        var intValue: Int? {
            switch self {
            case .int(let i): return i
            case .string(let s): return Int(s)
            case .double(let d): return Int(d)
            case .bool: return nil
            }
        }
    }

    static func extractJSONObject(from text: String) -> String? {
        guard let startRange = text.range(of: "{"),
              let endRange = text.range(of: "}", options: .backwards) else { return nil }
        return String(text[startRange.lowerBound..<endRange.upperBound])
    }

    static func parsePayload(from text: String) -> Payload? {
        guard let jsonString = extractJSONObject(from: text),
              let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    static func stringArg(_ payload: Payload, _ key: String) -> String? {
        if let args = payload.arguments, let value = args[key]?.stringValue { return value }
        switch key {
        case "command": return payload.command
        case "path": return payload.path
        case "content": return payload.content
        case "url": return payload.url
        case "query": return payload.query
        default: return nil
        }
    }

    /// Returns (tool name, normalized arguments) for downstream execution mapping.
    static func normalize(_ payload: Payload) -> (String, [String: String])? {
        var args: [String: String] = [:]
        if let nested = payload.arguments {
            for (key, value) in nested {
                if let stringValue = value.stringValue { args[key] = stringValue }
            }
        }
        if let command = payload.command { args["command"] = command }
        if let path = payload.path { args["path"] = path }
        if let content = payload.content { args["content"] = content }
        if let url = payload.url { args["url"] = url }
        if let query = payload.query { args["query"] = query }
        if let port = payload.port { args["port"] = String(port) }

        let toolName = payload.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if toolName.isEmpty { return nil }
        return (toolName, args)
    }
}