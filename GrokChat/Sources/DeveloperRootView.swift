import SwiftUI
import WebKit

// MARK: - API Retry Helper

/// Handles API calls with exponential backoff retry logic for rate limits and server errors
class APIRetryHelper {
    /// Retry configuration
    struct Config {
        let maxRetries: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval
        let retryableStatusCodes: Set<Int>

        static let `default` = Config(
            maxRetries: 3,
            baseDelay: 1.0,           // 1 second initial delay
            maxDelay: 30.0,           // Max 30 second delay
            retryableStatusCodes: [429, 500, 502, 503, 504]  // Rate limit + server errors
        )
    }

    /// Performs an API request with exponential backoff retry
    static func performRequest(
        _ request: URLRequest,
        config: Config = .default,
        attempt: Int = 0,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            // Check if we should retry
            if let httpResponse = response as? HTTPURLResponse,
               config.retryableStatusCodes.contains(httpResponse.statusCode),
               attempt < config.maxRetries {

                // Calculate delay with exponential backoff + jitter
                let exponentialDelay = config.baseDelay * pow(2.0, Double(attempt))
                let jitter = Double.random(in: 0...0.3) * exponentialDelay
                let delay = min(exponentialDelay + jitter, config.maxDelay)

                // Extract retry-after header if present (for rate limits)
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Double($0) } ?? delay

                let finalDelay = min(retryAfter, config.maxDelay)

                #if DEBUG
                print("[APIRetry] Status \(httpResponse.statusCode), retrying in \(String(format: "%.1f", finalDelay))s (attempt \(attempt + 1)/\(config.maxRetries))")
                #endif

                DispatchQueue.global().asyncAfter(deadline: .now() + finalDelay) {
                    performRequest(request, config: config, attempt: attempt + 1, completion: completion)
                }
                return
            }

            // No retry needed - return result
            completion(data, response, error)
        }.resume()
    }

    /// Parses API error response for user-friendly message
    static func parseErrorMessage(from data: Data?, statusCode: Int) -> String {
        // Try to parse xAI error format
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        // Fallback to status code descriptions
        switch statusCode {
        case 429:
            return "Rate limit exceeded. Please wait a moment and try again."
        case 401:
            return "Invalid API key. Please check your API key in Settings."
        case 403:
            return "Access denied. Your API key may not have access to this model."
        case 500...599:
            return "xAI server error. Please try again in a few moments."
        default:
            return "Request failed with status \(statusCode)."
        }
    }
}

// MARK: - Sidebar Tab Enum

/// Represents the different tabs in the sidebar
enum SidebarTab: String, Identifiable {
    case files = "Explorer"
    case chats = "Chats"
    case git = "Source Control"

    var id: String { rawValue }

    /// Tabs shown in the sidebar — git lives in footer branch indicator only.
    static var visibleTabs: [SidebarTab] { [.files, .chats] }

    var icon: String {
        switch self {
        case .files: return "folder"
        case .chats: return "bubble.left.and.bubble.right"
        case .git: return "arrow.triangle.branch"
        }
    }

    var selectedIcon: String {
        switch self {
        case .files: return "folder.fill"
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .git: return "arrow.triangle.branch"
        }
    }
}

// MARK: - Grok Build Modes (Chat / Agent / Agent full auto)

enum GrokBuildMode: String, CaseIterable, Identifiable {
    case chat
    case agent
    case agentAuto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat:      return "Chat"
        case .agent:     return "Agent"
        case .agentAuto: return "Agent (full auto)"
        }
    }

    var icon: String {
        switch self {
        case .chat:      return "bubble.left.and.bubble.right"
        case .agent:     return "person.crop.circle.badge.checkmark"
        case .agentAuto: return "play.fill"
        }
    }

    var description: String {
        switch self {
        case .chat:      return "Conversation and read-only exploration — no file changes"
        case .agent:     return "Human-in-the-loop — you approve each action"
        case .agentAuto: return "Full autonomy — agent runs tools without asking"
        }
    }

    var accentColor: Color {
        switch self {
        case .chat:      return .secondary
        case .agent:     return .blue
        case .agentAuto: return .green
        }
    }
}

struct GrokBuildModePicker: View {
    @Binding var mode: GrokBuildMode

    var body: some View {
        Menu {
            ForEach(GrokBuildMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    HStack {
                        Image(systemName: option.icon)
                        Text(option.displayName)
                        Spacer()
                        if mode == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.system(size: 10, weight: .medium))
                Text(mode.displayName)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Represents a file change in git
struct GitFileChange: Identifiable {
    let id = UUID()
    let path: String
    let status: GitStatus
    let url: URL
    let isStaged: Bool  // Track if file is staged for commit

    enum GitStatus: String {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case untracked = "?"

        var icon: String {
            switch self {
            case .modified: return "pencil.circle.fill"
            case .added: return "plus.circle.fill"
            case .deleted: return "minus.circle.fill"
            case .renamed: return "arrow.right.circle.fill"
            case .untracked: return "questionmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .modified: return .orange
            case .added: return .green
            case .deleted: return .red
            case .renamed: return .purple
            case .untracked: return .gray
            }
        }

        var label: String {
            switch self {
            case .modified: return "Modified"
            case .added: return "Added"
            case .deleted: return "Deleted"
            case .renamed: return "Renamed"
            case .untracked: return "Untracked"
            }
        }
    }
}

struct ModelResponse: Decodable {
    let data: [Model]
    struct Model: Decodable {
        let id: String
        let context_length: Int? // Context window size from API (if provided)
    }
}

class ModelRegistry {
    // Dynamic cache: Context window limits fetched from API
    static var modelContextLimits: [String: Int] = [:]
    // Dynamic cache: Pricing fetched from API (if available)
    static var modelPricing: [String: (input: Double, output: Double)] = [:]
    
    /// Canonical display order (Super Heavy / Grok Build models first).
    static let defaultModelPreference: [String] = [
        "grok-build-0.1",
        "grok-4.20-multi-agent-0309",
        "grok-4.20-0309-reasoning",
        "grok-4.20-0309-non-reasoning",
        "grok-4.3",
        "grok-imagine-image-quality",
        "grok-imagine-image",
        "grok-imagine-video",
        "grok-4-1-fast-reasoning",
        "grok-4-1-fast-non-reasoning",
        "grok-4-fast-reasoning",
        "grok-4-fast-non-reasoning",
        "grok-code-fast-1",
        "grok-4",
        "grok-2-vision-1212",
        "grok-2-1212",
        "grok-beta"
    ]

    static func sortedDisplayModels(_ models: [String]) -> [String] {
        let rank: [String: Int] = Dictionary(
            uniqueKeysWithValues: defaultModelPreference.enumerated().map { ($1, $0) }
        )
        return models.sorted { lhs, rhs in
            let l = rank[lhs] ?? Int.max
            let r = rank[rhs] ?? Int.max
            if l != r { return l < r }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    static func firstAvailable(from preferences: [String], in available: [String]) -> String? {
        if available.isEmpty { return preferences.first }
        let set = Set(available)
        return preferences.first { set.contains($0) }
    }

    static func fallbackModels(excluding failed: String, from available: [String]) -> [String] {
        sortedDisplayModels(available).filter { $0 != failed }
    }

    /// Returns a human-readable name for the model picker.
    static func friendlyName(for id: String) -> String {
        switch id {
        case "grok-build-0.1": return "Grok Build 0.1"
        case "grok-4.20-0309-non-reasoning": return "Grok 4.20 Fast"
        case "grok-4.20-0309-reasoning": return "Grok 4.20 Reasoning"
        case "grok-4.20-multi-agent-0309": return "Grok 4.20 Multi-Agent"
        case "grok-4.3": return "Grok 4.3"
        case "grok-imagine-image": return "Imagine Image"
        case "grok-imagine-image-quality": return "Imagine Image (HD)"
        case "grok-imagine-video": return "Imagine Video"
        case "grok-code-fast-1": return "Grok Build 0.1 (legacy ID)"
        case "grok-2-vision-1212": return "Grok 2 Vision"
        case "grok-2-1212": return "Grok 2"
        case "grok-3-mini": return "Grok 3 Mini"
        case "grok-beta": return "Grok Beta"
        default:
            break
        }

        let m = id.lowercased()
        if m.contains("4-1-fast") || m.contains("4.1-fast") { return "Grok 4.1 Fast" }
        if m.contains("4-fast") { return "Grok 4 Fast" }
        if m.contains("grok-4") { return "Grok 4" }
        if m.contains("grok-3") { return "Grok 3" }
        if m.contains("imagine") { return "Imagine" }
        return id.replacingOccurrences(of: "grok-", with: "Grok ").replacingOccurrences(of: "-", with: " ")
    }

    /// Short name for compact UI (input area)
    static func shortName(for id: String) -> String {
        switch id {
        case "grok-build-0.1": return "0.1 ⚡"
        case "grok-4.20-0309-non-reasoning": return "4.20 ⚡"
        case "grok-4.20-0309-reasoning": return "4.20 🧠"
        case "grok-4.20-multi-agent-0309": return "4.20 🤖"
        case "grok-4.3": return "4.3 🧠"
        case "grok-imagine-image": return "Imagine"
        case "grok-imagine-image-quality": return "Imagine HD"
        case "grok-imagine-video": return "Video"
        case "grok-code-fast-1": return "0.1 ⚡"
        case "grok-2-vision-1212": return "Vision"
        case "grok-2-1212": return "Grok 2"
        case "grok-3-mini": return "3 Mini"
        case "grok-beta": return "Beta"
        default:
            break
        }

        let m = id.lowercased()
        if m.contains("4-1-fast") || m.contains("4.1-fast") {
            if m.contains("non-reasoning") { return "4.1 ⚡" }
            if m.contains("reasoning") { return "4.1 🧠" }
            return "4.1"
        }
        if m.contains("4-fast") {
            if m.contains("non-reasoning") { return "4 ⚡" }
            if m.contains("reasoning") { return "4 🧠" }
            return "4 Fast"
        }
        if m.contains("grok-4") && !m.contains("fast") { return "Grok 4 🧠" }
        if m.contains("grok-3") && !m.contains("mini") { return "Grok 3" }
        if m.contains("imagine") || m.contains("vision") || m.contains("image") { return "Vision" }
        if m.contains("mini") { return "Mini" }
        let parts = id.replacingOccurrences(of: "grok-", with: "").split(separator: "-")
        return String(parts.first ?? "Grok").capitalized
    }
    
    /// Pricing per million tokens (input, output) in USD
    /// Based on xAI API pricing: https://docs.x.ai/docs/pricing
    /// Last updated: December 2025
    static func pricing(for model: String) -> (input: Double, output: Double) {
        // Check dynamic cache first
        if let cached = modelPricing[model] {
            return cached
        }
        
        let m = model.lowercased()

        // Grok Build 0.1 (agentic coding — same model as Grok Build CLI)
        if model == "grok-build-0.1" || m.contains("grok-build") {
            return (input: 1.00, output: 2.00)
        }
        
        // Grok 4 Series (Premium)
        if m.contains("grok-4.1-fast") || m.contains("grok-4-1-fast") {
            return (input: 3.00, output: 15.00) // $3/M input, $15/M output
        }
        if m.contains("grok-4") {
            return (input: 6.00, output: 30.00) // $6/M input, $30/M output
        }
        
        // Grok 3 Series
        if m.contains("grok-3-mini") {
            return (input: 0.30, output: 0.60) // Mini is cheaper
        }
        if m.contains("grok-3") {
            return (input: 3.00, output: 15.00)
        }
        
        // Grok 2 Series
        if m.contains("grok-2-vision") {
            return (input: 5.00, output: 15.00) // Vision has image cost
        }
        if m.contains("grok-2") {
            return (input: 2.00, output: 10.00)
        }
        
        // Legacy coding slug (retired → grok-build-0.1)
        if m.contains("grok-code") {
            return (input: 1.00, output: 2.00)
        }
        
        // Grok Beta (legacy)
        if m.contains("grok-beta") {
            return (input: 1.00, output: 5.00)
        }
        
        // Default fallback
        return (input: 2.00, output: 10.00)
    }
    
    /// Calculate cost for a given token count
    static func calculateCost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let prices = pricing(for: model)
        let inputCost = Double(inputTokens) / 1_000_000.0 * prices.input
        let outputCost = Double(outputTokens) / 1_000_000.0 * prices.output
        return inputCost + outputCost
    }
    
    static func supportsVision(_ id: String) -> Bool {
        let m = id.lowercased()
        return m.contains("vision") || m.contains("imagine-image") || m.contains("imagine-video")
            || (m.contains("image") && !m.contains("non-reasoning"))
    }

    static func isFast(_ id: String) -> Bool {
        let m = id.lowercased()
        return m.contains("non-reasoning") || m.contains("fast") || m.contains("mini")
            || id == "grok-build-0.1"
    }

    static func isCodeSpecialized(_ id: String) -> Bool {
        let m = id.lowercased()
        return m.contains("code") || id == "grok-build-0.1"
    }

    static func isMultiAgent(_ id: String) -> Bool {
        id.lowercased().contains("multi-agent")
    }

    /// Returns true only for actual reasoning models (excludes non-reasoning, fast, mini, vision)
    static func isReasoning(_ id: String) -> Bool {
        let m = id.lowercased()
        if m.contains("non-reasoning") { return false }
        if m.contains("mini") { return false }
        if m.contains("imagine") { return false }
        if m.contains("multi-agent") { return true }
        if m.contains("reasoning") { return true }
        if id == "grok-4.3" { return true }
        if m.contains("grok-4") && !m.contains("fast") && !m.contains("4.20") { return true }
        if m.contains("grok-3") && !m.contains("mini") { return true }
        if m.contains("grok-2") && !m.contains("vision") { return true }
        return false
    }

    /// Returns a brief description of the model's capabilities
    static func modelDescription(for id: String) -> String {
        let m = id.lowercased()

        if id == "grok-build-0.1" {
            return "⭐ Grok Build 0.1 • Agentic coding • Powers Grok Build CLI"
        }
        if id == "grok-4.20-multi-agent-0309" {
            return "🤖 Multi-agent orchestration • Complex tasks"
        }
        if id == "grok-4.20-0309-reasoning" {
            return "🧠 Deep reasoning • Latest Grok 4.20"
        }
        if id == "grok-4.20-0309-non-reasoning" {
            return "⚡ Fast responses • Latest Grok 4.20"
        }
        if id == "grok-4.3" {
            return "🧠 High-quality reasoning • Grok 4.3"
        }
        if id == "grok-imagine-image-quality" {
            return "🎨 High-quality image generation"
        }
        if id == "grok-imagine-image" {
            return "🎨 Image generation"
        }
        if id == "grok-imagine-video" {
            return "🎬 Video generation"
        }

        // Grok Build - Lightning fast for coding (legacy slug)
        if m.contains("code") {
            return "⚡ Legacy ID — use grok-build-0.1 • 256k context"
        }

        // Grok 4.1 Fast Series (Latest - November 2025)
        if m.contains("4-1-fast") || m.contains("4.1-fast") {
            if m.contains("non-reasoning") {
                return "🚀 Latest fast model • 2M context • No reasoning"
            }
            if m.contains("reasoning") {
                return "🧠 Latest fast model • 2M context • With reasoning"
            }
            return "🚀 Latest fast model • 2M context"
        }

        // Grok 4 Fast Series
        if m.contains("4-fast") || m.contains("4.fast") {
            if m.contains("non-reasoning") {
                return "⚡ Fast responses • 2M context • No reasoning"
            }
            if m.contains("reasoning") {
                return "🧠 Fast with reasoning • 2M context"
            }
            return "⚡ Fast responses • 2M context"
        }

        // Grok 4 (Premium)
        if m.contains("grok-4") && !m.contains("fast") {
            return "🏆 Best quality • Extended reasoning • 256k context"
        }

        // Grok 3 Series
        if m.contains("3-mini") || m.contains("mini") {
            return "Compact • Fast • Cost-effective"
        }
        if m.contains("grok-3") && !m.contains("mini") {
            return "Extended reasoning • High quality"
        }

        // Grok 2 Series
        if m.contains("vision") || m.contains("image") {
            return "👁️ Image understanding • Multimodal • 131k context"
        }
        if m.contains("grok-2") {
            return "Legacy model • 131k context"
        }

        // Default
        return "General purpose"
    }
    
    /// Task complexity level for model selection
    enum TaskComplexity: Int, Comparable {
        case simple = 1      // Basic questions, greetings
        case moderate = 2    // Standard coding, explanations
        case complex = 3     // Multi-step reasoning, complex coding
        case vision = 4      // Image-related (highest priority)

        static func < (lhs: TaskComplexity, rhs: TaskComplexity) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    /// Detected task type for model selection
    struct TaskAnalysis {
        var isCoding: Bool = false
        var isReasoning: Bool = false
        var isVision: Bool = false
        var complexity: TaskComplexity = .simple
        var codingScore: Int = 0      // Number of coding keywords matched
        var reasoningScore: Int = 0   // Number of reasoning keywords matched
        var detectedKeywords: [String] = []
    }

    /// Resolves which model to use based on selection, task type, and available models
    /// - Parameters:
    ///   - selected: The user-selected model (or "auto")
    ///   - hasImage: Whether the message includes an image
    ///   - textLength: The length of the input text
    ///   - messageText: The actual message text for task type detection
    ///   - availableModels: List of models available from the API (for validation)
    /// - Returns: A validated model ID that should work with the API
    static func resolveModel(selected: String, hasImage: Bool, textLength: Int, messageText: String = "", availableModels: [String] = []) -> String {
        let visionModels = [
            "grok-imagine-image-quality",
            "grok-imagine-image",
            "grok-2-vision-1212"
        ]
        let codingModels = [
            "grok-build-0.1",
            "grok-4.20-multi-agent-0309",
            "grok-4.20-0309-reasoning",
            "grok-code-fast-1",
            "grok-4.3",
            "grok-4.20-0309-non-reasoning"
        ]
        let reasoningModels = [
            "grok-4.20-multi-agent-0309",
            "grok-4.20-0309-reasoning",
            "grok-4.3",
            "grok-build-0.1",
            "grok-4-1-fast-reasoning",
            "grok-4-fast-reasoning",
            "grok-4"
        ]
        let defaultModels = defaultModelPreference

        let analysis = analyzeTask(messageText: messageText, hasImage: hasImage, textLength: textLength)

        func pick(from preferences: [String], reason: String) -> String {
            if let match = firstAvailable(from: preferences, in: availableModels) {
                return match
            }
            if let fallback = firstAvailable(from: defaultModels, in: availableModels) {
                return fallback
            }
            return preferences.first ?? defaultModels.first ?? "grok-build-0.1"
        }

        if selected != "auto" {
            if hasImage && !supportsVision(selected) {
                return pick(from: visionModels, reason: "vision override")
            }
            return selected
        }

        if analysis.isVision {
            return pick(from: visionModels, reason: "vision task")
        }
        if analysis.isCoding {
            return pick(from: codingModels, reason: "coding task")
        }
        if analysis.isReasoning || analysis.complexity == .complex || textLength > 1500 {
            return pick(from: reasoningModels, reason: "reasoning task")
        }
        return pick(from: defaultModels, reason: "general query")
    }

    /// Models known to work with Grok Build OAuth on the REST chat API.
    static let oauthCompatibleModels: [String] = [
        "grok-build-0.1",
        "grok-code-fast-1",
        "grok-4.20-0309-non-reasoning",
        "grok-4.20-0309-reasoning",
        "grok-4.20-multi-agent-0309",
        "grok-4-1-fast-non-reasoning",
        "grok-4-fast-non-reasoning",
        "grok-beta"
    ]

    /// When signed in via Grok Build OAuth, some picker models (e.g. grok-4.3) return HTTP 403 on the REST API.
    static func resolveAPIModel(
        selected: String,
        hasImage: Bool,
        textLength: Int,
        messageText: String = "",
        availableModels: [String] = [],
        useGrokBuildOAuth: Bool
    ) -> String {
        let resolved = resolveModel(
            selected: selected,
            hasImage: hasImage,
            textLength: textLength,
            messageText: messageText,
            availableModels: availableModels
        )
        guard useGrokBuildOAuth else { return normalizeModelID(resolved) }

        let pool = availableModels.isEmpty ? oauthCompatibleModels : availableModels
        let normalized = normalizeModelID(resolved)
        if pool.contains(normalized) { return normalized }
        return firstAvailable(from: oauthCompatibleModels, in: pool)
            ?? firstAvailable(from: defaultModelPreference, in: pool)
            ?? "grok-build-0.1"
    }

    /// Maps retired or alias model IDs to current API slugs.
    static func normalizeModelID(_ id: String) -> String {
        switch id {
        case "grok-code-fast-1":
            return "grok-build-0.1"
        default:
            return id
        }
    }

    /// Model slug for `grok agent stdio -m` (Grok Build CLI harness).
    static func resolveACPModel(selected: String, availableModels: [String] = []) -> String {
        let candidate: String
        if selected == "auto" {
            candidate = "grok-build-0.1"
        } else {
            candidate = normalizeModelID(selected)
        }

        if availableModels.isEmpty || availableModels.contains(candidate) {
            return candidate
        }

        return firstAvailable(from: ["grok-build-0.1", "grok-code-fast-1"], in: availableModels)
            ?? "grok-build-0.1"
    }

    /// Detects a simple "what's in this folder?" style request.
    static func messageAsksForDirectoryListing(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let phrases = [
            "what's in", "what is in", "whats in",
            "what's there", "what is there", "whats there",
            "this folder", "this directory", "current folder", "current directory",
            "list files", "list directory", "show files", "show me the files",
            "contents of", "what files", "files in", "files here", "in this project",
            "what do we have", "what's here", "what is here"
        ]
        return phrases.contains { lower.contains($0) }
    }

    /// Extracts a folder name from simple "create folder called X" requests.
    static func parseCreateFolderRequest(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)(?:create|make)\s+(?:a\s+)?(?:new\s+)?(?:folder|directory)(?:\s+(?:in\s+(?:here|this(?:\s+(?:folder|directory|project))?))?)?\s*(?:called|named)\s+["']?([^"'\n!?]+)["']?"#,
            #"(?i)(?:create|make)\s+(?:a\s+)?(?:new\s+)?(?:folder|directory)\s+["']?([^"'\s!?]+)["']?"#,
            #"(?i)mkdir\s+["']?([^"'\s!?]+)["']?"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed) else { continue }
            let name = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !name.contains(".."), !name.contains("/") { return name }
        }
        return nil
    }

    /// Analyzes the message to determine task type and complexity
    private static func analyzeTask(messageText: String, hasImage: Bool, textLength: Int) -> TaskAnalysis {
        var analysis = TaskAnalysis()
        let lowerText = messageText.lowercased()

        // Vision detection
        analysis.isVision = hasImage
        if hasImage {
            analysis.complexity = .vision
        }

        // Coding keywords with weights
        let codingKeywords: [(keyword: String, weight: Int)] = [
            // Programming languages (high weight)
            ("javascript", 2), ("typescript", 2), ("python", 2), ("swift", 2),
            ("java", 2), ("kotlin", 2), ("rust", 2), ("go", 2), ("ruby", 2),
            ("php", 2), ("c++", 2), ("c#", 2), ("sql", 2),
            // Frameworks (high weight)
            ("react", 2), ("next.js", 2), ("nextjs", 2), ("vue", 2), ("angular", 2),
            ("node", 2), ("express", 2), ("django", 2), ("flask", 2),
            ("swiftui", 2), ("tailwind", 2), ("bootstrap", 2),
            // Actions (medium weight)
            ("implement", 1), ("code", 1), ("debug", 1), ("refactor", 1),
            ("build", 1), ("deploy", 1), ("compile", 1), ("test", 1),
            ("fix the bug", 2), ("fix this", 1), ("fix error", 2),
            // Concepts (lower weight)
            ("function", 1), ("class", 1), ("api", 1), ("endpoint", 1),
            ("database", 1), ("query", 1), ("component", 1), ("module", 1),
            ("html", 1), ("css", 1), ("json", 1), ("xml", 1),
            ("website", 1), ("web app", 2), ("mobile app", 2), ("app", 1),
            ("script", 1), ("program", 1), ("algorithm", 1),
            ("create a", 1), ("write a", 1), ("make a", 1),
            ("frontend", 1), ("backend", 1), ("fullstack", 1),
            ("git", 1), ("npm", 1), ("yarn", 1), ("package", 1)
        ]

        // Reasoning keywords with weights
        let reasoningKeywords: [(keyword: String, weight: Int)] = [
            // Deep analysis (high weight)
            ("explain in detail", 3), ("step by step", 3), ("think through", 3),
            ("reasoning", 2), ("analyze", 2), ("evaluate", 2),
            ("what is the difference", 2), ("compare and contrast", 2),
            ("pros and cons", 2), ("advantages and disadvantages", 2),
            // Questions requiring thought (medium weight)
            ("why does", 1), ("why is", 1), ("how does", 1), ("how is", 1),
            ("what causes", 1), ("explain", 1), ("describe", 1),
            ("compare", 1), ("contrast", 1), ("analyze", 1),
            // Complex topics (medium weight)
            ("theory", 1), ("concept", 1), ("principle", 1),
            ("understand", 1), ("meaning", 1), ("significance", 1),
            ("implications", 2), ("consequences", 2),
            ("in depth", 2), ("comprehensive", 2), ("thorough", 2)
        ]

        // Score coding keywords
        for (keyword, weight) in codingKeywords {
            if lowerText.contains(keyword) {
                analysis.codingScore += weight
                analysis.detectedKeywords.append(keyword)
            }
        }
        analysis.isCoding = analysis.codingScore >= 2

        // Score reasoning keywords
        for (keyword, weight) in reasoningKeywords {
            if lowerText.contains(keyword) {
                analysis.reasoningScore += weight
                analysis.detectedKeywords.append(keyword)
            }
        }
        analysis.isReasoning = analysis.reasoningScore >= 2

        // Determine complexity
        if !analysis.isVision {
            let totalScore = analysis.codingScore + analysis.reasoningScore
            if totalScore >= 6 || (analysis.isCoding && analysis.isReasoning) {
                analysis.complexity = .complex
            } else if totalScore >= 2 || textLength > 500 {
                analysis.complexity = .moderate
            } else {
                analysis.complexity = .simple
            }
        }

        return analysis
    }
    
    /// Returns the context window size (in tokens) for a given model
    /// 
    /// **Future-Proofing Strategy:**
    /// 1. First checks the dynamic cache (populated from API responses)
    /// 2. Falls back to hardcoded values based on official xAI docs
    /// 3. Uses conservative default (128K) for unknown models
    ///
    /// **To Update When New Models Arrive:**
    /// - Option A: API will automatically populate the cache via `fetchModels()`
    /// - Option B: Add new model patterns below in the hardcoded section
    /// - Option C: Update the remote config file (future enhancement)
    ///
    /// **Official Source:** https://docs.x.ai/docs/models
    /// **Last Updated:** December 2025
    static func contextWindow(for model: String) -> Int {
        // 1. Check dynamic cache first (API response)
        if let cachedLimit = modelContextLimits[model] {
            return cachedLimit
        }
        
        // 2. Fallback to hardcoded values (based on model patterns)
        let modelLower = model.lowercased()
        
        // Grok 4.20 / Super Heavy models
        if modelLower.contains("4.20") {
            return 2_000_000
        }
        // Grok Build 0.1 / legacy code slug
        if modelLower.contains("grok-build") || modelLower.contains("grok-code") {
            return 256_000
        }
        if model == "grok-4.3" {
            return 256_000
        }

        // Grok 4 Series (Latest)
        if modelLower.contains("grok-4.1-fast") || modelLower.contains("grok-4.1fast") {
            return 2_000_000 // 2M tokens - Grok 4.1 Fast
        }
        if modelLower.contains("grok-4") {
            return 256_000 // 256K tokens - Grok 4 (pricing tiers at 128K)
        }
        
        // Grok 3 Series
        if modelLower.contains("grok-3") {
            if modelLower.contains("beta") {
                return 1_000_000 // 1M tokens - Grok 3 Beta
            }
            return 131_072 // 131K tokens - Grok 3 / Grok 3 Mini
        }
        
        // Grok 2 Series
        if modelLower.contains("grok-2") {
            return 128_000 // 128K tokens - All Grok 2 variants (vision, 1212, etc.)
        }
        
        // Grok 1.5
        if modelLower.contains("grok-1.5") {
            return 128_000 // 128K tokens
        }
        
        // Grok Beta (legacy)
        if modelLower.contains("grok-beta") {
            return 131_072 // 131K tokens
        }
        
        // Fallback for unknown models
        return 128_000 // Default: 128K tokens
    }
}

// MARK: - ToolAction (top-level so ChatMessage can reference it)
enum ToolAction: Codable, Equatable {
    case terminal(String)
    case readFile(String)
    case writeFile(String, String)
    case createDirectory(String)
    case fetchWeb(String)
    case searchWeb(String)
    case openURL(String)
    case checkServerStatus(Int)

    var isReadOnly: Bool {
        switch self {
        case .readFile, .checkServerStatus:
            return true
        case .terminal(let cmd):
            let normalized = cmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let readOnlyPrefixes = ["ls", "pwd", "cat ", "head ", "tail ", "find ", "tree", "git status", "git log", "git diff", "git branch"]
            return readOnlyPrefixes.contains { normalized == $0 || normalized.hasPrefix($0) }
        case .writeFile, .createDirectory, .fetchWeb, .searchWeb, .openURL:
            return false
        }
    }

    var description: String {
        switch self {
        case .terminal(let cmd): return cmd
        case .readFile(let path): return "Read \(path)"
        case .writeFile(let path, _): return "Write \(path)"
        case .createDirectory(let path): return "Create folder \(path)"
        case .fetchWeb(let url): return "Fetch \(url)"
        case .searchWeb(let query): return "Search: \(query)"
        case .openURL(let url): return "Open \(url)"
        case .checkServerStatus(let port): return "Check localhost:\(port)"
        }
    }
}

// MARK: - Models
struct ChatMessage: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    let role: String // "user" or "assistant"
    var content: String
    var isThinking: Bool = false
    var imageData: Data? = nil // For Vision support
    var usedModel: String? // Track which model generated this (final model)
    var modelsAttempted: [String]? // Track all models attempted (for fallback display)
    var toolAction: String? = nil // Tool action executed (e.g., "rm file.md")
    var toolOutput: String? = nil // Tool execution result
    var isHiddenFromUI: Bool = false // Hide from UI but keep for API context
    var pendingToolAction: ToolAction? = nil // For Agent mode approval (transient, not persisted)
    var activityLines: [AgentActivityLine] = [] // Live inference steps (runtime only)

    // Exclude pendingToolAction from Codable since it's runtime-only state
    enum CodingKeys: String, CodingKey {
        case id, role, content, isThinking, imageData, usedModel, modelsAttempted, toolAction, toolOutput, isHiddenFromUI
    }
}

struct AgentActivityLine: Identifiable, Equatable {
    let id: UUID
    var icon: String
    var title: String
    var detail: String?
    var isInProgress: Bool

    init(id: UUID = UUID(), icon: String, title: String, detail: String? = nil, isInProgress: Bool = false) {
        self.id = id
        self.icon = icon
        self.title = title
        self.detail = detail
        self.isInProgress = isInProgress
    }

    /// Status-only lines that should disappear once a response is shown.
    static let transientTitles: Set<String> = [
        "Thinking...", "Thinking…", "Thinking",
        "Connecting...", "Processing...", "Analyzing results",
        "Starting Grok agent...", "Starting agent…", "Creating session...", "Preparing session…",
        "Waiting for Grok agent...", "Connecting…"
    ]

    var isTransient: Bool { Self.transientTitles.contains(title) }

    static func visibleLines(from lines: [AgentActivityLine], isLive: Bool) -> [AgentActivityLine] {
        if isLive { return lines }
        return lines.filter { !$0.isTransient }
    }
}

struct ChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var lastModified: Date
}

struct FileSystemItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    var children: [FileSystemItem]?
}

// MARK: - Persistence Helper
class PersistenceController {
    static let shared = PersistenceController()
    
    private var historyURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("GrokBuild/History") // Renamed from GrokCode for Grok Build branding
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("sessions.json")
    }
    
    func save(sessions: [ChatSession]) {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: historyURL)
        } catch {
            #if DEBUG
            print("Failed to save history: \(error)")
            #endif
        }
    }
    
    func load() -> [ChatSession] {
        do {
            let data = try Data(contentsOf: historyURL)
            return try JSONDecoder().decode([ChatSession].self, from: data)
        } catch {
            return []
        }
    }
    
    func cleanOldSessions(days: Int, sessions: [ChatSession]) -> [ChatSession] {
        guard days > 0 else { return sessions }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return sessions.filter { $0.lastModified > cutoff }
    }
}

// MARK: - Shared Grok icon helper

/// Crisp Grok mark for toolbars, sidebars, and inline UI. Uses the MenuBarIcon asset at native resolution.
struct GrokMarkView: View {
    var size: CGFloat = 14
    var template: Bool = true
    var opacity: Double = 1.0

    var body: some View {
        Image("MenuBarIcon")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .renderingMode(template ? .template : .original)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .opacity(opacity)
            // Prefer vector-like downscale; avoid low-quality bilinear softening in toolbars.
            .accessibilityHidden(true)
    }
}

private func makeGrokLogoImage(size: CGFloat, template: Bool = false) -> NSImage? {
    guard let grokIcon = NSImage(named: "MenuBarIcon") else { return nil }
    let icon = grokIcon.copy() as! NSImage
    icon.isTemplate = template
    // Preserve source resolution; AppKit/SwiftUI scales down with better filtering than a tiny raster.
    return icon
}

private func makeGrokMenuBarIcon(size: CGFloat = 14) -> NSImage? {
    makeGrokLogoImage(size: size, template: true)
}

struct GrokLogoView: View {
    var size: CGFloat = 48
    var template: Bool = false
    var opacity: Double = 1.0
    
    var body: some View {
        Group {
            if NSImage(named: "MenuBarIcon") != nil {
                GrokMarkView(size: size, template: template, opacity: opacity)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.orange)
                    .opacity(opacity)
            }
        }
    }
}

// MARK: - Main View
struct DeveloperRootView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var apiKey: String = "" // Loaded from Keychain on appear
    
    // Grok Build CLI session (Super Heavy) - primary auth path
    @StateObject private var grokBuildAuth = GrokBuildAuthManager.shared
    @StateObject private var orchestrator = AgentOrchestrator.shared

    @AppStorage("grok_build_mode") private var grokBuildModeRaw: String = GrokBuildMode.agentAuto.rawValue

    private var grokBuildMode: GrokBuildMode {
        if grokBuildModeRaw == "plan" { return .chat }
        return GrokBuildMode(rawValue: grokBuildModeRaw) ?? .agentAuto
    }

    private var grokBuildModeBinding: Binding<GrokBuildMode> {
        Binding(
            get: {
                if grokBuildModeRaw == "plan" { return .chat }
                return GrokBuildMode(rawValue: grokBuildModeRaw) ?? .agentAuto
            },
            set: { grokBuildModeRaw = $0.rawValue }
        )
    }

    @AppStorage("selected_model") private var selectedModel: String = "auto" // Default to Auto
    @AppStorage("chatRetentionDays") private var chatRetention: Int = 30 // 0 = Forever
    @AppStorage("safetyEnabled") private var safetyEnabled: Bool = true // Default: ON for safety
    
    // Feature Switch: Working Directory with Bookmark Persistence
    @AppStorage("workingDirectoryBookmark") private var workingDirectoryBookmark: Data?
    @State private var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    /// Rejects macOS temp dirs and other paths that aren't real project folders.
    private static func isUsableProjectDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if path == temp || path.hasPrefix(temp + "/") { return false }
        if path.contains("/var/folders/") && path.contains("/T") { return false }
        if path == "/tmp" || path.hasPrefix("/tmp/") { return false }
        return true
    }

    private var hasProjectFolder: Bool {
        workingDirectoryBookmark != nil && Self.isUsableProjectDirectory(workingDirectory)
    }
    @State private var sessions: [ChatSession] = []
    @State private var currentSessionId: UUID = UUID()
    
    // Chat State (Active Session)
    @State private var messages: [ChatMessage] = []
    @State private var inputMessage = ""
    @State private var inputImage: Data? = nil
    @State private var inputHeight: CGFloat = 24 // Dynamic height for input field
    @State private var totalTokens: Int = 0
    @State private var contextUsage: Double = 0.0 // 0.0 to 1.0
    @State private var currentModelUsed: String? = nil // Track which model was used for token calc
    @State private var currentRequestId: UUID? = nil // For request cancellation tracking
    
    // Cost Tracking
    @State private var lastInputTokens: Int = 0
    @State private var lastOutputTokens: Int = 0
    @State private var sessionCost: Double = 0.0 // Cost for current session
    @State private var totalCost: Double = 0.0 // Cumulative cost (persisted)

    // Git Repository State
    @State private var gitBranch: String? = nil
    @State private var gitBranches: [String] = []
    @State private var hasUncommittedChanges: Bool = false
    @State private var gitRepositoryPath: String? = nil
    @State private var isInitializingRepo: Bool = false
    
    @State private var isSending: Bool = false
    @State private var isLoadingModels: Bool = false
    @State private var availableModels: [String] = []
    @State private var errorMessage: String?
    @State private var isShowingConsole: Bool = false
    @State private var requestStatus: String = "" // For showing what's happening
    @State private var requestStartTime: Date? = nil
    @State private var activeAssistantMessageId: UUID?
    
    // Sidebar State
    @State private var isSidebarExpanded: Bool = true
    @State private var selectedSidebarTab: SidebarTab = .files
    @State private var fileTree: [FileSystemItem] = []
    @State private var expandedFileIds: Set<UUID> = []
    @State private var gitChangedFiles: [GitFileChange] = []
    @State private var commitMessage: String = ""
    
    // Chat Management State
    @State private var sessionToDelete: ChatSession?
    @State private var isShowingDeleteConfirmation: Bool = false
    @State private var sessionToRename: ChatSession?
    @State private var isShowingRenameAlert: Bool = false
    @State private var newChatTitle: String = ""
    
    @State private var showingAPIKeySheet = false

    // Event Monitor (for cleanup)
    @State private var eventMonitor: Any?

    // File System Monitoring
    @State private var fileSystemMonitor: DispatchSourceFileSystemObject?
    @State private var monitoredFileDescriptor: Int32?
    @State private var refreshDebounceTimer: Timer?

    // Background Process Management
    @State private var runningProcesses: [UUID: Process] = [:]

    // Dynamic Colors
    var bgDark: Color { Color(nsColor: .windowBackgroundColor) }
    var sidebarBg: Color { Color(nsColor: .controlBackgroundColor) }
    var textGray: Color { Color.secondary }

    // Extracted model selector label to keep the complex conditional logic out of the Menu label
    // (prevents "Type '()' cannot conform to 'View'" errors in view builders)
    @ViewBuilder
    private var modelSelectorLabel: some View {
        HStack(spacing: 4) {
            if selectedModel == "auto" {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text("Auto")
                    .font(.system(size: 11, weight: .medium))
            } else {
                Text(ModelRegistry.shortName(for: selectedModel))
                    .font(.system(size: 11, weight: .medium))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // Extracted to keep the main body expression small enough for the SwiftUI compiler
    @ViewBuilder
    private var mainContentView: some View {
        if isShowingConsole {
            ConsoleWebView(onBack: { isShowingConsole = false })
                .transition(.move(edge: .bottom))
        } else if grokBuildAuth.isUsingGrokBuildSession {
            // Using Grok Build Super Heavy session (preferred)
            if sessions.isEmpty && messages.isEmpty {
                ChatInterface
            } else {
                ChatInterface
            }
        } else if let cliSession = grokBuildAuth.detectGrokBuildCLISession() {
            GrokBuildContinuePrompt(session: cliSession) {
                _ = grokBuildAuth.importFromGrokBuildCLI()
                fetchModels()
            } fallbackAPIKeyPrompt: {
                showingAPIKeySheet = true
            }
        } else if apiKey.isEmpty && !grokBuildAuth.isUsingGrokBuildSession {
            GrokBuildOnboardingView(
                authManager: grokBuildAuth,
                apiKey: $apiKey,
                onUnlock: fetchModels
            )
        } else if sessions.isEmpty && messages.isEmpty {
            ChatInterface
        } else {
            ChatInterface
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            ZStack(alignment: .leading) {
                sidebarBg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header (Logo + Toggle)
                    HStack {
                        if isSidebarExpanded {
                            HStack(spacing: 8) {
                                GrokMarkView(size: 18, template: true)
                                Text("Grok Build")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(Color.primary)
                            }
                            Spacer()
                        }
                        Button(action: { isSidebarExpanded.toggle() }) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() }
                            else { NSCursor.pop() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(height: 50)
                    
                    if isSidebarExpanded {
                        sidebarProjectsTab
                            .frame(maxHeight: .infinity)
                    } else {
                        VStack(spacing: 4) {
                            Button(action: startNewAgent) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .help("New Agent")
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() }
                                else { NSCursor.pop() }
                            }

                            Button(action: { isSidebarExpanded = true }) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .help("Projects")
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() }
                                else { NSCursor.pop() }
                            }

                            Spacer()
                        }
                        .padding(.top, 8)
                    }

                    // Sidebar Footer
                    VStack(spacing: 6) {
                        Divider()

                        // Git branch (compact footer when in a repo)
                        if isSidebarExpanded, let branch = gitBranch, hasProjectFolder {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                Text(branch)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if hasUncommittedChanges {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 6, height: 6)
                                        .help("Uncommitted changes")
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(width: isSidebarExpanded ? 260 : 60)
            .animation(.spring(response: 0.3), value: isSidebarExpanded)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ReloadGrokHistory"))) { _ in
                let loaded = PersistenceController.shared.load()
                sessions = PersistenceController.shared.cleanOldSessions(days: chatRetention, sessions: loaded)
            }
            .overlay(
                Rectangle()
                    .frame(width: 1)
                    .foregroundStyle(.quaternary),
                alignment: .trailing
            )
            
            // MARK: - Main Content
            ZStack {
                bgDark.ignoresSafeArea()
                mainContentView
            }
        }

        .onAppear {
            // Migrate API key from UserDefaults to Keychain (one-time)
            KeychainHelper.shared.migrateAPIKeyFromUserDefaults()

            // Load API key from Keychain
            apiKey = KeychainHelper.shared.getAPIKey() ?? ""
            
            // Grok Build: prefer CLI OAuth session (same ~/.grok/auth.json as CLI / VS Code)
            grokBuildAuth.bootstrapFromCLIIfNeeded()

            // Restore folder access before bootstrap so project/thread state matches disk
            restoreDirectoryAccess()
            orchestrator.bootstrap(projectPath: workingDirectory)

            if sessions.isEmpty {
                let loaded = PersistenceController.shared.load()
                sessions = PersistenceController.shared.cleanOldSessions(days: chatRetention, sessions: loaded)
            }

            if !orchestrator.store.snapshot.workspaces.isEmpty {
                sessions = orchestrator.store.allThreadsFlat().map { $0.asChatSession }
            }

            beginEmptyAgentSession()
            prewarmAgentIfNeeded()
            refreshFileList()
            refreshGitStatus()

            // Load persisted total API cost
            totalCost = UserDefaults.standard.double(forKey: "totalApiCost")

            // Auto-refresh available models on load
            fetchModels()
        }
        .onDisappear {
            // Clean up file system monitoring
            stopFileSystemMonitoring()
        }
        .onChange(of: apiKey) { newValue in
            // Save API key to Keychain when it changes
            if newValue.isEmpty {
                KeychainHelper.shared.deleteAPIKey()
            } else {
                KeychainHelper.shared.saveAPIKey(newValue)
            }
        }
        .onChange(of: grokBuildModeRaw) { _ in
            prewarmAgentIfNeeded()
        }
        .frame(minWidth: 900, minHeight: 600)
        // Alerts
        .alert("Delete Chat", isPresented: $isShowingDeleteConfirmation, presenting: sessionToDelete) { session in
            Button("Delete", role: .destructive) { deleteChat(session) }
            Button("Cancel", role: .cancel) { }
        } message: { session in
            Text("Are you sure you want to delete \"\(session.title)\"? This cannot be undone.")
        }
        .alert("Rename Chat", isPresented: $isShowingRenameAlert) {
            TextField("New Name", text: $newChatTitle)
            Button("Rename") {
                if let session = sessionToRename {
                    renameChat(session, newTitle: newChatTitle)
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        // Keyboard shortcut for paste (Cmd+V)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
            // Nothing needed here, but ensures view is ready
        }
        // Listen for API key changes from Settings window
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("APIKeyChanged"))) { notification in
            if let newKey = notification.object as? String {
                apiKey = newKey
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenProjectFolder"))) { _ in
            selectDirectory()
        }
        .sheet(isPresented: $showingAPIKeySheet) {
            GrokBuildAPIKeySheet(apiKey: $apiKey, onSave: {
                showingAPIKeySheet = false
                fetchModels()
            })
        }
    }
    
    /// Resolves Grok Build OAuth token (with refresh) or falls back to API key.
    private func authTokenForRequest(completion: @escaping (String?) -> Void) {
        grokBuildAuth.refreshAccessTokenIfNeeded { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let token):
                    completion(token)
                case .failure:
                    completion(self.grokBuildAuth.resolvedAuthToken(fallbackApiKey: self.apiKey))
                }
            }
        }
    }
    
    var ChatInterface: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                VStack(spacing: 20) {
                    Spacer()
                    GrokMarkView(size: 72, template: true, opacity: 0.2)
                    VStack(spacing: 8) {
                        Text("Grok Build")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.25))
                        Text("What do you want to build?")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(messages.filter { !$0.isHiddenFromUI }) { message in
                                MessageBubble(
    message: message,
    requestStatus: statusText(for: message),
    isActiveInference: isSending && message.id == activeAssistantMessageId,
    onApprove: message.pendingToolAction != nil ? { approvePendingTool(messageId: message.id) } : nil,
    onReject: message.pendingToolAction != nil ? { rejectPendingTool(messageId: message.id) } : nil
)
                                    .id(message.id)
                            }
                            if isLoadingModels || isSending {
                                // ProgressView handled in bubbles or logic
                            }
                            Color.clear.frame(height: 1).id("BOTTOM")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: messages) { _ in
                        withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                    }
                }
            }
            // Seamless Input Area - No Divider
            HStack {
                Spacer()
                InputArea
                    .padding(.bottom, 20)
                    // Listen for Context Transfer (Attached here for safe type inference)
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TransferWebContext"))) { notification in
                        if let text = notification.object as? String {
                            // Smart Append
                            if inputMessage.isEmpty {
                                inputMessage = text
                            } else {
                                inputMessage += "\n\n" + text
                            }
                            // Update height for new content
                            inputHeight = calculateInputHeight(for: inputMessage)
                        }
                    }
                    // Listen for Spotlight queries sent to Code mode
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SpotlightQuery"))) { notification in
                        if let query = notification.object as? String {
                            inputMessage = query
                            // Update height for new content
                            inputHeight = calculateInputHeight(for: inputMessage)
                            // Auto-send the query
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                sendMessage()
                            }
                        }
                    }
                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }
    
    var InputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imgData = inputImage, let nsImage = NSImage(data: imgData) {
                HStack(spacing: 8) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(action: { inputImage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 10) {
                    Menu {
                        Button(action: pasteImage) {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }
                        Button(action: takeScreenshot) {
                            Label("Take Screenshot", systemImage: "camera.viewfinder")
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)

                    ZStack(alignment: .topLeading) {
                        if inputMessage.isEmpty {
                            Text("Message Grok Build…")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 7)
                                .padding(.leading, 2)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                        }

                        CustomTextEditor(
                            text: $inputMessage,
                            onSubmit: { sendMessage() },
                            onTextChange: {
                                ensureCurrentChatExists()
                                inputHeight = calculateInputHeight(for: inputMessage)
                            }
                        )
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(height: inputHeight)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .layoutPriority(1)

                Menu {
                    // Auto Option
                    Button(action: { selectedModel = "auto" }) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.orange)
                                Text("Auto (Smart)")
                                    .fontWeight(.medium)
                                Spacer()
                                if selectedModel == "auto" {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text("Automatically picks Grok Build on Super Heavy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    Divider()

                    ForEach(availableModels, id: \.self) { (model: String) in
                        Button(action: { self.selectedModel = model }) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    // Model Name
                                    Text(ModelRegistry.friendlyName(for: model))
                                        .fontWeight(.medium)

                                    Spacer()

                                    // Capability Icons with better clarity
                                    HStack(spacing: 4) {
                                        if ModelRegistry.supportsVision(model) {
                                            Image(systemName: "eye.fill")
                                                .foregroundStyle(.blue)
                                                .help("Vision: Can process images")
                                        }
                                        if ModelRegistry.isReasoning(model) {
                                            Image(systemName: "brain.head.profile")
                                                .foregroundStyle(.purple)
                                                .help("Reasoning: Extended thinking capability")
                                        }
                                        if ModelRegistry.isFast(model) {
                                            Image(systemName: "bolt.fill")
                                                .foregroundStyle(.yellow)
                                                .help("Fast: Optimized for speed")
                                        }
                                        if ModelRegistry.isMultiAgent(model) {
                                            Image(systemName: "person.3.fill")
                                                .foregroundStyle(.cyan)
                                                .help("Multi-agent orchestration")
                                        }
                                        if ModelRegistry.isCodeSpecialized(model) {
                                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                                .foregroundStyle(.green)
                                                .help("Code: Specialized for programming")
                                        }
                                    }
                                    .font(.caption)

                                    if selectedModel == model {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }

                                // Description
                                Text(ModelRegistry.modelDescription(for: model))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } label: {
                    modelSelectorLabel
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)

                    Button(action: {
                        if isSending { stopGeneration() } else { sendMessage() }
                    }) {
                        Image(systemName: isSending ? "stop.fill" : "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(isSending ? Color.red : Color.primary)
                            .clipShape(Circle())
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    }
                    .buttonStyle(.plain)
                    .disabled((inputMessage.isEmpty && inputImage == nil) && !isSending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    GrokBuildModePicker(mode: grokBuildModeBinding)
                    if isSending {
                        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(activityStatusLabel)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else if orchestrator.isSessionReady {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Grok CLI ready")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else if orchestrator.isPrewarming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Starting Grok CLI…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else if grokBuildMode != .chat, orchestrator.prewarmFailed {
                        Text("Grok CLI offline · API fallback")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if grokBuildMode != .chat {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Starting Grok CLI…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if totalTokens > 0, let model = currentModelUsed {
                        ContextWindowIndicator(
                            tokens: totalTokens,
                            usage: contextUsage,
                            model: model,
                            inputTokens: lastInputTokens,
                            outputTokens: lastOutputTokens,
                            sessionCost: sessionCost,
                            totalCost: totalCost
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: 640)
        // Handle Cmd+V for image paste
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Check for Cmd+V
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                    // Only handle if there's an image in clipboard (not text)
                    let pb = NSPasteboard.general
                    if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
                        self.pasteImage()
                        return nil // Consume the event
                    }
                }
                return event // Pass through
            }
        }
        .onDisappear {
            // Clean up event monitor to prevent memory leak
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }

    // MARK: - Sidebar Tab Views

    /// Files tab — project explorer only
    private var sidebarFilesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Explorer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: refreshFileList) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(!hasProjectFolder)
                Button(action: selectDirectory) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open Folder…")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if hasProjectFolder {
                Text(workingDirectory.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()
                .padding(.horizontal, 8)

            ScrollView {
                if !hasProjectFolder {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("Open a project folder")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Grok Build will read and edit files in the folder you choose.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Button("Open Folder…", action: selectDirectory)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .padding(.horizontal, 12)
                } else if fileTree.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("Empty folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(fileTree) { item in
                            FileRowWithContextMenu(item: item, depth: 0)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Projects sidebar — folder = agent context, threads nested under each project
    private var sidebarProjectsTab: some View {
        ProjectsSidebarView(
            store: orchestrator.store,
            authManager: grokBuildAuth,
            hasAPIKey: !apiKey.isEmpty,
            selectedProjectId: orchestrator.store.snapshot.selectedProjectId,
            currentThreadId: $currentSessionId,
            busyThreadIds: [],
            onNewAgent: startNewAgent,
            onSelectProject: activateProject,
            onSelectThread: activateThread,
            onOpenSettings: openSettings,
            onNewThread: { project in
                orchestrator.store.select(projectId: project.id)
                let thread = orchestrator.store.createThread(inProjectId: project.id, title: "New Chat")
                activateThread(thread, project: project)
            },
            onDeleteThread: { id in
                if let thread = orchestrator.store.allThreadsFlat().first(where: { $0.id == id }) {
                    deleteChat(thread.asChatSession)
                }
                orchestrator.store.deleteThread(id)
            },
            onRenameThread: { id, currentTitle in
                if let thread = orchestrator.store.allThreadsFlat().first(where: { $0.id == id }) {
                    sessionToRename = thread.asChatSession
                    newChatTitle = currentTitle
                    isShowingRenameAlert = true
                }
            },
            onArchiveThread: { id in
                orchestrator.store.archiveThread(id)
                if currentSessionId == id,
                   let project = orchestrator.store.selectedProject,
                   let next = orchestrator.store.activeThreads(for: project).first {
                    activateThread(next, project: project)
                }
            },
            onUnarchiveThread: { id in
                orchestrator.store.unarchiveThread(id)
                if let project = orchestrator.store.selectedProject,
                   let thread = project.threads.first(where: { $0.id == id }) {
                    activateThread(thread, project: project)
                }
            },
            onNewWorktree: startNewWorktree,
            onSwitchBranch: requestSwitchBranch,
            onRemoveProject: { project in
                orchestrator.store.removeProject(id: project.id)
                if let next = orchestrator.store.selectedProject {
                    activateProject(next)
                } else {
                    sessions = []
                    messages = []
                }
            },
            onTogglePin: { project in
                orchestrator.store.toggleProjectPinned(project.id)
            },
            showInactiveProjects: .constant(true)
        )
    }

    // MARK: - Git worktree / branch actions

    func startNewWorktree(for project: AgentProject) {
        guard GitService.isRepository(at: project.path) else {
            presentGitError("\(project.name) is not a git repository.")
            return
        }
        guard let branch = promptForBranchName() else { return }
        switch GitService.createWorktree(repoPath: project.path, branch: branch) {
        case .success(let worktreePath):
            let worktree = orchestrator.store.addWorktreeProject(
                name: branch,
                path: worktreePath,
                branch: branch,
                parentRepoPath: project.path
            )
            openProjectFolder(worktree.url, startNewAgent: true)
        case .failure(let error):
            presentGitError(error.localizedDescription)
        }
    }

    func requestSwitchBranch(for project: AgentProject) {
        guard GitService.isRepository(at: project.path) else {
            presentGitError("\(project.name) is not a git repository.")
            return
        }
        let branches = GitService.localBranches(at: project.path)
        guard !branches.isEmpty else {
            presentGitError("No local branches found for \(project.name).")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Switch Branch"
        alert.informativeText = "Choose a branch to check out in \(project.name)."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        popup.addItems(withTitles: branches)
        if let current = project.gitBranch, branches.contains(current) {
            popup.selectItem(withTitle: current)
        }
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn,
              let branch = popup.titleOfSelectedItem else { return }
        switchBranch(for: project, to: branch)
    }

    func switchBranch(for project: AgentProject, to branch: String) {
        switch GitService.switchBranch(branch, at: project.path) {
        case .success:
            orchestrator.store.setBranch(branch, for: project.id)
            refreshGitStatus()
        case .failure(let error):
            presentGitError(error.localizedDescription)
        }
    }

    func promptForBranchName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "Enter a branch name. A new branch is created if it doesn't already exist."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "feature/my-branch"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func presentGitError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Git"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Git/Source Control tab content
    /// Computed properties for staged/unstaged file separation
    private var stagedFiles: [GitFileChange] {
        gitChangedFiles.filter { $0.isStaged }
    }

    private var unstagedFiles: [GitFileChange] {
        gitChangedFiles.filter { !$0.isStaged }
    }

    private var sidebarGitTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Repository Header with path context
            VStack(alignment: .leading, spacing: 4) {
                // Branch info
                HStack {
                    if let branch = gitBranch {
                        // Branch selector menu
                        Menu {
                            ForEach(gitBranches, id: \.self) { branchName in
                                Button(action: {
                                    if branchName != gitBranch {
                                        switchBranch(to: branchName)
                                    }
                                }) {
                                    HStack {
                                        Text(branchName)
                                        if branchName == gitBranch {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                                Text(branch)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                if gitBranches.count > 1 {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                if hasUncommittedChanges {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .help(gitBranches.count > 1 ? "Switch branch" : "Current branch")
                    } else if workingDirectoryBookmark == nil {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("No folder selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Not a git repository")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: { refreshGitStatus(); refreshGitChanges() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh git status")
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }

                // Repository path context (truncated)
                if gitBranch != nil {
                    Text(workingDirectory.lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.2))

            if gitBranch != nil {
                // Changes List
                if gitChangedFiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                        Text("Working tree clean")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("No uncommitted changes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Staged Changes Section
                            if !stagedFiles.isEmpty {
                                gitSectionHeader(title: "STAGED CHANGES", count: stagedFiles.count, color: .green)
                                ForEach(stagedFiles) { file in
                                    gitFileRow(file: file, isStaged: true)
                                }
                            }

                            // Unstaged Changes Section
                            if !unstagedFiles.isEmpty {
                                gitSectionHeader(title: "CHANGES", count: unstagedFiles.count, color: .orange)
                                ForEach(unstagedFiles) { file in
                                    gitFileRow(file: file, isStaged: false)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    }

                    Divider()
                        .padding(.horizontal, 8)

                    // Commit Section
                    VStack(spacing: 8) {
                        TextField("Commit message...", text: $commitMessage)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .padding(8)
                            .background(.quaternary.opacity(0.3))
                            .cornerRadius(6)

                        Button(action: commitChanges) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text(stagedFiles.isEmpty ? "Stage & Commit All" : "Commit Staged")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(commitMessage.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                            .foregroundColor(commitMessage.isEmpty ? .secondary : .white)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(commitMessage.isEmpty)
                        .help(stagedFiles.isEmpty ? "Stages all changes and commits" : "Commits only staged changes")
                        .onHover { hovering in
                            if hovering && !commitMessage.isEmpty {
                                NSCursor.pointingHand.push()
                            } else if !hovering {
                                NSCursor.pop()
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            } else if workingDirectoryBookmark == nil {
                // No folder selected
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No Folder Selected")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Select a project folder to view git status")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)

                    Button("Select Folder") {
                        selectDirectory()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 40)
                .padding(.horizontal, 16)
            } else {
                // Folder selected but not a git repo
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Not a Git Repository")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(workingDirectory.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Button(action: {
                        initializeGitRepository()
                    }) {
                        HStack(spacing: 4) {
                            if isInitializingRepo {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(isInitializingRepo ? "Initializing..." : "Initialize Repository")
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .padding(.top, 4)
                    .disabled(isInitializingRepo)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 40)
                .padding(.horizontal, 16)
            }

            Spacer(minLength: 0)
        }
    }

    /// Section header for git file lists
    @ViewBuilder
    private func gitSectionHeader(title: String, count: Int, color: Color) -> some View {
        HStack {
            Text("\(title) (\(count))")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Individual git file row
    @ViewBuilder
    private func gitFileRow(file: GitFileChange, isStaged: Bool) -> some View {
        HStack(spacing: 6) {
            // Stage/unstage button
            Button(action: {
                if isStaged {
                    unstageFile(file.path)
                } else {
                    stageFile(file.path)
                }
            }) {
                Image(systemName: isStaged ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isStaged ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(isStaged ? "Unstage file" : "Stage file")
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }

            Image(systemName: file.status.icon)
                .font(.system(size: 10))
                .foregroundStyle(file.status.color)
                .frame(width: 12)

            Text(file.path)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(file.status.label)
                .font(.system(size: 9))
                .foregroundStyle(file.status.color)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: { revealInFinder(file.url) }) {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Divider()
            if isStaged {
                Button(action: { unstageFile(file.path) }) {
                    Label("Unstage", systemImage: "minus.circle")
                }
            } else {
                Button(action: { stageFile(file.path) }) {
                    Label("Stage", systemImage: "plus.circle")
                }
            }
            if file.status != .untracked {
                Button(action: { discardChanges(file.path) }) {
                    Label("Discard Changes", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    /// Initialize a new git repository with an initial commit on main branch
    func initializeGitRepository() {
        isInitializingRepo = true
        let directory = workingDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Initialize the repository
            let initResult = self.runGitCommand(["init"], in: directory)

            #if DEBUG
            print("Git init result: \(initResult ?? "nil")")
            print("Working directory: \(directory.path)")
            #endif

            guard initResult != nil else {
                DispatchQueue.main.async {
                    self.isInitializingRepo = false
                }
                return
            }

            // Step 2: Configure default branch name to 'main'
            _ = self.runGitCommand(["config", "init.defaultBranch", "main"], in: directory)

            // Step 3: Ensure we're on main branch
            _ = self.runGitCommand(["checkout", "-b", "main"], in: directory)

            // Step 4: Create a .gitignore file if it doesn't exist
            let gitignorePath = directory.appendingPathComponent(".gitignore")
            if !FileManager.default.fileExists(atPath: gitignorePath.path) {
                let defaultGitignore = """
                # macOS
                .DS_Store

                # IDE
                .vscode/
                .idea/

                # Build artifacts
                build/
                dist/
                *.o
                *.exe

                """
                try? defaultGitignore.write(to: gitignorePath, atomically: true, encoding: .utf8)
            }

            // Step 5: Add all files
            _ = self.runGitCommand(["add", "."], in: directory)

            // Step 6: Create initial commit
            let commitResult = self.runGitCommand(["commit", "-m", "Initial commit"], in: directory)

            #if DEBUG
            print("Git commit result: \(commitResult ?? "nil")")
            #endif

            // Step 7: Refresh UI to show the new repository state
            // Get the branch name directly before switching to main thread
            let branch = self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            let status = self.runGitCommand(["status", "--porcelain"], in: directory)

            DispatchQueue.main.async {
                // Update git state directly
                self.gitBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.hasUncommittedChanges = !(status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                self.gitRepositoryPath = directory.path

                // Refresh changed files
                self.refreshGitChanges()

                // Done
                self.isInitializingRepo = false

                #if DEBUG
                print("Repository initialized with main branch")
                print("Current branch: \(self.gitBranch ?? "unknown")")
                #endif
            }
        }
    }

    /// Unstage a file
    func unstageFile(_ path: String) {
        let directory = workingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runGitCommand(["reset", "HEAD", "--", path], in: directory)
            DispatchQueue.main.async {
                self.refreshGitChanges()
            }
        }
    }

    /// Switch to a different branch
    func switchBranch(to branchName: String) {
        let directory = workingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runGitCommand(["checkout", branchName], in: directory)

            #if DEBUG
            print("Branch switch result: \(result ?? "nil")")
            #endif

            DispatchQueue.main.async {
                self.refreshGitStatus()
                self.refreshGitChanges()
            }
        }
    }

    /// Calculate dynamic height for input field based on content
    func calculateInputHeight(for text: String) -> CGFloat {
        let minHeight: CGFloat = 24
        let maxHeight: CGFloat = 200
        let lineHeight: CGFloat = 20

        // Count lines in the text
        let lines = text.components(separatedBy: .newlines).count
        let calculatedHeight = CGFloat(lines) * lineHeight + 8 // 8px padding

        // Clamp between min and max
        return min(max(calculatedHeight, minHeight), maxHeight)
    }

    // MARK: - Logic

    /// Opens the main pane on an empty draft thread for the current project.
    func beginEmptyAgentSession() {
        orchestrator.store.ensureDefaultWorkspace(projectPath: workingDirectory)
        orchestrator.store.pruneDuplicateEmptyThreads()
        createNewChat(forceNew: false)
    }

    func createNewChat(forceNew: Bool = false) {
        persistCurrentThread()

        orchestrator.store.ensureDefaultWorkspace(projectPath: workingDirectory)

        if !forceNew,
           let project = orchestrator.store.selectedProject,
           let emptyThread = project.threads.first(where: {
               $0.messages.isEmpty && ($0.title == "New Chat" || $0.title == "New Thread")
           }) {
            switchChat(to: emptyThread.id)
            return
        }

        let thread = orchestrator.store.createThread()
        let newSession = thread.asChatSession
        sessions.insert(newSession, at: 0)
        currentSessionId = newSession.id
        messages = []
        isShowingConsole = false // Exit console when creating new chat
        
        // Reset context window counters for new session
        totalTokens = 0
        sessionCost = 0.0
        contextUsage = 0.0
        lastInputTokens = 0
        lastOutputTokens = 0
        currentModelUsed = nil
        
        PersistenceController.shared.save(sessions: sessions) // Persist immediately
        prewarmAgentIfNeeded()
    }

    func persistCurrentThread() {
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx].messages = messages
            sessions[idx].lastModified = Date()
            if let firstUser = messages.first(where: { $0.role == "user" }) {
                let title = String(firstUser.content.prefix(40))
                if !title.isEmpty, sessions[idx].title == "New Chat" || sessions[idx].title == "New Thread" {
                    sessions[idx].title = title
                }
            }
        }
        PersistenceController.shared.save(sessions: sessions)

        if var thread = orchestrator.store.allThreadsFlat().first(where: { $0.id == currentSessionId }) {
            thread.messages = messages
            thread.lastModified = Date()
            if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
                thread.title = sessions[idx].title
            }
            orchestrator.store.updateThread(thread)
        }
    }
    
    /// Ensures the current session exists in the sidebar. Called when user starts typing.
    func ensureCurrentChatExists() {
        // If the current session ID isn't in our sessions list, we're in a phantom chat
        if sessions.first(where: { $0.id == currentSessionId }) == nil {
            // Create a new session with the current ID
            let newSession = ChatSession(id: currentSessionId, title: "New Chat", messages: messages, lastModified: Date())
            sessions.insert(newSession, at: 0)
            PersistenceController.shared.save(sessions: sessions)
        }
    }
    
    func switchChat(to id: UUID) {
        persistCurrentThread()
        orchestrator.store.select(threadId: id)
        
        // Load new
        if let thread = orchestrator.store.allThreadsFlat().first(where: { $0.id == id }) {
            currentSessionId = id
            messages = thread.messages
        } else if let session = sessions.first(where: { $0.id == id }) {
            currentSessionId = id
            messages = session.messages
        } else {
            return
        }
        isShowingConsole = false // Exit console when switching chats
        
        // Reset context window counters for new session
        totalTokens = 0
        sessionCost = 0.0
        contextUsage = 0.0
        lastInputTokens = 0
        lastOutputTokens = 0
        currentModelUsed = nil
        prewarmAgentIfNeeded()
    }
    
    func prewarmAgentIfNeeded() {
        guard grokBuildMode != .chat else {
            orchestrator.stop()
            return
        }
        _ = workingDirectory.startAccessingSecurityScopedResource()
        let projectPath = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let acpModel = ModelRegistry.resolveACPModel(selected: selectedModel, availableModels: availableModels)
        if !orchestrator.hasWarmSession(
            threadId: currentSessionId,
            projectPath: projectPath,
            mode: grokBuildMode,
            model: acpModel
        ) {
            orchestrator.warmSession(
                projectPath: projectPath,
                mode: grokBuildMode,
                threadId: currentSessionId,
                model: acpModel
            )
        }
    }

    private var activityStatusLabel: String {
        let base = requestStatus.isEmpty ? "Working…" : requestStatus
        guard let start = requestStartTime else { return base }
        let elapsed = Int(Date().timeIntervalSince(start))
        if elapsed >= 45 {
            return "\(base) · \(elapsed)s · tap Stop if stuck"
        }
        if elapsed >= 3 {
            return "\(base) · \(elapsed)s"
        }
        return base
    }

    private func statusText(for message: ChatMessage) -> String {
        guard isSending, message.id == activeAssistantMessageId else { return "" }
        return activityStatusLabel
    }

    private func appendAgentActivity(
        to messageId: UUID,
        icon: String,
        title: String,
        detail: String? = nil,
        inProgress: Bool = true
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        if let last = messages[idx].activityLines.last,
           last.title == title,
           last.detail == detail,
           last.isInProgress == inProgress {
            return
        }
        if inProgress, var last = messages[idx].activityLines.last, last.isInProgress {
            last.isInProgress = false
            messages[idx].activityLines[messages[idx].activityLines.count - 1] = last
        }
        messages[idx].activityLines.append(
            AgentActivityLine(icon: icon, title: title, detail: detail, isInProgress: inProgress)
        )
        requestStatus = title
    }

    private func completeAgentActivity(for messageId: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[idx].activityLines.removeAll { $0.isTransient }
        guard !messages[idx].activityLines.isEmpty else { return }
        var last = messages[idx].activityLines[messages[idx].activityLines.count - 1]
        if last.isInProgress {
            last.isInProgress = false
            messages[idx].activityLines[messages[idx].activityLines.count - 1] = last
        }
    }
    
    func deleteChat(_ session: ChatSession) {
        orchestrator.store.deleteThread(session.id)
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions.remove(at: idx)
            PersistenceController.shared.save(sessions: sessions)
            
            // If we deleted the active chat, switch to another or create new
            if session.id == currentSessionId {
                if let first = sessions.first {
                    switchChat(to: first.id)
                } else {
                    createNewChat()
                }
            }
        }
    }
    
    func renameChat(_ session: ChatSession, newTitle: String) {
        orchestrator.store.renameThread(session.id, title: newTitle)
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].title = newTitle
            PersistenceController.shared.save(sessions: sessions)
        }
    }
    
    func refreshFileList() {
        guard hasProjectFolder else {
            fileTree = []
            return
        }
        
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: workingDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            fileTree = urls
                .filter { url in
                    let name = url.lastPathComponent
                    if name.hasPrefix("augment-zsh-") { return false }
                    if name.hasPrefix(".") { return false }
                    return true
                }
                .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileSystemItem(name: url.lastPathComponent, url: url, isDirectory: isDir, children: nil)
            }.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            #if DEBUG
            print("Failed to list directory: \(error)")
            #endif
            fileTree = []
        }
    }

    // MARK: - File System Monitoring

    /// Start monitoring the working directory for file system changes
    func startFileSystemMonitoring() {
        // Stop any existing monitor first
        stopFileSystemMonitoring()

        guard hasProjectFolder else { return }

        // Open file descriptor for the directory
        let path = workingDirectory.path
        let fileDescriptor = open(path, O_EVTONLY)

        guard fileDescriptor >= 0 else {
            #if DEBUG
            print("Failed to open directory for monitoring: \(path)")
            #endif
            return
        }

        monitoredFileDescriptor = fileDescriptor

        // Create dispatch source to monitor file system events
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.main
        )

        source.setEventHandler {
            // Debounce rapid changes (wait 500ms before refreshing)
            self.refreshDebounceTimer?.invalidate()
            self.refreshDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                self.refreshFileList()
            }
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileSystemMonitor = source

        #if DEBUG
        print("Started file system monitoring for: \(path)")
        #endif
    }

    /// Stop monitoring the file system
    func stopFileSystemMonitoring() {
        refreshDebounceTimer?.invalidate()
        refreshDebounceTimer = nil

        fileSystemMonitor?.cancel()
        fileSystemMonitor = nil

        if let fd = monitoredFileDescriptor {
            close(fd)
            monitoredFileDescriptor = nil

            #if DEBUG
            print("Stopped file system monitoring")
            #endif
        }
    }

    /// Refresh git repository status for current working directory
    func refreshGitStatus() {
        guard workingDirectoryBookmark != nil else {
            gitBranch = nil
            hasUncommittedChanges = false
            gitRepositoryPath = nil
            return
        }

        let directory = workingDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            let repoRoot = self.runGitCommand(["rev-parse", "--show-toplevel"], in: directory)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let workingPath = directory.path

            let isRepoRoot = (repoRoot == workingPath)

            if isRepoRoot {
                let branch = self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
                let status = self.runGitCommand(["status", "--porcelain"], in: directory)
                let branchList = self.runGitCommand(["branch", "--format=%(refname:short)"], in: directory)

                DispatchQueue.main.async {
                    self.gitBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.hasUncommittedChanges = !(status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    self.gitRepositoryPath = repoRoot

                    if let branches = branchList {
                        self.gitBranches = branches
                            .split(separator: "\n")
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    } else {
                        self.gitBranches = []
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.gitBranch = nil
                    self.gitBranches = []
                    self.hasUncommittedChanges = false
                    self.gitRepositoryPath = nil
                }
            }
        }
    }

    /// Run a git command in the given directory (safe for background queues).
    private func runGitCommand(_ arguments: [String], in directory: URL) -> String? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            #if DEBUG
            print("Git command failed to launch: \(error)")
            #endif
            return nil
        }

        pipe.fileHandleForWriting.closeFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            try? pipe.fileHandleForReading.close()
            return nil
        }

        let handle = pipe.fileHandleForReading
        var output = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        try? handle.close()

        guard !output.isEmpty else { return "" }
        return String(data: output, encoding: .utf8)
    }

    /// Refresh the list of changed files in git
    func refreshGitChanges() {
        guard workingDirectoryBookmark != nil, gitBranch != nil else {
            gitChangedFiles = []
            return
        }

        let directory = workingDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            guard let status = self.runGitCommand(["status", "--porcelain"], in: directory) else {
                DispatchQueue.main.async {
                    self.gitChangedFiles = []
                }
                return
            }

            #if DEBUG
            print("Git status output: '\(status)'")
            print("Status is empty: \(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
            #endif

            // Git porcelain format: XY filename
            // X = status in index (staged), Y = status in work tree (unstaged)
            // Space means no change in that area
            let changes = status.split(separator: "\n").compactMap { line -> GitFileChange? in
                let lineStr = String(line)
                guard lineStr.count >= 3 else { return nil }

                // Parse the two-character status code
                let indexStatus = lineStr.prefix(1)  // Staged status
                let workTreeStatus = String(lineStr.dropFirst(1).prefix(1))  // Unstaged status
                let filePath = String(lineStr.dropFirst(3))

                // Skip files that start with dot-directories that aren't in the repo
                // (e.g., .aws/, .anthropic/ which are system dirs, not repo dirs)
                if filePath.hasPrefix(".") && !filePath.hasPrefix(".github") &&
                   !filePath.hasPrefix(".gitignore") && !filePath.hasPrefix(".gitattributes") {
                    // Check if this looks like a system dotfile/folder (common patterns)
                    let systemDotFiles = [".aws", ".anthropic", ".adobe", ".bash", ".bun",
                                          ".cache", ".cargo", ".chatgpt", ".claude", ".config",
                                          ".CFUser", ".npm", ".ssh", ".zsh"]
                    for prefix in systemDotFiles {
                        if filePath.hasPrefix(prefix) { return nil }
                    }
                }

                // Determine if file is staged (has changes in index)
                let isStaged = indexStatus != " " && indexStatus != "?"

                // Determine the primary status to show
                let gitStatus: GitFileChange.GitStatus
                let statusToCheck = isStaged ? String(indexStatus) : workTreeStatus

                switch statusToCheck {
                case "M": gitStatus = .modified
                case "A": gitStatus = .added
                case "D": gitStatus = .deleted
                case "R": gitStatus = .renamed
                case "?": gitStatus = .untracked
                default: gitStatus = .modified
                }

                let url = directory.appendingPathComponent(filePath)
                return GitFileChange(path: filePath, status: gitStatus, url: url, isStaged: isStaged)
            }

            DispatchQueue.main.async {
                self.gitChangedFiles = changes

                #if DEBUG
                print("Updated gitChangedFiles: \(changes.count) files")
                for change in changes {
                    print("  - \(change.path) [\(change.status.rawValue)] staged: \(change.isStaged)")
                }
                #endif
            }
        }
    }

    /// Stage a file for commit
    func stageFile(_ path: String) {
        let directory = workingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runGitCommand(["add", path], in: directory)
            DispatchQueue.main.async {
                self.refreshGitChanges()
            }
        }
    }

    /// Discard changes to a file
    func discardChanges(_ path: String) {
        let directory = workingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runGitCommand(["checkout", "--", path], in: directory)
            DispatchQueue.main.async {
                self.refreshGitChanges()
                self.refreshGitStatus()
            }
        }
    }

    /// Commit staged changes (or stage all first if nothing is staged)
    func commitChanges() {
        guard !commitMessage.isEmpty else { return }

        let message = commitMessage
        let needsStageAll = stagedFiles.isEmpty
        let directory = workingDirectory
        commitMessage = "" // Clear immediately for UX

        DispatchQueue.global(qos: .userInitiated).async {
            if needsStageAll {
                _ = self.runGitCommand(["add", "-A"], in: directory)
            }
            let commitResult = self.runGitCommand(["commit", "-m", message], in: directory)

            #if DEBUG
            print("Commit result: \(commitResult ?? "nil")")
            #endif

            let status = self.runGitCommand(["status", "--porcelain"], in: directory)
            let branch = self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            let branchList = self.runGitCommand(["branch", "--format=%(refname:short)"], in: directory)

            // Update UI on main thread
            DispatchQueue.main.async {
                // Update git status
                self.gitBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.hasUncommittedChanges = !(status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                // Parse branch list
                if let branches = branchList {
                    self.gitBranches = branches
                        .split(separator: "\n")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }

                // Refresh changed files list
                self.refreshGitChanges()

                #if DEBUG
                print("Git status refreshed after commit")
                print("Has uncommitted changes: \(self.hasUncommittedChanges)")
                print("Changed files count: \(self.gitChangedFiles.count)")
                #endif
            }
        }
    }

    @ViewBuilder
    func FileRow(item: FileSystemItem, depth: Int) -> some View {
        Button(action: {
            if !item.isDirectory {
                loadFileContent(item.url)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDirectory ? Color.blue : Color.secondary)
                    .frame(width: 12)
                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(depth * 10) + 8)
        .padding(.trailing, 12)
    }

    /// File row with enhanced context menu for native macOS actions - hierarchical tree view
    @ViewBuilder
    func FileRowWithContextMenu(item: FileSystemItem, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row content - use Button instead of onTapGesture for better responsiveness
            Button(action: {
                if item.isDirectory {
                    // Toggle expand/collapse
                    toggleFolderExpanded(item)
                } else {
                    loadFileContent(item.url)
                }
            }) {
                HStack(spacing: 4) {
                    // Disclosure triangle for directories
                    if item.isDirectory {
                        Image(systemName: expandedFileIds.contains(item.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    } else {
                        // Spacer for alignment with files
                        Color.clear.frame(width: 12, height: 12)
                    }

                    Image(systemName: fileIcon(for: item))
                        .font(.system(size: 12))
                        .foregroundStyle(item.isDirectory ? Color.blue : fileIconColor(for: item.name))
                        .frame(width: 14)
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 5)
                .padding(.leading, CGFloat(depth * 16) + 4)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
            .contextMenu {
                // Add to Chat
                Button(action: { loadFileContent(item.url) }) {
                    Label("Add to Chat", systemImage: "bubble.left.and.text.bubble.right")
                }
                .disabled(item.isDirectory)

                Divider()

                // Reveal in Finder
                Button(action: { revealInFinder(item.url) }) {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                // Open with Default App
                Button(action: { openWithDefaultApp(item.url) }) {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }

                // Open in Terminal (for directories)
                if item.isDirectory {
                    Button(action: { openInTerminal(item.url) }) {
                        Label("Open in Terminal", systemImage: "terminal")
                    }
                }

                Divider()

                // Copy Path
                Button(action: { copyPath(item.url) }) {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }

                // Copy Relative Path
                Button(action: { copyRelativePath(item.url) }) {
                    Label("Copy Relative Path", systemImage: "doc.on.doc.fill")
                }

                Divider()

                // Quick Look Preview
                Button(action: { quickLookPreview(item.url) }) {
                    Label("Quick Look", systemImage: "eye")
                }
                .disabled(item.isDirectory)
            }

            // Render children if expanded
            if item.isDirectory && expandedFileIds.contains(item.id) {
                if let children = item.children {
                    ForEach(children) { child in
                        AnyView(FileRowWithContextMenu(item: child, depth: depth + 1))
                    }
                } else {
                    // Loading indicator
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Loading...")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat((depth + 1) * 16) + 20)
                    .padding(.vertical, 4)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: expandedFileIds)
    }

    // MARK: - File Context Menu Actions

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func openWithDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openInTerminal(_ url: URL) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(url.path)'"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func copyRelativePath(_ url: URL) {
        let relativePath = url.path.replacingOccurrences(of: workingDirectory.path + "/", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativePath, forType: .string)
    }

    func quickLookPreview(_ url: URL) {
        // Use QLPreviewPanel for Quick Look
        NSWorkspace.shared.open(url)
    }

    /// Toggle folder expanded state and load children if needed
    func toggleFolderExpanded(_ item: FileSystemItem) {
        if expandedFileIds.contains(item.id) {
            // Collapse: just remove from expanded set
            expandedFileIds.remove(item.id)
        } else {
            // Expand: add to expanded set and load children if not already loaded
            expandedFileIds.insert(item.id)
            loadChildrenIfNeeded(for: item)
        }
    }

    /// Load children for a folder item if not already loaded
    func loadChildrenIfNeeded(for item: FileSystemItem) {
        // Check if children already loaded in the tree
        if findItem(by: item.id, in: fileTree)?.children != nil {
            return
        }

        // Load children from filesystem
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: item.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let children = urls.map { fileUrl in
                let isDir = (try? fileUrl.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileSystemItem(name: fileUrl.lastPathComponent, url: fileUrl, isDirectory: isDir, children: nil)
            }.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

            // Update the tree with loaded children
            fileTree = updateChildren(for: item.id, with: children, in: fileTree)
        } catch {
            #if DEBUG
            print("Failed to load directory children: \(error)")
            #endif
        }
    }

    /// Find an item by ID in the tree
    func findItem(by id: UUID, in items: [FileSystemItem]) -> FileSystemItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children, let found = findItem(by: id, in: children) {
                return found
            }
        }
        return nil
    }

    /// Update children for an item in the tree (returns new tree)
    func updateChildren(for id: UUID, with children: [FileSystemItem], in items: [FileSystemItem]) -> [FileSystemItem] {
        return items.map { item in
            if item.id == id {
                var updated = item
                updated.children = children
                return updated
            } else if let existingChildren = item.children {
                var updated = item
                updated.children = updateChildren(for: id, with: children, in: existingChildren)
                return updated
            }
            return item
        }
    }

    /// Returns appropriate SF Symbol for file type
    func fileIcon(for item: FileSystemItem) -> String {
        if item.isDirectory { return "folder.fill" }

        let ext = item.url.pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts", "jsx", "tsx": return "doc.text"
        case "html", "htm": return "globe"
        case "css", "scss", "sass": return "paintbrush"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "pdf": return "doc.fill"
        case "zip", "tar", "gz", "rar": return "archivebox"
        case "mp3", "wav", "aac", "m4a": return "music.note"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "xcodeproj", "xcworkspace": return "hammer"
        case "plist": return "list.bullet.rectangle"
        default: return "doc"
        }
    }

    /// Returns color for file type
    func fileIconColor(for name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "py": return .blue
        case "js", "ts": return .yellow
        case "jsx", "tsx": return .cyan
        case "html": return .red
        case "css", "scss": return .purple
        case "json": return .green
        case "md": return .gray
        default: return .secondary
        }
    }
    
    func loadFileContent(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let attachment = "\n\nFile: \(url.lastPathComponent)\n```\n\(content)\n```\n"
            if inputMessage.isEmpty {
                inputMessage = "Analyze this file:\n" + attachment
            } else {
                inputMessage += attachment
            }
        } catch {
            #if DEBUG
            print("Failed to read file: \(error)")
            #endif
        }
    }
    
    func generateSessionTitle() {
        authTokenForRequest { token in
            guard let token, !token.isEmpty,
                  let url = URL(string: "https://api.x.ai/v1/chat/completions") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let history = messages.prefix(4).map { ["role": $0.role, "content": $0.content] }
        
        let body: [String: Any] = [
            "messages": history + [["role": "user", "content": "Generate a very short 3-5 word title for this conversation. Return ONLY the title text, no quotes."]],
            "model": selectedModel,
            "stream": false
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { return }
            struct ChatResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String? }
                    let message: Message
                }
                let choices: [Choice]
            }
            if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
               let title = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") {
                   DispatchQueue.main.async {
                       if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
                           sessions[idx].title = title
                           PersistenceController.shared.save(sessions: sessions)
                       }
                   }
            }
        }.resume()
        }
    }
    
    // MARK: - Actions
    
    func pasteImage() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) {
            inputImage = data
        } else if let data = pasteboard.data(forType: .tiff) {
             if let bitmap = NSBitmapImageRep(data: data),
                let pngData = bitmap.representation(using: .png, properties: [:]) {
                 inputImage = pngData
             }
        }
    }
    
    func takeScreenshot() {
        // Check if Screen Recording permission is granted
        // Note: This will still prompt once if not granted, but won't keep prompting
        let hasPermission = CGPreflightScreenCaptureAccess()
        
        if !hasPermission {
            // Request permission (will show system dialog)
            CGRequestScreenCaptureAccess()
            
            // Show user-friendly message
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Screen Recording Permission Needed"
                alert.informativeText = """
                To use "Take Screenshot", please:
                
                1. Open System Settings
                2. Go to Privacy & Security > Screen Recording
                3. Enable "Grok"
                4. Restart the app if needed
                
                Alternative: Use Cmd+Shift+4 to take a screenshot, then paste with Cmd+V or the "Paste from Clipboard" button.
                """
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }
        
        // Permission granted - proceed with screenshot
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-ic"] // -i for interactive, -c for clipboard
        
        // Run on background thread to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try task.run()
                task.waitUntilExit()
                
                // After completion, check clipboard on main thread
                DispatchQueue.main.async {
                    let pasteboard = NSPasteboard.general
                    if let data = pasteboard.data(forType: .png) {
                        self.inputImage = data
                    } else if let data = pasteboard.data(forType: .tiff) {
                        if let bitmap = NSBitmapImageRep(data: data),
                           let pngData = bitmap.representation(using: .png, properties: [:]) {
                            self.inputImage = pngData
                        }
                    }
                }
            } catch {
                #if DEBUG
                print("Screenshot failed: \(error)")
                #endif
            }
        }
    }
    
    func startNewAgent() {
        openProjectFolderViaPanel(startNewAgent: true)
    }

    func openProjectFolderViaPanel(startNewAgent: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = startNewAgent
            ? "Choose a folder for this agent. Grok Build will use it as the working directory."
            : "Select a project folder for Grok Build."
        panel.prompt = startNewAgent ? "Select Folder" : "Open"

        if panel.runModal() == .OK, let url = panel.url {
            openProjectFolder(url, startNewAgent: startNewAgent)
        }
    }

    func openProjectFolder(_ url: URL, startNewAgent: Bool) {
        guard Self.isUsableProjectDirectory(url) else { return }
        _ = url.startAccessingSecurityScopedResource()
        saveBookmark(for: url)
        workingDirectory = url
        refreshFileList()
        startFileSystemMonitoring()

        let project = orchestrator.store.ensureDefaultWorkspace(projectPath: url)
        orchestrator.store.select(projectId: project.id)
        orchestrator.store.pruneDuplicateEmptyThreads()

        sessions = orchestrator.store.allThreadsFlat().map { $0.asChatSession }

        if startNewAgent {
            createNewChat(forceNew: true)
        } else {
            beginEmptyAgentSession()
        }

        prewarmAgentIfNeeded()
        refreshGitStatus()
    }

    func activateProject(_ project: AgentProject) {
        let normalizedCurrent = workingDirectory.standardizedFileURL.path
        let normalizedProject = project.url.standardizedFileURL.path

        orchestrator.store.select(projectId: project.id)

        if normalizedCurrent != normalizedProject {
            openProjectFolder(project.url, startNewAgent: false)
            return
        }

        sessions = orchestrator.store.allThreadsFlat().map { $0.asChatSession }
        beginEmptyAgentSession()
    }

    func activateThread(_ thread: AgentThread, project: AgentProject) {
        let normalizedCurrent = workingDirectory.standardizedFileURL.path
        let normalizedProject = project.url.standardizedFileURL.path

        orchestrator.store.select(projectId: project.id)
        orchestrator.store.select(threadId: thread.id)
        orchestrator.store.setThreadUnread(thread.id, unread: false)

        if normalizedCurrent != normalizedProject {
            openProjectFolder(project.url, startNewAgent: false)
        }

        switchChat(to: thread.id)
    }

    func selectDirectory() {
        openProjectFolderViaPanel(startNewAgent: false)
    }

    func openSettings() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showSettings(nil)
        }
    }
    
    // MARK: - Security Scoped Bookmarks
    func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            workingDirectoryBookmark = data
        } catch {
            #if DEBUG
            print("Failed to save bookmark: \(error)")
            #endif
        }
    }
    
    func restoreDirectoryAccess() {
        guard let data = workingDirectoryBookmark else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                saveBookmark(for: url)
            }
            guard Self.isUsableProjectDirectory(url) else {
                workingDirectoryBookmark = nil
                fileTree = []
                stopFileSystemMonitoring()
                return
            }
            if url.startAccessingSecurityScopedResource() {
                workingDirectory = url
                startFileSystemMonitoring()
                let project = orchestrator.store.ensureDefaultWorkspace(projectPath: url)
                orchestrator.store.select(projectId: project.id)
            } else {
                #if DEBUG
                print("Failed to access security scoped resource")
                #endif
            }
        } catch {
            #if DEBUG
            print("Failed to resolve bookmark: \(error)")
            #endif
        }
    }
    func resetToHome() {
        messages.removeAll()
        errorMessage = nil
    }
    
    func fetchModels() {
        isLoadingModels = true
        errorMessage = nil
        
        authTokenForRequest { token in
            guard let token, !token.isEmpty else {
                DispatchQueue.main.async {
                    self.isLoadingModels = false
                    self.errorMessage = "Sign in with Grok Build or add an API key in Settings."
                }
                return
            }
            
            guard let url = URL(string: "https://api.x.ai/v1/models") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoadingModels = false
                
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                
                guard let data = data else {
                    self.errorMessage = "No data"
                    return
                }
                
                 if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    self.errorMessage = "Error: \(httpResponse.statusCode)"
                    return
                }
                
                do {
                    let decoded = try JSONDecoder().decode(ModelResponse.self, from: data)
                    self.availableModels = ModelRegistry.sortedDisplayModels(decoded.data.map { $0.id })

                    // Debug: Log available models
                    #if DEBUG
                    print("📋 Available models from API (\(self.availableModels.count)):")
                    for model in self.availableModels {
                        print("   • \(model)")
                    }
                    #endif

                    // Cache context window limits from API (if provided)
                    for model in decoded.data {
                        if let contextLength = model.context_length {
                            ModelRegistry.modelContextLimits[model.id] = contextLength
                        }
                    }

                    // Keep 'auto' if selected, otherwise fallback check
                    if self.selectedModel != "auto" && !self.availableModels.contains(self.selectedModel) {
                        #if DEBUG
                        print("⚠️ Selected model '\(self.selectedModel)' not available, switching to auto")
                        #endif
                        self.selectedModel = "auto"
                    }
                } catch {
                     // Silent fail or simple message
                     self.errorMessage = "Failed to parse"
                     #if DEBUG
                     print("❌ Failed to parse models response: \(error)")
                     #endif
                }
            }
        }.resume()
        }
    }

    func sendMessage() {
        guard !inputMessage.isEmpty && !isSending else { return }

        let userMsg = inputMessage
        inputMessage = ""
        inputHeight = 24 // Reset to minimum height
        isSending = true
        requestStartTime = Date()

        // 1. Add User Message
        let newUserMsg = ChatMessage(role: "user", content: userMsg, isThinking: false, imageData: inputImage)
        messages.append(newUserMsg)

        // Note: We do NOT overwrite 'selectedModel' here anymore.
        // We let performAPICall resolve it dynamically.

        inputImage = nil

        // 2. Add Placeholder Assistant Message
        let assistantMsgId = UUID()
        activeAssistantMessageId = assistantMsgId
        messages.append(ChatMessage(id: assistantMsgId, role: "assistant", content: "", isThinking: true))

        // 3. Resolve Model (Smart Selection) - Check the user message's imageData, not inputImage (already cleared)
        // Pass availableModels and messageText to ensure smart model selection based on task type
        let modelToUse = ModelRegistry.resolveAPIModel(
            selected: selectedModel,
            hasImage: newUserMsg.imageData != nil,
            textLength: userMsg.count,
            messageText: userMsg,
            availableModels: availableModels,
            useGrokBuildOAuth: grokBuildAuth.isUsingGrokBuildSession
        )

        // Set initial status
        requestStatus = "Connecting..."

        authTokenForRequest { token in
            guard let token, !token.isEmpty else {
                self.isSending = false
                self.requestStatus = ""
                self.requestStartTime = nil
                self.activeAssistantMessageId = nil
                if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                    self.messages[idx].content = "❌ Not authenticated. Sign in with Grok Build (`grok login`) or add an API key in Settings."
                    self.messages[idx].isThinking = false
                }
                return
            }

            if self.orchestrator.shouldUseACP(
                auth: self.grokBuildAuth,
                threadId: self.currentSessionId,
                projectPath: self.workingDirectory,
                mode: self.grokBuildMode,
                text: userMsg,
                model: ModelRegistry.resolveACPModel(selected: self.selectedModel, availableModels: self.availableModels)
            ) {
                self.performACPPrompt(assistantMsgId: assistantMsgId, userText: userMsg, modelID: modelToUse, authToken: token)
                return
            }

            self.performAPICall(assistantMsgId: assistantMsgId, modelID: modelToUse, authToken: token)
        }
    }

    /// Route prompt through official `grok agent stdio` ACP adapter.
    func performACPPrompt(assistantMsgId: UUID, userText: String, modelID: String, authToken: String) {
        _ = workingDirectory.startAccessingSecurityScopedResource()
        let projectPath = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let acpModel = ModelRegistry.resolveACPModel(selected: selectedModel, availableModels: availableModels)
        requestStatus = orchestrator.hasWarmSession(
            threadId: currentSessionId,
            projectPath: projectPath,
            mode: grokBuildMode,
            model: acpModel
        ) ? "Grok CLI…" : "Starting Grok CLI…"

        orchestrator.sendPrompt(
            text: userText,
            threadId: currentSessionId,
            projectPath: projectPath,
            mode: grokBuildMode,
            model: acpModel,
            assistantMessageId: assistantMsgId,
            onUpdate: { _, update in
                update(&self.messages)
            },
            onComplete: {
                self.completeAgentActivity(for: assistantMsgId)
                self.isSending = false
                self.requestStatus = ""
                self.requestStartTime = nil
                self.activeAssistantMessageId = nil
                self.persistCurrentThread()
            },
            onStatusChange: { status in
                self.requestStatus = status
            },
            onFailure: {
                self.performAgentFallback(
                    assistantMsgId: assistantMsgId,
                    userText: userText,
                    modelID: modelID,
                    authToken: authToken
                )
            }
        )
    }

    /// When Grok CLI fails, try local tools for simple ops, then REST API.
    func performAgentFallback(assistantMsgId: UUID, userText: String, modelID: String, authToken: String) {
        if ModelRegistry.messageAsksForDirectoryListing(userText) {
            performLocalDirectoryListing(assistantMsgId: assistantMsgId)
            return
        }
        if grokBuildMode != .chat, let folderName = ModelRegistry.parseCreateFolderRequest(userText) {
            performLocalCreateFolder(assistantMsgId: assistantMsgId, folderName: folderName)
            return
        }
        if let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) {
            messages[idx].content = ""
            messages[idx].isThinking = true
        }
        isSending = true
        requestStatus = "API fallback…"
        performAPICall(assistantMsgId: assistantMsgId, modelID: modelID, authToken: authToken)
    }

    /// Lists the workspace folder locally — no API or ACP required.
    func performLocalDirectoryListing(assistantMsgId: UUID) {
        _ = workingDirectory.startAccessingSecurityScopedResource()
        let folderURL = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        requestStatus = "Listing folder…"
        appendAgentActivity(to: assistantMsgId, icon: "folder", title: "Listing folder", detail: folderURL.lastPathComponent)

        DispatchQueue.global(qos: .userInitiated).async {
            let output: String
            if !FileManager.default.fileExists(atPath: folderURL.path) {
                output = "❌ Folder not found:\n\(folderURL.path)"
            } else {
                do {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: folderURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                        options: [.skipsHiddenFiles]
                    )
                    let sorted = contents.sorted {
                        $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
                    }
                    var lines = ["**\(folderURL.lastPathComponent)**", ""]
                    lines.append("Path: `\(folderURL.path)`")
                    lines.append("")
                    if sorted.isEmpty {
                        lines.append("_(empty folder)_")
                    } else {
                        for item in sorted {
                            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                            lines.append(isDir ? "📁 \(item.lastPathComponent)/" : "📄 \(item.lastPathComponent)")
                        }
                    }
                    output = lines.joined(separator: "\n")
                } catch {
                    output = "❌ Could not list folder: \(error.localizedDescription)"
                }
            }

            DispatchQueue.main.async {
                guard let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) else {
                    self.isSending = false
                    self.requestStatus = ""
                    self.requestStartTime = nil
                    self.activeAssistantMessageId = nil
                    return
                }
                self.messages[idx].content = output
                self.messages[idx].isThinking = false
                self.messages[idx].usedModel = nil
                self.completeAgentActivity(for: assistantMsgId)
                self.isSending = false
                self.requestStatus = ""
                self.requestStartTime = nil
                self.activeAssistantMessageId = nil
                self.persistCurrentThread()
            }
        }
    }

    /// Creates a folder in the workspace locally — instant, no API/ACP required.
    func performLocalCreateFolder(assistantMsgId: UUID, folderName: String) {
        _ = workingDirectory.startAccessingSecurityScopedResource()
        requestStatus = "Creating folder…"
        appendAgentActivity(to: assistantMsgId, icon: "folder.badge.plus", title: "Creating folder", detail: folderName)

        if grokBuildMode == .agent {
            guard let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) else {
                isSending = false
                requestStatus = ""
                requestStartTime = nil
                activeAssistantMessageId = nil
                return
            }
            messages[idx].content = "Create folder **\(folderName)** in this workspace?"
            messages[idx].pendingToolAction = .createDirectory(folderName)
            messages[idx].isThinking = false
            completeAgentActivity(for: assistantMsgId)
            isSending = false
            requestStatus = "Waiting for approval..."
            requestStartTime = nil
            activeAssistantMessageId = nil
            persistCurrentThread()
            return
        }

        executeToolActionAsync(.createDirectory(folderName)) { [self] output in
            guard let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) else {
                isSending = false
                requestStatus = ""
                requestStartTime = nil
                activeAssistantMessageId = nil
                return
            }
            let succeeded = output.hasPrefix("Created directory:")
            messages[idx].content = succeeded
                ? "Created folder **\(folderName)**."
                : output
            messages[idx].toolAction = "Create folder \(folderName)"
            messages[idx].toolOutput = output
            messages[idx].isThinking = false
            completeAgentActivity(for: assistantMsgId)
            appendAgentActivity(
                to: assistantMsgId,
                icon: succeeded ? "checkmark.circle" : "xmark.circle",
                title: succeeded ? "Folder created" : "Could not create folder",
                detail: folderName,
                inProgress: false
            )
            isSending = false
            requestStatus = ""
            requestStartTime = nil
            activeAssistantMessageId = nil
            persistCurrentThread()
        }
    }
    
    func stopGeneration() {
        if orchestrator.isACPActive {
            orchestrator.stop()
        }
        currentRequestId = nil  // Invalidate current request
        isSending = false
        requestStatus = ""
        requestStartTime = nil
        activeAssistantMessageId = nil

        // Remove thinking message if present
        if let lastMsg = messages.last, lastMsg.isThinking {
            messages.removeLast()
        }
    }
    
    func performAPICall(assistantMsgId: UUID, modelID: String, authToken: String) {
        activeAssistantMessageId = assistantMsgId
        // Capture session ID at start to prevent race condition
        let sessionIdAtStart = self.currentSessionId

        // Create unique request ID for cancellation tracking
        let requestId = UUID()
        self.currentRequestId = requestId

        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120 // 2 minute timeout for API calls
        
        // Map messages
        var apiMessages: [[String: Any]] = messages.filter { !$0.isThinking && $0.id != assistantMsgId }.map { msg in
            if let imgData = msg.imageData {
                let base64 = imgData.base64EncodedString()
                let content: [[String: Any]] = [
                    ["type": "text", "text": msg.content],
                    [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/png;base64,\(base64)",
                            "detail": "high"
                        ]
                    ]
                ]
                return ["role": msg.role, "content": content]
            } else {
                return ["role": msg.role, "content": msg.content]
            }
        }
        
        // System Prompt with Tool Definition (Grok Build Agent)
        let registry = GrokBuildToolRegistry.shared
        let mode = grokBuildMode
        
        var modeInstruction = ""
        switch mode {
        case .chat:
            modeInstruction = """
            You are in **CHAT MODE**.
            - Answer questions and explore the project with read-only tools (list_directory, read_file, get_working_directory).
            - **Do NOT execute** writes, mkdir, run_command, or destructive shell commands.
            - If the user wants changes made, suggest switching to Agent mode.
            """
        case .agent:
            modeInstruction = """
            You are in **AGENT MODE** (human-in-the-loop).
            - You can propose tool calls.
            - The user will review and approve each action before it runs.
            - Be careful with destructive operations.
            """
        case .agentAuto:
            modeInstruction = """
            You are in **AGENT (AUTO) MODE**.
            - You have full autonomy.
            - Execute tool calls as needed to complete the user's request.
            - Still respect the Safety Mode setting.
            """
        }
        
        let toolsInstruction = """
        You are Grok Build, an expert developer agent running inside the macOS Grok Build app.
        Current Working Directory: \(workingDirectory.path)
        Safety Mode: \(safetyEnabled ? "ENABLED (Destructive commands blocked)" : "DISABLED")
        Current Mode: \(mode.displayName)
        
        \(modeInstruction)
        
        AVAILABLE TOOLS:
        \(registry.allToolDescriptions())
        
        TOOL USE FORMAT:
        When you need to use a tool, output **only** a valid JSON object like this (no extra text):
        
        ```json
        {
          "tool": "tool_name",
          "arguments": {
            "param1": "value1",
            "param2": "value2"
          }
        }
        ```
        
        After receiving the tool result, continue reasoning and use more tools if needed until the task is complete.
        When the task is done, give a final clear answer to the user.
        
        IMPORTANT: If the user asks what is in a folder, directory, or project, call `list_directory` immediately (use `"."` for the current workspace). Do not reply that you will check — run the tool first.
        If the user asks to create a folder, call `create_directory` with the folder name immediately. Do not reply that you will create it — run the tool first.
        """
        
        apiMessages.insert(["role": "system", "content": toolsInstruction], at: 0)
        
        let body: [String: Any] = [
            "messages": apiMessages,
            "model": modelID,
            "stream": false,
            "temperature": 0.1 // Low temp for precise tool use
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Update status (no model name - that appears after response)
        DispatchQueue.main.async {
            self.requestStatus = "Thinking..."
        }

        // Start a timer to update status with elapsed time for long requests
        let statusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
            DispatchQueue.main.async {
                guard self.currentRequestId == requestId, let startTime = self.requestStartTime else {
                    timer.invalidate()
                    return
                }
                let elapsed = Int(Date().timeIntervalSince(startTime))
                if elapsed > 30 {
                    self.requestStatus = "Still processing... (\(elapsed)s)"
                } else if elapsed > 10 {
                    self.requestStatus = "Thinking... (\(elapsed)s)"
                }
            }
        }

        // Use retry helper for resilient API calls
        APIRetryHelper.performRequest(request) { data, response, error in
            // Stop the status timer
            statusTimer.invalidate()

            DispatchQueue.main.async {
                // Check if request was cancelled
                guard self.currentRequestId == requestId else {
                    return  // Request was cancelled, ignore response
                }

                // Find message index
                guard let index = messages.firstIndex(where: { $0.id == assistantMsgId }) else {
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil
                    activeAssistantMessageId = nil
                    activeAssistantMessageId = nil
                    return
                }

                // Track model used (append to attempted list, set as final)
                if messages[index].modelsAttempted == nil {
                    messages[index].modelsAttempted = []
                }
                messages[index].modelsAttempted?.append(modelID)
                messages[index].usedModel = modelID

                // Handle network errors
                if let error = error {
                    let nsError = error as NSError
                    var userFriendlyMessage = "Network error occurred"

                    // Provide more specific error messages
                    if nsError.code == NSURLErrorTimedOut {
                        userFriendlyMessage = "Request timed out. The server took too long to respond. Please try again."
                    } else if nsError.code == NSURLErrorNotConnectedToInternet {
                        userFriendlyMessage = "No internet connection. Please check your network and try again."
                    } else if nsError.code == NSURLErrorCannotFindHost || nsError.code == NSURLErrorCannotConnectToHost {
                        userFriendlyMessage = "Cannot reach xAI servers. Please check your internet connection."
                    } else {
                        userFriendlyMessage = "Network error: \(error.localizedDescription)"
                    }

                    messages[index].content = "❌ \(userFriendlyMessage)"
                    messages[index].isThinking = false
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil
                    activeAssistantMessageId = nil
                    return
                }

                // Handle HTTP errors (after retries exhausted)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    let errorMsg = APIRetryHelper.parseErrorMessage(from: data, statusCode: httpResponse.statusCode)
                    var userFriendlyError = "API Error (\(httpResponse.statusCode))"

                    // Provide context for common errors
                    if httpResponse.statusCode == 401 {
                        userFriendlyError = grokBuildAuth.isUsingGrokBuildSession
                            ? "Grok Build session expired. Run `grok login` in Terminal, then reopen Build."
                            : "Authentication failed. Sign in with Grok Build or check your API key in Settings."
                    } else if httpResponse.statusCode == 429 {
                        userFriendlyError = "Rate limit exceeded. Please wait a moment and try again."
                    } else if httpResponse.statusCode == 403 {
                        let fallbackModels = ModelRegistry.fallbackModels(
                            excluding: modelID,
                            from: self.availableModels.isEmpty ? ModelRegistry.oauthCompatibleModels : self.availableModels
                        )
                        for fallbackModel in fallbackModels {
                            messages[index].content = ""
                            messages[index].isThinking = true
                            requestStatus = "Retrying with \(ModelRegistry.shortName(for: fallbackModel))..."
                            self.performAPICall(assistantMsgId: assistantMsgId, modelID: fallbackModel, authToken: authToken)
                            return
                        }
                        userFriendlyError = grokBuildAuth.isUsingGrokBuildSession
                            ? "Model '\(ModelRegistry.friendlyName(for: modelID))' isn't available on your Grok Build plan via the API. Try the **Build** model or use the Grok agent when ready."
                            : errorMsg
                    } else if httpResponse.statusCode == 400 {
                        // Model might not be available - try fallback with latest models first
                        #if DEBUG
                        print("⚠️ 400 error with model '\(modelID)': \(errorMsg)")
                        print("   Available models: \(self.availableModels)")
                        #endif

                        let fallbackModels = ModelRegistry.fallbackModels(
                            excluding: modelID,
                            from: self.availableModels.isEmpty ? ModelRegistry.defaultModelPreference : self.availableModels
                        )

                        for fallbackModel in fallbackModels {
                            #if DEBUG
                            print("   🔄 Retrying with fallback model: \(fallbackModel)")
                            #endif
                            messages[index].content = ""
                            messages[index].isThinking = true
                            requestStatus = "Retrying..."
                            self.performAPICall(assistantMsgId: assistantMsgId, modelID: fallbackModel, authToken: authToken)
                            return
                        }

                        userFriendlyError = "Model '\(modelID)' is not available. \(errorMsg)"
                    } else if httpResponse.statusCode >= 500 {
                        userFriendlyError = "xAI server error (\(httpResponse.statusCode)). Please try again in a moment."
                    } else {
                        userFriendlyError = errorMsg
                    }

                    messages[index].content = "❌ \(userFriendlyError)"
                    messages[index].isThinking = false
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil
                    activeAssistantMessageId = nil
                    return
                }

                guard let data = data else {
                    messages[index].content = "❌ No data received from server"
                    messages[index].isThinking = false
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil
                    activeAssistantMessageId = nil
                    return
                }

                // Update status
                requestStatus = "Processing..."

                do {
                    // Response Structs
                    struct ChatResponse: Decodable {
                        struct Choice: Decodable {
                            struct Message: Decodable {
                                let content: String?
                            }
                            let message: Message
                        }
                        struct Usage: Decodable {
                            let prompt_tokens: Int
                            let completion_tokens: Int
                            let total_tokens: Int
                        }
                        let choices: [Choice]
                        let usage: Usage?
                    }

                    let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
                    let content = decoded.choices.first?.message.content ?? "No response"
                    
                    // Update token usage and cost
                    if let usage = decoded.usage {
                        // Only update if we're still in the same session (prevent race condition)
                        guard self.currentSessionId == sessionIdAtStart else { return }
                        
                        self.totalTokens = usage.total_tokens
                        self.currentModelUsed = modelID
                        self.lastInputTokens = usage.prompt_tokens
                        self.lastOutputTokens = usage.completion_tokens
                        
                        // Dynamic context window based on model
                        let maxContext = ModelRegistry.contextWindow(for: modelID)
                        self.contextUsage = Double(usage.total_tokens) / Double(maxContext)
                        
                        // Calculate cost for this request
                        let requestCost = ModelRegistry.calculateCost(
                            model: modelID,
                            inputTokens: usage.prompt_tokens,
                            outputTokens: usage.completion_tokens
                        )
                        self.sessionCost += requestCost
                        self.totalCost += requestCost
                        
                        // Persist total cost
                        UserDefaults.standard.set(self.totalCost, forKey: "totalApiCost")
                    }
                    
                    messages[index].content = content
                    
                    // CHECK FOR TOOLS - Respect Grok Build Mode
                    if content.contains("\"tool\":") {
                        // Parse JSON from content block
                        if let action = parseToolAction(from: content) {
                            messages[index].isThinking = false
                            messages[index].toolAction = action.description

                            // === MODE-BASED BEHAVIOR ===
                            switch grokBuildMode {
                            case .chat:
                                if action.isReadOnly {
                                    break // execute read-only tools below
                                } else {
                                    messages[index].toolOutput = "💬 **Chat Mode** — Proposed action:\n\n\(action.description)\n\nThis was **not executed**. Switch to Agent or Agent (full auto) to run it."
                                    messages[index].isThinking = false
                                    isSending = false
                                    requestStatus = ""
                                    return
                                }

                            case .agent:
                                // AGENT MODE: Ask for approval
                                messages[index].toolOutput = "⏸️ Awaiting your approval to run:\n\n\(action.description)"
                                messages[index].pendingToolAction = action
                                messages[index].isThinking = false
                                isSending = false
                                requestStatus = "Waiting for approval..."
                                return

                            case .agentAuto:
                                // AGENT (AUTO): Execute immediately
                                break
                            }

                            // Update status
                            let activityDetail: String?
                            let activityIcon: String
                            let activityTitle: String
                            switch action {
                            case .terminal(let cmd):
                                activityTitle = "Running command"
                                activityDetail = cmd
                                activityIcon = "terminal"
                                requestStatus = "Running command..."
                            case .readFile(let path):
                                activityTitle = "Reading file"
                                activityDetail = path
                                activityIcon = "doc.text"
                                requestStatus = "Reading file..."
                            case .writeFile(let path, _):
                                activityTitle = "Writing file"
                                activityDetail = path
                                activityIcon = "square.and.pencil"
                                requestStatus = "Writing file..."
                            case .createDirectory(let path):
                                activityTitle = "Creating folder"
                                activityDetail = path
                                activityIcon = "folder.badge.plus"
                                requestStatus = "Creating folder..."
                            case .fetchWeb(let url):
                                activityTitle = "Fetching URL"
                                activityDetail = url
                                activityIcon = "globe"
                                requestStatus = "Fetching..."
                            case .searchWeb(let query):
                                activityTitle = "Searching web"
                                activityDetail = query
                                activityIcon = "magnifyingglass"
                                requestStatus = "Searching..."
                            case .openURL(let url):
                                activityTitle = "Opening URL"
                                activityDetail = url
                                activityIcon = "link"
                                requestStatus = "Opening..."
                            case .checkServerStatus(let port):
                                activityTitle = "Checking server"
                                activityDetail = "localhost:\(port)"
                                activityIcon = "network"
                                requestStatus = "Checking..."
                            }
                            appendAgentActivity(
                                to: assistantMsgId,
                                icon: activityIcon,
                                title: activityTitle,
                                detail: activityDetail
                            )

                            // Execute tool
                            executeToolActionAsync(action) { [self] output in
                                completeAgentActivity(for: assistantMsgId)
                                appendAgentActivity(
                                    to: assistantMsgId,
                                    icon: "checkmark.circle",
                                    title: "Tool finished",
                                    detail: String(output.prefix(120)),
                                    inProgress: false
                                )
                                // 2. Store tool execution data in the assistant's message for UI display
                                messages[index].toolOutput = output

                                // 3. Create a hidden user message with the output for the API
                                // This message is for the API to analyze, but won't be displayed in UI
                                var hiddenMessage: ChatMessage
                                if shouldShowToolOutput(action, output: output) {
                                    hiddenMessage = ChatMessage(role: "user", content: "Terminal Output:\n```\n\(output)\n```\nAnalyze this output.", isHiddenFromUI: true)
                                } else {
                                    hiddenMessage = ChatMessage(role: "user", content: "Tool executed successfully. Output: \(output)", isHiddenFromUI: true)
                                }
                                messages.append(hiddenMessage)

                                // SAVE STATE
                                if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
                                    sessions[idx].messages = messages
                                    sessions[idx].lastModified = Date()
                                    PersistenceController.shared.save(sessions: sessions)
                                }

                                // 4. Recursive Call to interpret result
                                requestStatus = "Analyzing..."
                                appendAgentActivity(
                                    to: assistantMsgId,
                                    icon: "brain.head.profile",
                                    title: "Analyzing results"
                                )
                                let nextId = UUID()
                                messages.append(ChatMessage(id: nextId, role: "assistant", content: "", isThinking: true))
                                performAPICall(assistantMsgId: nextId, modelID: modelID, authToken: authToken)
                            }
                            return
                        }
                    }

                    messages[index].isThinking = false
                    completeAgentActivity(for: assistantMsgId)
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil
                    activeAssistantMessageId = nil
                    
                    // SAVE FINAL STATE
                    if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
                        sessions[idx].messages = messages
                        sessions[idx].lastModified = Date()
                        PersistenceController.shared.save(sessions: sessions)
                        
                        // Auto-Name
                        if sessions[idx].title == "New Chat" && messages.count >= 2 {
                            generateSessionTitle()
                        }
                    }
                    
                } catch {
                    messages[index].content = "❌ Failed to parse response from server. The API returned an unexpected format.\n\nError: \(error.localizedDescription)"
                    messages[index].isThinking = false
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil
                    activeAssistantMessageId = nil
                }
            }
        }
    }
    
    // MARK: - Agent Mode Approval Helpers

    func approvePendingTool(messageId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let action = messages[index].pendingToolAction else { return }

        messages[index].pendingToolAction = nil
        messages[index].toolOutput = "✅ Approved by user. Executing..."

        executeToolActionAsync(action) { [self] output in
            messages[index].toolOutput = output

            // Continue the agent loop
            let nextId = UUID()
            messages.append(ChatMessage(id: nextId, role: "assistant", content: "", isThinking: true))
            authTokenForRequest { token in
                guard let token, !token.isEmpty else { return }
                performAPICall(assistantMsgId: nextId, modelID: selectedModel, authToken: token)
            }
        }
    }

    func rejectPendingTool(messageId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        let actionDesc = messages[index].pendingToolAction?.description ?? "action"
        messages[index].pendingToolAction = nil
        messages[index].toolOutput = "❌ Rejected by user."

        // Tell the model it was rejected
        let hiddenMessage = ChatMessage(role: "user", content: "The user rejected the proposed action: \(actionDesc)", isHiddenFromUI: true)
        messages.append(hiddenMessage)

        // Let the model replan
        let nextId = UUID()
        messages.append(ChatMessage(id: nextId, role: "assistant", content: "", isThinking: true))
        authTokenForRequest { token in
            guard let token, !token.isEmpty else { return }
            performAPICall(assistantMsgId: nextId, modelID: selectedModel, authToken: token)
        }
    }

    // MARK: - Tool Logic
    
    func parseToolAction(from text: String) -> ToolAction? {
        guard let payload = GrokBuildToolParser.parsePayload(from: text),
              let (toolName, args) = GrokBuildToolParser.normalize(payload) else { return nil }

        switch toolName {
        case "terminal", "run_command", "run_terminal_command", "shell":
            if let cmd = args["command"] { return .terminal(cmd) }
        case "read_file":
            if let path = args["path"] { return .readFile(path) }
        case "write_file":
            if let path = args["path"], let content = args["content"] { return .writeFile(path, content) }
        case "create_directory", "mkdir":
            if let path = args["path"] { return .createDirectory(path) }
        case "list_directory":
            if let path = args["path"], !path.isEmpty { return .terminal("ls -la \"\(path)\"") }
            return .terminal("ls -la")
        case "get_working_directory", "pwd":
            return .terminal("pwd")
        case "fetch_web":
            if let url = args["url"] { return .fetchWeb(url) }
        case "search_web":
            if let query = args["query"] ?? args["q"] { return .searchWeb(query) }
        case "open_url", "open_browser":
            if let url = args["url"] { return .openURL(url) }
        case "check_server", "check_port":
            if let portStr = args["port"], let port = Int(portStr) { return .checkServerStatus(port) }
        default:
            return nil
        }
        return nil
    }
    
    // MARK: - Command Safety Validation

    /// Validates if a command is safe to execute
    /// Uses a combination of whitelist for safe commands and blocklist for known dangerous patterns
    func validateCommand(_ command: String) -> (safe: Bool, reason: String?) {
        // Normalize command for checking (lowercase, trim whitespace)
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Extract the base command (first word)
        let baseCommand = normalized.split(separator: " ").first.map(String.init) ?? normalized

        // === WHITELIST: Safe commands that are always allowed ===
        let safeCommands: Set<String> = [
            // Navigation & Listing
            "ls", "pwd", "cd", "tree", "find", "locate", "which", "whereis", "file",
            // Reading
            "cat", "head", "tail", "less", "more", "wc", "grep", "awk", "sed", "cut", "sort", "uniq",
            // Git (read operations)
            "git", "gh",
            // Development
            "swift", "swiftc", "xcodebuild", "xcrun", "clang", "make", "cmake",
            "npm", "npx", "yarn", "pnpm", "node", "python", "python3", "pip", "pip3",
            "ruby", "gem", "bundle", "cargo", "rustc", "go",
            // Package managers (read)
            "brew", "port",
            // Info commands
            "echo", "printf", "date", "cal", "uptime", "whoami", "hostname", "uname",
            "df", "du", "free", "top", "ps", "env", "printenv",
            // Network (read-only)
            "curl", "wget", "ping", "host", "dig", "nslookup",
            // Compression (read)
            "tar", "zip", "unzip", "gzip", "gunzip",
            // Text processing
            "diff", "patch", "jq", "yq", "xmllint",
            // Directory creation (safe)
            "mkdir", "touch",
            // Testing
            "test", "[", "true", "false"
        ]

        // === BLOCKLIST: Dangerous patterns always blocked ===
        let dangerousPatterns: [(pattern: String, reason: String)] = [
            // Destructive commands
            ("rm ", "File deletion is blocked"),
            ("rm\t", "File deletion is blocked"),
            ("rmdir", "Directory deletion is blocked"),
            ("unlink", "File deletion is blocked"),
            ("shred", "Secure deletion is blocked"),

            // Privilege escalation
            ("sudo", "Privilege escalation is blocked"),
            ("su ", "User switching is blocked"),
            ("doas", "Privilege escalation is blocked"),

            // Dangerous file operations
            ("mv ", "File moving is blocked (use cp instead)"),
            ("chmod", "Permission changes are blocked"),
            ("chown", "Ownership changes are blocked"),
            ("chgrp", "Group changes are blocked"),
            ("chflags", "Flag changes are blocked"),

            // System modification
            ("dd ", "Disk operations are blocked"),
            ("mkfs", "Filesystem creation is blocked"),
            ("mount", "Mount operations are blocked"),
            ("umount", "Unmount operations are blocked"),
            ("diskutil", "Disk utility is blocked"),

            // Process control
            ("kill", "Process termination is blocked"),
            ("pkill", "Process termination is blocked"),
            ("killall", "Process termination is blocked"),

            // Shell injection vectors
            ("; rm", "Command chaining with rm is blocked"),
            ("&& rm", "Command chaining with rm is blocked"),
            ("|| rm", "Command chaining with rm is blocked"),
            ("`rm", "Command substitution with rm is blocked"),
            ("$(rm", "Command substitution with rm is blocked"),
            ("| sh", "Piping to shell is blocked"),
            ("| bash", "Piping to shell is blocked"),
            ("| zsh", "Piping to shell is blocked"),
            ("|sh", "Piping to shell is blocked"),
            ("|bash", "Piping to shell is blocked"),
            ("|zsh", "Piping to shell is blocked"),

            // Dangerous redirects
            ("> /", "Redirecting to root paths is blocked"),
            (">/", "Redirecting to root paths is blocked"),
            (">> /", "Appending to root paths is blocked"),
            (">>/", "Appending to root paths is blocked"),

            // Network dangers
            ("nc ", "Netcat is blocked"),
            ("netcat", "Netcat is blocked"),
            ("ncat", "Netcat is blocked"),

            // Cron/at (persistent)
            ("crontab", "Cron modification is blocked"),
            ("at ", "Scheduled tasks are blocked"),

            // LaunchD
            ("launchctl", "LaunchD modification is blocked"),
        ]

        // Check blocklist first (even for whitelisted base commands)
        for (pattern, reason) in dangerousPatterns {
            if normalized.contains(pattern.lowercased()) {
                return (false, reason)
            }
        }

        // Check if base command is in whitelist
        if safeCommands.contains(baseCommand) {
            return (true, nil)
        }

        // Unknown command - block by default in safety mode
        return (false, "Command '\(baseCommand)' is not in the allowed list. Disable Safety Mode to run arbitrary commands.")
    }

    // MARK: - Background Process Management

    /// Detect if a command is a long-running server command
    private func isServerCommand(_ command: String) -> Bool {
        let serverPatterns = [
            "npm run dev", "npm start", "npm run start",
            "yarn dev", "yarn start",
            "pnpm dev", "pnpm start",
            "npx next dev", "next dev",
            "python -m http.server", "python3 -m http.server",
            "flask run", "uvicorn", "gunicorn",
            "node server", "nodemon",
            "cargo run", "go run",
            "php -S", "ruby -run"
        ]
        let lowercased = command.lowercased()
        return serverPatterns.contains { lowercased.contains($0) }
    }

    /// Check if a port is currently in use on localhost
    private func isPortInUse(port: Int) -> Bool {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", "lsof -i :\(port) | grep LISTEN"]

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// Async version of executeToolAction - runs on background thread
    func executeToolActionAsync(_ action: ToolAction, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.executeToolAction(action)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func executeToolAction(_ action: ToolAction) -> String {
        switch action {
        case .terminal(let command):
            // Security Check with enhanced validation
            if safetyEnabled {
                let validation = validateCommand(command)
                if !validation.safe {
                    return "🛡️ Safety Mode Blocked: \(validation.reason ?? "Command not allowed")\n\nTo run this command, disable Safety Mode in Settings (⚠️ use with caution)."
                }
            }

            let task = Process()
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.currentDirectoryURL = workingDirectory
            task.launchPath = "/bin/zsh"
            task.arguments = ["-c", command]

            do {
                try task.run()

                // Check if this is a server/long-running command
                if isServerCommand(command) {
                    // For server commands, don't wait - just start and return early
                    let processId = UUID()
                    DispatchQueue.main.async {
                        self.runningProcesses[processId] = task
                    }

                    // Extract port from command
                    var port = "3000" // default
                    if let portMatch = command.range(of: #"-p\s*(\d+)"#, options: .regularExpression) ??
                                      command.range(of: #"--port\s*(\d+)"#, options: .regularExpression) ??
                                      command.range(of: #":(\d{4,5})"#, options: .regularExpression) {
                        let portStr = String(command[portMatch])
                        if let nums = portStr.range(of: #"\d+"#, options: .regularExpression) {
                            port = String(portStr[nums])
                        }
                    }

                    // Check if port is already in use BEFORE waiting
                    let portInUse = isPortInUse(port: Int(port) ?? 3000)

                    // Give the server a moment to start and check for immediate errors
                    Thread.sleep(forTimeInterval: 2.5)

                    // Read any initial output (non-blocking)
                    let fileHandle = pipe.fileHandleForReading
                    let availableData = fileHandle.availableData
                    let initialOutput = String(data: availableData, encoding: .utf8) ?? ""

                    if task.isRunning {
                        return """
                        ✅ Server started successfully!

                        🌐 The development server is now running at: http://localhost:\(port)

                        Initial output:
                        ```
                        \(initialOutput.isEmpty ? "(Server is starting...)" : String(initialOutput.prefix(500)))
                        ```

                        💡 The server will continue running in the background.

                        **Useful commands:**
                        • Check status: `lsof -i :\(port)`
                        • Stop server: `pkill -f "\(command.prefix(30))"`
                        """
                    } else {
                        // Server exited immediately - probably an error
                        let remainingData = fileHandle.readDataToEndOfFile()
                        let fullOutput = initialOutput + (String(data: remainingData, encoding: .utf8) ?? "")

                        // Detect port conflict
                        if portInUse || fullOutput.lowercased().contains("address already in use") ||
                           fullOutput.lowercased().contains("eaddrinuse") ||
                           fullOutput.lowercased().contains("port") && fullOutput.lowercased().contains("already") {
                            return """
                            ⚠️ Port \(port) is already in use!

                            Another process is using this port. You have a few options:

                            **Option 1: Kill the existing process**
                            ```bash
                            lsof -ti :\(port) | xargs kill -9
                            ```

                            **Option 2: Use a different port**
                            ```bash
                            \(command) --port \(Int(port)! + 1)
                            ```

                            **Option 3: Find what's using the port**
                            ```bash
                            lsof -i :\(port)
                            ```

                            Original error:
                            ```
                            \(fullOutput.prefix(300))
                            ```
                            """
                        }

                        return "❌ Server failed to start:\n```\n\(fullOutput)\n```"
                    }
                }

                // For regular commands, wait with timeout
                let timeout: TimeInterval = 30.0
                let deadline = Date().addingTimeInterval(timeout)

                var outputData = Data()
                let fileHandle = pipe.fileHandleForReading

                // Read with timeout
                while task.isRunning && Date() < deadline {
                    let available = fileHandle.availableData
                    if !available.isEmpty {
                        outputData.append(available)
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                // If still running after timeout, get what we have
                if task.isRunning {
                    task.terminate()
                    let remaining = fileHandle.availableData
                    outputData.append(remaining)
                    let output = String(data: outputData, encoding: .utf8) ?? "No output"
                    return "⚠️ Command timed out after \(Int(timeout))s. Partial output:\n\(output)"
                }

                // Command completed normally
                let remaining = fileHandle.readDataToEndOfFile()
                outputData.append(remaining)
                let output = String(data: outputData, encoding: .utf8) ?? "No output"

                // Check if this was a git command that might affect repository state
                let gitStateCommands = ["git checkout", "git branch", "git switch", "git init", "git commit", "git add", "git reset", "git restore"]
                let isGitStateCommand = gitStateCommands.contains { command.contains($0) }

                if isGitStateCommand {
                    // Refresh git status on main thread after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.refreshGitStatus()
                        self.refreshGitChanges()
                    }
                }

                return output
            } catch {
                return "Command failed: \(error.localizedDescription)"
            }
            
        case .readFile(let path):
            // Security Check: Path Traversal
            if path.contains("..") && safetyEnabled { return "Error: Path traversal blocked by Safety Mode." }
            
            let fileURL = workingDirectory.appendingPathComponent(path)
            
            // Safeguard 1: File Existence
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return "Error: File not found at \(path)"
            }
            
            // Safeguard 2: Binary & Size Check
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = attributes[.size] as? UInt64 ?? 0
                
                // Limit: 1MB (Soft limit to prevent UI/Memory freeze)
                if fileSize > 1_000_000 {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    let partialData = handle.readData(ofLength: 100_000) // Read first 100KB
                    handle.closeFile()
                    
                    if let content = String(data: partialData, encoding: .utf8) {
                         return "⚠️ File is too large (\(fileSize / 1024) KB). Showing first 100KB:\n\n" + content
                    } else {
                        return "Error: File is too large and appears to be binary."
                    }
                }
                
                // Check for Binary (Scan first 1024 bytes for null characters)
                let handle = try FileHandle(forReadingFrom: fileURL)
                let checkData = handle.readData(ofLength: 1024)
                handle.closeFile()
                
                if checkData.contains(0) {
                     return "Error: File appears to be binary (image, executable, etc.) and cannot be read as text."
                }
                
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                return content
            } catch {
                return "Error reading file: \(error.localizedDescription)"
            }
            
        case .writeFile(let path, let content):
            if path.contains("..") && safetyEnabled { return "Error: Path traversal blocked by Safety Mode." }
            
            let fileURL = workingDirectory.appendingPathComponent(path)
            do {
                // Ensure directory exists
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try content.write(to: fileURL, atomically: true, encoding: .utf8)

                DispatchQueue.main.async { self.refreshFileList() }
                return "Successfully wrote to \(path)"
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }

        case .createDirectory(let path):
            if path.contains("..") && safetyEnabled { return "Error: Path traversal blocked by Safety Mode." }

            let dirURL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path).standardized
                : workingDirectory.appendingPathComponent(path).standardized
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                DispatchQueue.main.async { self.refreshFileList() }
                return "Created directory: \(dirURL.lastPathComponent)"
            } catch {
                return "Error creating directory: \(error.localizedDescription)"
            }
            
        case .fetchWeb(let urlString):
             // Synchronous hack
             let semaphore = DispatchSemaphore(value: 0)
             var result = ""
             
             guard let url = URL(string: urlString) else { return "Invalid URL" }
             
             let task = URLSession.shared.dataTask(with: url) { data, response, error in
                 defer { semaphore.signal() }
                 if let error = error {
                     result = "Error fetching: \(error.localizedDescription)"
                     return
                 }
                 if let data = data, let html = String(data: data, encoding: .utf8) {
                     // Simple Strip Tags
                     let str = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
                     result = String(str.prefix(5000))
                 }
             }
             task.resume()
             semaphore.wait()
             return result.isEmpty ? "No content or timed out" : result
            
        case .searchWeb(let query):
            let semaphore = DispatchSemaphore(value: 0)
            var result = ""
            
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else { return "Invalid Query" }
            
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }
                if let error = error {
                    result = "Search Error: \(error.localizedDescription)"
                    return
                }
                
                if let data = data, let html = String(data: data, encoding: .utf8) {
                     // Robust Parse of DuckDuckGo HTML Result
                     // Format: <a rel="..." class="result__a" href="...">Title</a> ... <a class="result__snippet" ...>Snippet</a>
                     var results: [String] = []
                     
                     // Split by result divs to keep title and snippet together
                     let resultDivs = html.components(separatedBy: "class=\"result results_links")
                     
                     for div in resultDivs.dropFirst().prefix(6) {
                         // Extract Title & Link
                         let titlePattern = "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
                         var title = "No Title"
                         var link = ""
                         
                         if let titleRegex = try? NSRegularExpression(pattern: titlePattern, options: .caseInsensitive),
                            let match = titleRegex.firstMatch(in: div, options: [], range: NSRange(div.startIndex..., in: div)) {
                                 if let hrefRange = Range(match.range(at: 1), in: div),
                                    let textRange = Range(match.range(at: 2), in: div) {
                                     link = String(div[hrefRange])
                                     title = String(div[textRange]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                                 }
                         }
                         
                         // Extract Snippet
                         let snippetPattern = "<a[^>]*class=\"result__snippet\"[^>]*>(.*?)</a>"
                         var snippet = ""
                         
                         if let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: .caseInsensitive),
                            let match = snippetRegex.firstMatch(in: div, options: [], range: NSRange(div.startIndex..., in: div)) {
                                 if let textRange = Range(match.range(at: 1), in: div) {
                                     snippet = String(div[textRange]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                                     snippet = snippet.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'")
                                 }
                         }
                         
                         if !link.isEmpty {
                             // Clean up DDG redirect links
                             var cleanUrl = link
                             if cleanUrl.hasPrefix("//duckduckgo.com/l/?uddg=") {
                                  cleanUrl = cleanUrl.replacingOccurrences(of: "//duckduckgo.com/l/?uddg=", with: "")
                                  cleanUrl = cleanUrl.removingPercentEncoding ?? cleanUrl
                                  if let end = cleanUrl.range(of: "&rut=") {
                                      cleanUrl = String(cleanUrl[..<end.lowerBound])
                                  }
                             }
                             
                             results.append("### \(title)\nURL: \(cleanUrl)\nSnippet: \(snippet)\n")
                         }
                     }
                     
                     if results.isEmpty {
                         result = "No search results found for query: \(query)"
                     } else {
                         result = "Web Search Results:\n\n" + results.joined(separator: "\n")
                     }
                }
            }
            task.resume()
            semaphore.wait()
            return result

        case .openURL(let urlString):
            // Open URL in browser with localhost handling
            return openURLInBrowser(urlString)

        case .checkServerStatus(let port):
            // Check if localhost port is responding
            return checkLocalhostPort(port)
        }
    }

    /// Opens a URL in the default browser with smart localhost handling
    /// For localhost URLs, checks if server is running first and provides helpful errors
    private func openURLInBrowser(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else {
            return "❌ Invalid URL: \(urlString)"
        }

        // Check if this is a localhost URL
        let isLocalhost = url.host == "localhost" || url.host == "127.0.0.1"

        if isLocalhost, let port = url.port {
            // Check if server is actually running
            let portCheck = checkLocalhostPort(port)

            if portCheck.contains("not responding") || portCheck.contains("Connection refused") {
                return """
                ⚠️ Cannot open \(urlString)

                The development server on port \(port) is not running yet.

                **Suggestions:**
                1. Start the server first: `npm run dev` or similar
                2. Check if port \(port) is already in use: `lsof -i :\(port)`
                3. Wait a few seconds for the server to start

                💡 Tip: Start the server before trying to open the browser.
                """
            }
        }

        // Open in default browser
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }

        if isLocalhost {
            return "✅ Opened \(urlString) in your default browser\n\n💡 Development server detected - refresh the browser if page doesn't load immediately."
        }

        return "✅ Opened \(urlString) in your default browser"
    }

    /// Checks if a localhost port is responding
    /// Useful for verifying development servers are running before opening browser
    private func checkLocalhostPort(_ port: Int) -> String {
        let urlString = "http://localhost:\(port)"
        guard let url = URL(string: urlString) else {
            return "❌ Invalid port: \(port)"
        }

        var result = "⏳ Checking localhost:\(port)..."
        let semaphore = DispatchSemaphore(value: 0)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3.0  // Quick timeout

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCannotConnectToHost ||
                   nsError.code == -61 || // Connection refused
                   nsError.code == NSURLErrorTimedOut {
                    result = """
                    ❌ Server on port \(port) is not responding

                    **Possible causes:**
                    • No server running on this port
                    • Server is still starting up
                    • Server crashed or was stopped

                    **To check:**
                    ```bash
                    lsof -i :\(port)
                    ```
                    """
                } else {
                    result = "⚠️ Connection error: \(error.localizedDescription)"
                }
            } else if let httpResponse = response as? HTTPURLResponse {
                result = """
                ✅ Server on port \(port) is running!

                • Status: \(httpResponse.statusCode)
                • URL: \(urlString)

                Ready to open in browser.
                """
            } else {
                result = "✅ Server on port \(port) appears to be running"
            }
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()
        return result
    }

    /// Determines whether tool output should be displayed in the chat interface
    /// Returns true for complex operations that benefit from visible output
    /// Returns false for simple operations where the description is sufficient
    func shouldShowToolOutput(_ action: ToolAction, output: String) -> Bool {
        // Always show output if there's an error
        if output.contains("Error:") || output.contains("error:") ||
           output.contains("Failed") || output.contains("failed") ||
           output.contains("🛡️ Safety Mode Blocked") {
            return true
        }

        switch action {
        case .terminal(let command):
            // Hide output for simple file operations
            let simpleCommands = [
                "rm ", "mv ", "cp ", "mkdir ", "touch ",
                "git add", "git commit -m", "git status",
                "ls ", "pwd", "cd ", "echo "
            ]

            // Check if it's a simple command
            for simpleCmd in simpleCommands {
                if command.trimmingCharacters(in: .whitespaces).hasPrefix(simpleCmd) {
                    return false
                }
            }

            // Show output for complex/long-running commands
            let complexCommands = [
                "npm install", "npm run", "npm start", "npm test",
                "yarn install", "yarn add", "yarn start", "yarn test",
                "pip install", "pip3 install",
                "cargo build", "cargo run", "cargo test",
                "make", "cmake",
                "docker", "kubectl",
                "git clone", "git pull", "git push", "git log", "git diff",
                "curl", "wget",
                "python", "node", "ruby", "go run",
                "jest", "mocha", "pytest",
                "eslint", "tslint", "pylint"
            ]

            for complexCmd in complexCommands {
                if command.contains(complexCmd) {
                    return true
                }
            }

            // Default: show output for terminal commands we're unsure about
            return true

        case .readFile(_):
            // Don't show output for file reads - the content will be in the assistant's response
            return false

        case .writeFile(_, _):
            // Don't show output for file writes - success message is sufficient
            return false

        case .createDirectory(_):
            return false

        case .fetchWeb(_):
            // Don't show output for web fetches - content will be in assistant's response
            return false

        case .searchWeb(_):
            // Show search results as they're useful to see
            return true

        case .openURL(_):
            // Show URL open result (especially helpful for localhost errors)
            return true

        case .checkServerStatus(_):
            // Show server status check results
            return true
        }
    }
}

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: ChatMessage
    var requestStatus: String = ""
    var isActiveInference: Bool = false
    var onApprove: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil
    @State private var isOutputExpanded: Bool = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == "user" {
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    // Image Preview in User Bubble
                    if let data = message.imageData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 400, maxHeight: 300)
                            .cornerRadius(12)
                    }
                    
                    if !message.content.isEmpty {
                        // CHECK IF THIS IS A TOOL OUTPUT
                        if message.content.hasPrefix("Terminal Output:") || message.content.hasPrefix("Tool Output:") {
                            // TERMINAL / TOOL OUTPUT (Collapsible, subtle)
                            VStack(alignment: .leading, spacing: 8) {
                                Button(action: { isOutputExpanded.toggle() }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "terminal.fill")
                                            .font(.system(size: 10))
                                        Text("Output")
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Image(systemName: isOutputExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() }
                                    else { NSCursor.pop() }
                                }
                                
                                if isOutputExpanded {
                                    // Clean monospaced output
                                    ScrollView(.horizontal, showsIndicators: true) {
                                        Text(message.content)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.primary.opacity(0.85))
                                            .padding(12)
                                            .textSelection(.enabled)
                                    }
                                    .background(Color.primary.opacity(0.03))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
           .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                }
                            }
                            .frame(maxWidth: 650)
                        } else {
                            // STANDARD USER MESSAGE
                            Text(message.content)
                                .font(.system(size: 15))
                                .padding(14)
                                .foregroundStyle(.primary)
                                .background(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.08))
                                .cornerRadius(16)
                                .frame(maxWidth: 650, alignment: .trailing)
                        }
                    }
                }
            } else {
                // ASSISTANT MESSAGE
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cpu") // Avatar
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(Circle())
                        .padding(.top, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        if message.isThinking {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(requestStatus.isEmpty ? "Working…" : requestStatus)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else if isToolCall(message.content) {
                            // RENDER TOOL CALL
                            ToolCallBadge(content: message.content)
                        } else {
                            // Show tool execution badge if this message executed a tool
                            if let toolAction = message.toolAction {
                                ToolExecutionBadge(action: toolAction, output: message.toolOutput)
                            }

                            // APPROVAL UI for Agent mode
                            if let pending = message.pendingToolAction {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Grok wants to perform this action:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text(pending.description)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(8)
                                        .background(Color.yellow.opacity(0.15))
                                        .cornerRadius(6)

                                    HStack {
                                        Button("Approve & Run") {
                                            onApprove?()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.green)

                                        Button("Reject") {
                                            onReject?()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.top, 6)
                            }

                            // RICH MARKDOWN CONTENT
                            if !message.content.isEmpty {
                                MarkdownView(content: message.content)
                            }

                            let activityLines = AgentActivityLine.visibleLines(
                                from: message.activityLines,
                                isLive: isActiveInference
                            )
                            if !activityLines.isEmpty {
                                AgentActivityFeedView(
                                    lines: activityLines,
                                    isLive: isActiveInference
                                )
                            }

                            if !requestStatus.isEmpty, isActiveInference {
                                Label(requestStatus, systemImage: "ellipsis.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .labelStyle(.titleAndIcon)
                                    .padding(.top, 2)
                            }
                            
                            // Footer: Copy Button & Model Info
                            HStack {
                                // Show model(s) used
                                if let attempted = message.modelsAttempted, attempted.count > 1 {
                                    // Multiple models were tried (fallback occurred)
                                    HStack(spacing: 4) {
                                        ForEach(attempted, id: \.self) { model in
                                            if model == message.usedModel {
                                                // Final successful model
                                                Text(ModelRegistry.shortName(for: model))
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                // Failed model (strikethrough)
                                                Text(ModelRegistry.shortName(for: model))
                                                    .font(.system(size: 9))
                                                    .strikethrough()
                                                    .foregroundStyle(.tertiary)
                                            }
                                            if model != attempted.last {
                                                Text("→")
                                                    .font(.system(size: 8))
                                                    .foregroundStyle(.quaternary)
                                            }
                                        }
                                    }
                                } else if let model = message.usedModel {
                                    // Single model used
                                    Text(ModelRegistry.shortName(for: model))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button(action: {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(message.content, forType: .string)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() }
                                    else { NSCursor.pop() }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                }
            }
            if message.role != "user" { Spacer() }
        }
    }
    
    func isToolCall(_ content: String) -> Bool {
        return content.trimmingCharacters(in: .whitespacesAndNewlines).starts(with: "{") && content.contains("\"tool\":")
    }
}

// MARK: - Markdown Helpers
struct MarkdownView: View {
    let content: String
    
    var body: some View {
        let components = parseMarkdown(content)
        
        VStack(alignment: .leading, spacing: 8) {
            ForEach(components.indices, id: \.self) { index in
                let component = components[index]
                switch component.type {
                case .heading(let level):
                    headingView(text: component.text, level: level)
                case .text:
                    // Use AttributedString for robust markdown parsing
                    if let attributed = try? AttributedString(markdown: component.text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        // Fallback if parsing fails
                        Text(component.text)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                case .bullet:
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        if let attributed = try? AttributedString(markdown: component.text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(attributed)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } else {
                            Text(component.text)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                case .code(let lang):
                    CodeBlockView(language: lang, code: component.text)
                }
            }
        }
    }
    
    @ViewBuilder
    func headingView(text: String, level: Int) -> some View {
        let sizes: [CGFloat] = [28, 24, 20, 17, 15, 13] // h1 - h6
        let size = level <= sizes.count ? sizes[level - 1] : 13
        
        Text(text)
            .font(.system(size: size, weight: level <= 2 ? .bold : .semibold))
            .foregroundStyle(Color.primary)
            .padding(.top, level <= 2 ? 8 : 4)
            .textSelection(.enabled)
    }
    
    struct MDComponent {
        enum Kind {
            case heading(Int) // level 1-6
            case text
            case bullet
            case code(String?)
        }
        let type: Kind
        let text: String
    }
    
    func parseMarkdown(_ text: String) -> [MDComponent] {
        var components: [MDComponent] = []
        let parts = text.components(separatedBy: "```")
        
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 {
                // Regular text - parse line by line for headings and bullets
                let lines = part.components(separatedBy: "\n")
                var textBuffer = ""
                
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    
                    // Check for heading (# at start)
                    if trimmed.hasPrefix("#") {
                        // Flush text buffer
                        if !textBuffer.isEmpty {
                            components.append(.init(type: .text, text: textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)))
                            textBuffer = ""
                        }
                        
                        // Count heading level
                        var level = 0
                        for char in trimmed {
                            if char == "#" { level += 1 } else { break }
                        }
                        level = min(level, 6)
                        
                        let headingText = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                        if !headingText.isEmpty {
                            components.append(.init(type: .heading(level), text: headingText))
                        }
                    }
                    // Check for bullet
                    else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                        // Flush text buffer
                        if !textBuffer.isEmpty {
                            components.append(.init(type: .text, text: textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)))
                            textBuffer = ""
                        }
                        
                        let bulletText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        components.append(.init(type: .bullet, text: bulletText))
                    }
                    // Regular text line
                    else {
                        textBuffer += line + "\n"
                    }
                }
                
                // Flush remaining text
                if !textBuffer.isEmpty {
                    components.append(.init(type: .text, text: textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } else {
                // Code block
                let lines = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let lang = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = lines.count > 1 ? String(lines[1]) : ""
                components.append(.init(type: .code(lang), text: code))
            }
        }
        return components
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with language and copy button
            HStack {
                // Language badge
                if let lang = language, !lang.isEmpty {
                    HStack(spacing: 4) {
                        languageIcon(for: lang)
                        Text(lang.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("CODE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Copy button with feedback
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        if copied {
                            Text("Copied!")
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.4))

            // Syntax-highlighted code
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                SyntaxHighlightedText(code: code, language: language ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 400) // Limit height for long code blocks
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.12)) // Dark code background
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    func languageIcon(for lang: String) -> some View {
        let lowered = lang.lowercased()
        switch lowered {
        case "swift":
            Image(systemName: "swift")
        case "python", "py":
            Image(systemName: "curlybraces")
        case "javascript", "js", "typescript", "ts":
            Image(systemName: "j.square")
        case "rust":
            Image(systemName: "gearshape.2")
        case "go", "golang":
            Image(systemName: "g.square")
        case "bash", "sh", "zsh", "shell":
            Image(systemName: "terminal")
        case "json":
            Image(systemName: "curlybraces.square")
        case "html", "xml":
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        case "css", "scss", "sass":
            Image(systemName: "paintpalette")
        default:
            Image(systemName: "doc.text")
        }
    }
}

/// Basic syntax highlighting for common patterns
struct SyntaxHighlightedText: View {
    let code: String
    let language: String

    var body: some View {
        Text(highlightedCode)
    }

    var highlightedCode: AttributedString {
        var result = AttributedString(code)

        let lang = language.lowercased()

        // Define color scheme
        let keywordColor = Color(red: 0.7, green: 0.4, blue: 0.9)      // Purple for keywords
        let stringColor = Color(red: 0.9, green: 0.5, blue: 0.4)       // Orange for strings
        let commentColor = Color(red: 0.5, green: 0.5, blue: 0.5)      // Gray for comments
        let numberColor = Color(red: 0.6, green: 0.8, blue: 0.9)       // Cyan for numbers

        // Language-specific keywords
        let keywords: [String]
        switch lang {
        case "swift":
            keywords = ["func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case", "switch", "guard", "private", "public", "internal", "static", "self", "Self", "nil", "true", "false", "async", "await", "try", "catch", "throws", "throw", "@State", "@Binding", "@Published", "@ObservedObject", "@StateObject", "@Environment", "some", "any", "where", "extension", "protocol", "init", "deinit", "override", "final", "lazy", "weak", "unowned", "mutating", "inout"]
        case "python", "py":
            keywords = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "with", "lambda", "yield", "async", "await", "pass", "break", "continue", "None", "True", "False", "and", "or", "not", "in", "is", "self", "global", "nonlocal", "raise", "assert"]
        case "javascript", "js", "typescript", "ts":
            keywords = ["function", "const", "let", "var", "if", "else", "for", "while", "return", "import", "export", "from", "class", "extends", "new", "this", "async", "await", "try", "catch", "throw", "null", "undefined", "true", "false", "typeof", "instanceof", "default", "switch", "case", "break", "continue", "interface", "type", "enum", "public", "private", "protected", "static", "readonly", "abstract", "implements"]
        case "rust":
            keywords = ["fn", "let", "mut", "if", "else", "for", "while", "loop", "return", "use", "mod", "pub", "struct", "enum", "impl", "trait", "match", "self", "Self", "Some", "None", "Ok", "Err", "true", "false", "async", "await", "unsafe", "where", "const", "static", "type", "move", "ref", "dyn", "box", "extern", "crate", "super"]
        case "go", "golang":
            keywords = ["func", "var", "const", "if", "else", "for", "range", "return", "import", "package", "struct", "interface", "map", "chan", "go", "defer", "select", "case", "switch", "break", "continue", "nil", "true", "false", "type", "make", "new", "append", "len", "cap", "error"]
        case "bash", "sh", "zsh", "shell":
            keywords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "exit", "export", "local", "echo", "read", "cd", "pwd", "ls", "mkdir", "rm", "cp", "mv", "cat", "grep", "awk", "sed", "chmod", "chown", "sudo", "source", "true", "false"]
        default:
            keywords = ["function", "const", "let", "var", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "true", "false", "null", "nil", "self", "this"]
        }

        // Apply keyword highlighting
        for keyword in keywords {
            let pattern = "\\b\(keyword)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsRange = NSRange(code.startIndex..., in: code)
                for match in regex.matches(in: code, options: [], range: nsRange) {
                    if let range = Range(match.range, in: code),
                       let attrRange = Range(range, in: result) {
                        result[attrRange].foregroundColor = keywordColor
                    }
                }
            }
        }

        // Highlight strings (double and single quotes)
        highlightPattern("\"[^\"\\\\]*(\\\\.[^\"\\\\]*)*\"", in: &result, with: stringColor)
        highlightPattern("'[^'\\\\]*(\\\\.[^'\\\\]*)*'", in: &result, with: stringColor)

        // Highlight comments (// and #)
        highlightPattern("//.*$", in: &result, with: commentColor, options: .anchorsMatchLines)
        highlightPattern("#.*$", in: &result, with: commentColor, options: .anchorsMatchLines)

        // Highlight numbers
        highlightPattern("\\b\\d+(\\.\\d+)?\\b", in: &result, with: numberColor)

        return result
    }

    func highlightPattern(_ pattern: String, in result: inout AttributedString, with color: Color, options: NSRegularExpression.Options = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let nsRange = NSRange(code.startIndex..., in: code)
        for match in regex.matches(in: code, options: [], range: nsRange) {
            if let range = Range(match.range, in: code),
               let attrRange = Range(range, in: result) {
                result[attrRange].foregroundColor = color
            }
        }
    }
}

struct ToolCallBadge: View {
    let content: String
    @State private var isHovering = false
    
    var body: some View {
        let toolName = extractToolName(from: content)
        let command = extractCommand(from: content)
        
        HStack(spacing: 6) {
            // Icon only (always visible)
            Image(systemName: toolIcon(for: toolName))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            
            // Tool name (shows on hover or always for non-terminal)
            if isHovering || toolName != "Terminal" {
                Text(toolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            // Command (inline, subtle)
            if let cmd = command {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(cmd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(isHovering ? 0.06 : 0.03))
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
    
    func toolIcon(for name: String) -> String {
        switch name {
        case "Read File": return "doc.text"
        case "Write File": return "square.and.pencil"
        case "Fetch Web": return "globe"
        case "Terminal": return "terminal"
        default: return "wrench.and.screwdriver"
        }
    }
    
    func extractToolName(from content: String) -> String {
        if content.contains("read_file") { return "Read File" }
        if content.contains("write_file") { return "Write File" }
        if content.contains("fetch_web") { return "Fetch Web" }
        if content.contains("terminal") { return "Terminal" }
        return "System"
    }
    
    func extractCommand(from content: String) -> String? {
        if let range = content.range(of: "\"command\": \"") {
            let suffix = content[range.upperBound...]
            if let end = suffix.range(of: "\"") {
                let cmd = String(suffix[..<end.lowerBound])
                // Truncate long commands
                return cmd.count > 40 ? String(cmd.prefix(40)) + "..." : cmd
            }
        }
        if let range = content.range(of: "\"path\": \"") {
            let suffix = content[range.upperBound...]
            if let end = suffix.range(of: "\"") {
                return String(suffix[..<end.lowerBound])
            }
        }
        // Fetch Web url
        if let range = content.range(of: "\"url\": \"") {
             let suffix = content[range.upperBound...]
             if let end = suffix.range(of: "\"") {
                 return String(suffix[..<end.lowerBound])
             }
         }
        return nil
    }
}

// MARK: - Tool Execution Badge

struct AgentActivityFeedView: View {
    let lines: [AgentActivityLine]
    var isLive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                let isLast = index == lines.count - 1
                let showSpinner = isLive && isLast && line.isInProgress
                HStack(alignment: .center, spacing: 8) {
                    Group {
                        if showSpinner {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: line.isInProgress ? line.icon : "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(line.isInProgress ? Color.accentColor : Color.green)
                        }
                    }
                    .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.title)
                            .font(.system(size: 12, weight: .medium))
                        if let detail = line.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.top, 4)
    }
}

struct ToolExecutionBadge: View {
    let action: String
    let output: String?
    @State private var isExpanded = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Compact action display
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green.opacity(0.8))

                Text("Executed:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(action)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)

                // Show expand button if there's output
                if let output = output, !output.isEmpty, shouldShowOutput(output) {
                    Spacer()
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(colorScheme == .dark ? 0.08 : 0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
            )

            // Expandable output section
            if isExpanded, let output = output, !output.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.7))
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }

    // Only show output for complex operations or errors
    func shouldShowOutput(_ output: String) -> Bool {
        // Always show if there's an error
        if output.contains("Error:") || output.contains("error:") ||
           output.contains("Failed") || output.contains("failed") ||
           output.contains("🛡️ Safety Mode Blocked") {
            return true
        }

        // Show if output is substantial (more than just "success")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 50 || trimmed.contains("\n")
    }
}

// MARK: - Context Window Indicator

struct ContextWindowIndicator: View {
    let tokens: Int
    let usage: Double
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let sessionCost: Double
    let totalCost: Double
    @State private var isHovering = false
    
    var body: some View {
        let maxTokens = ModelRegistry.contextWindow(for: model)
        let percentage = String(format: "%.1f", usage * 100)
        
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 3)
                .frame(width: 28, height: 28)
            
            // Progress circle
            Circle()
                .trim(from: 0, to: min(usage, 1.0))
                .stroke(usageColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 28, height: 28)
                .rotationEffect(.degrees(-90))
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $isHovering, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                // Context Window Section
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(usageColor)
                    Text("Context Window")
                        .fontWeight(.semibold)
                }
                
                HStack {
                    Text("Used:")
                    Spacer()
                    Text("\(formatTokens(tokens)) / \(formatTokens(maxTokens)) (\(percentage)%)")
                        .fontWeight(.medium)
                }
                
                Divider()
                
                // Token Breakdown
                HStack {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.blue)
                    Text("Input:")
                    Spacer()
                    Text("\(formatTokens(inputTokens))")
                }
                
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.green)
                    Text("Output:")
                    Spacer()
                    Text("\(formatTokens(outputTokens))")
                }
                
                Divider()
                
                // Cost Section
                HStack {
                    Image(systemName: "dollarsign.circle")
                        .foregroundStyle(.orange)
                    Text("Session Cost:")
                    Spacer()
                    Text("$\(String(format: "%.4f", sessionCost))")
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Total Cost:")
                    Spacer()
                    Text("$\(String(format: "%.4f", totalCost))")
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
                
                Divider()
                
                // Model
                HStack {
                    Text("Model:")
                    Spacer()
                    Text(ModelRegistry.shortName(for: model))
                        .foregroundStyle(.secondary)
                    if ModelRegistry.isReasoning(model) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.purple)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(12)
            .frame(width: 220)
        }
    }
    
    var usageColor: Color {
        if usage < 0.5 {
            return .green
        } else if usage < 0.8 {
            return .yellow
        } else {
            return .red
        }
    }
    
    func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

// MARK: - Subcomponents

struct LockedView: View {
    @Binding var apiKey: String
    var onUnlock: () -> Void
    
    var body: some View {
        GrokBuildOnboardingView(
            authManager: GrokBuildAuthManager.shared,
            apiKey: $apiKey,
            onUnlock: onUnlock
        )
    }
}

// MARK: - Grok Build onboarding (CLI OAuth primary)

struct GrokBuildOnboardingView: View {
    @ObservedObject var authManager: GrokBuildAuthManager
    @Binding var apiKey: String
    var onUnlock: () -> Void
    @State private var showingAPIKey = false
    
    var body: some View {
        VStack(spacing: 28) {
            GrokLogoView(size: 48)
            
            VStack(spacing: 8) {
                Text("Sign in to Grok Build")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Use the same login as the Grok CLI and VS Code extension — Super Heavy access, no API key required.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            
            VStack(spacing: 12) {
                Button {
                    authManager.launchCLILogin()
                } label: {
                    Label("Sign in with Grok CLI", systemImage: "terminal")
                        .font(.headline)
                        .frame(minWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                
                Button {
                    if authManager.importFromGrokBuildCLI() {
                        onUnlock()
                    }
                } label: {
                    Label("Continue with Grok Build", systemImage: "arrow.right.circle.fill")
                        .frame(minWidth: 280)
                }
                .buttonStyle(.bordered)
                .disabled(!authManager.hasCLISessionOnDisk)
            }
            
            if let error = authManager.lastAuthError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            Divider().frame(width: 220)
            
            Button("Use API key instead (console.x.ai)") {
                showingAPIKey = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            
            Text("Recommended: `grok login` writes to ~/.grok/auth.json — same file this app reads.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .sheet(isPresented: $showingAPIKey) {
            GrokBuildAPIKeySheet(apiKey: $apiKey, onSave: {
                showingAPIKey = false
                onUnlock()
            })
        }
    }
}

struct GrokBuildAPIKeySheet: View {
    @Binding var apiKey: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("API Key (fallback)")
                .font(.title2.bold())
            Text("Use a key from console.x.ai if you prefer not to use Grok Build OAuth.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            SecureField("xai-...", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save & Continue") {
                    if !apiKey.isEmpty {
                        KeychainHelper.shared.saveAPIKey(apiKey)
                        GrokBuildAuthManager.shared.signOut()
                        onSave()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Grok Build Continue Prompt (Primary seamless path)

struct GrokBuildContinuePrompt: View {
    var session: GrokBuildSession
    var onContinue: () -> Void
    var fallbackAPIKeyPrompt: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            GrokLogoView(size: 56)
            
            VStack(spacing: 8) {
                Text("Grok Build Login Found")
                    .font(.title)
                    .fontWeight(.bold)
                
                if let email = session.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                if session.isSuperHeavy {
                    Text("Super Heavy (Tier 5)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .cornerRadius(6)
                }
                
                Text("Continue with your existing Grok CLI login for full Grok Build access.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            
            Button(action: onContinue) {
                Label("Continue with Grok Build", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            
            Divider()
                .frame(width: 200)
            
            VStack(spacing: 6) {
                Text("Or use an API key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Button("Enter API Key (console.x.ai)") {
                    fallbackAPIKeyPrompt()
                }
                .buttonStyle(.bordered)
            }
            
            Text("Grok Build OAuth = Super Heavy limits • API Key = standard limits")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}


struct HeroView: View {
    let workingDirectory: URL
    var onSelectDirectory: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            GrokLogoView(size: 60, opacity: 0.4)
            
            VStack(spacing: 8) {
                Text("Grok Build")
                    .font(.title)
                    .fontWeight(.bold)
                Text("AI Developer Agent")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 16) {
                Button(action: onSelectDirectory) {
                    HStack {
                        Image(systemName: "folder")
                        Text(workingDirectory.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Select Working Directory" : workingDirectory.lastPathComponent)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                Text("Select a directory to give the AI access to read/write files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}





// MARK: - Legacy / Helper Components

struct ActionChip: View {
    let label: String
    let icon: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(isHovering ? 0.1 : 0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(isHovering ? 0.2 : 0.1), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

struct ConsoleWebView: View {
    var onBack: () -> Void

    // Static URL constant - guaranteed valid at compile time
    private static let consoleURL = URL(string: "https://console.x.ai/home")!

    var body: some View {
        ZStack(alignment: .topLeading) {
            WebView(url: Self.consoleURL)
                .ignoresSafeArea()
            // Removed Back button as requested
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct WebView: NSViewRepresentable {
    let url: URL
    
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
}

// MARK: - Custom TextEditor with Enter Key Handling
struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onTextChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        // Configure text view
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        // Add text container insets to match placeholder padding (reduced to 6 for better centering)
        textView.textContainerInset = NSSize(width: 0, height: 6)

        // Configure scroll view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChange()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle Enter key (without Shift)
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Check if Shift is pressed
                if NSEvent.modifierFlags.contains(.shift) {
                    // Shift+Enter: insert newline (default behavior)
                    return false
                } else {
                    // Enter alone: submit
                    parent.onSubmit()
                    return true // Consume the event
                }
            }
            return false
        }
    }
}
