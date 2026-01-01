import SwiftUI
import WebKit

// MARK: - Feature Flags
// Set to true to enable voice input feature (currently disabled for release due to duplicate transcription bug)
private let VOICE_INPUT_ENABLED = false

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
enum SidebarTab: String, CaseIterable {
    case files = "Files"
    case chats = "Chats"
    case git = "Source Control"

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

    /// Returns the display name for a model - uses actual API model ID for clarity
    static func friendlyName(for id: String) -> String {
        // Use the actual API model ID as the display name to avoid confusion
        // This ensures each model is uniquely identifiable
        return id
    }

    /// Short name for compact UI (input area)
    static func shortName(for id: String) -> String {
        // Exact matches first (highest priority)
        if id == "grok-code-fast-1" { return "⚡ Code" }
        if id == "grok-2-vision-1212" { return "👁️ Vision" }
        if id == "grok-2-image-1212" { return "👁️ Vision" }
        if id == "grok-2-1212" { return "Grok 2" }
        if id == "grok-3-mini" { return "3 Mini" }
        if id == "grok-beta" { return "Beta" }

        // Grok 4.1 Fast Series (must check BEFORE generic 4-fast)
        if id.contains("4-1-fast") {
            if id.contains("non-reasoning") { return "4.1 ⚡" }
            if id.contains("reasoning") { return "4.1 🧠" }
            return "4.1"
        }

        // Grok 4 Fast Series (check after 4-1)
        if id.contains("4-fast") && !id.contains("4-1") {
            if id.contains("non-reasoning") { return "4 ⚡" }
            if id.contains("reasoning") { return "4 🧠" }
            return "4 Fast"
        }

        // Grok 4 (non-fast variants)
        if id.contains("grok-4") && !id.contains("fast") { return "Grok 4 🧠" }

        // Grok 3 series
        if id.contains("grok-3") && !id.contains("mini") { return "Grok 3" }

        // Generic fallbacks
        if id.contains("vision") || id.contains("image") { return "Vision" }
        if id.contains("mini") { return "Mini" }

        // Final fallback: extract version number
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

        // Grok Code
        if m.contains("grok-code") {
            return (input: 0.50, output: 2.00) // Fast/cheap
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
        return id.contains("vision") || id.contains("image")
    }

    static func isFast(_ id: String) -> Bool {
        return id.contains("fast") || id.contains("mini")
    }

    static func isCodeSpecialized(_ id: String) -> Bool {
        return id.contains("code")
    }

    /// Returns true only for actual reasoning models (excludes non-reasoning, fast, mini, vision)
    static func isReasoning(_ id: String) -> Bool {
        let m = id.lowercased()
        // Explicitly NOT reasoning
        if m.contains("non-reasoning") { return false }
        if m.contains("fast") { return false }
        if m.contains("mini") { return false }
        if m.contains("vision") { return false }
        // Explicitly reasoning models
        if m.contains("reasoning") { return true }
        // Grok 4 (full) is reasoning
        if m.contains("grok-4") && !m.contains("fast") { return true }
        // Grok 3 (full, not mini) is reasoning
        if m.contains("grok-3") && !m.contains("mini") { return true }
        // Grok 2 (not vision) can do reasoning
        if m.contains("grok-2") && !m.contains("vision") { return true }
        return false
    }

    /// Returns a brief description of the model's capabilities
    static func modelDescription(for id: String) -> String {
        let m = id.lowercased()

        // Grok Code - Lightning fast for coding
        if m.contains("code") {
            return "⚡ Lightning fast for coding • 256k context"
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

        // LATEST xAI models (December 2025) - prioritize newest & fastest
        let knownGoodModels = [
            // Latest Grok 4.1 Fast models (NEW - November 2025)
            "grok-4-1-fast-reasoning",      // Latest fast + reasoning (2M context)
            "grok-4-1-fast-non-reasoning",  // Latest fast without reasoning (2M context)
            // Grok 4 Fast models
            "grok-4-fast-reasoning",        // Fast + reasoning (2M context)
            "grok-4-fast-non-reasoning",    // Fast without reasoning (2M context)
            // Specialized models
            "grok-code-fast-1",             // Lightning fast for coding (256k context)
            "grok-4",                       // Best overall model (256k context)
            // Vision model
            "grok-2-vision-1212",           // Vision model for images
            // Legacy fallbacks
            "grok-2-1212",                  // Legacy fallback
            "grok-beta"                     // Legacy fallback
        ]

        // Model preferences by task type - PRIORITIZE LATEST MODELS
        let visionModels = ["grok-2-vision-1212"]  // Only vision model available
        let codingModels = [
            "grok-code-fast-1",             // BEST for coding - lightning fast
            "grok-4-1-fast-reasoning",      // Latest fast with reasoning
            "grok-4-fast-reasoning",        // Fast with reasoning
            "grok-4",                       // Best overall
            "grok-2-1212"                   // Legacy fallback
        ]
        let reasoningModels = [
            "grok-4-1-fast-reasoning",      // Latest fast with reasoning
            "grok-4-fast-reasoning",        // Fast with reasoning
            "grok-4",                       // Best overall
            "grok-4-1-fast-non-reasoning",  // Latest fast
            "grok-2-1212"                   // Legacy fallback
        ]
        let defaultModels = [
            "grok-4-1-fast-non-reasoning",  // Latest fast (best balance)
            "grok-4-fast-non-reasoning",    // Fast
            "grok-4-1-fast-reasoning",      // Latest fast with reasoning
            "grok-4",                       // Best overall
            "grok-2-1212"                   // Legacy fallback
        ]

        // Analyze the task
        let analysis = analyzeTask(messageText: messageText, hasImage: hasImage, textLength: textLength)

        #if DEBUG
        print("🤖 Auto Model Selection:")
        print("   • User selected: \(selected)")
        print("   • Has image: \(hasImage)")
        print("   • Text length: \(textLength)")
        print("   • Available models: \(availableModels.count)")
        print("   📊 Task Analysis:")
        print("      • Coding: \(analysis.isCoding) (score: \(analysis.codingScore))")
        print("      • Reasoning: \(analysis.isReasoning) (score: \(analysis.reasoningScore))")
        print("      • Vision: \(analysis.isVision)")
        print("      • Complexity: \(analysis.complexity)")
        if !analysis.detectedKeywords.isEmpty {
            print("      • Keywords: \(analysis.detectedKeywords.prefix(5).joined(separator: ", "))")
        }
        #endif

        // Helper to find a valid model from preferences
        func findValidModel(preferring preferences: [String], reason: String) -> String {
            let safeModels = availableModels.isEmpty ? knownGoodModels : availableModels.filter { knownGoodModels.contains($0) }

            for model in preferences {
                if safeModels.contains(model) || availableModels.isEmpty {
                    #if DEBUG
                    print("   ✅ Selected '\(model)' for: \(reason)")
                    #endif
                    return model
                }
            }

            let fallback = safeModels.first ?? "grok-2-1212"
            #if DEBUG
            print("   ⚠️ Using fallback: \(fallback) (reason: \(reason))")
            #endif
            return fallback
        }

        // =====================================================
        // MANUAL MODEL SELECTION - ALWAYS RESPECT USER CHOICE
        // =====================================================
        if selected != "auto" {
            // If user manually selected a model, use it (with one exception: vision)

            // Only override for vision if the selected model can't handle images
            if hasImage && !supportsVision(selected) {
                #if DEBUG
                print("   ⚠️ User model '\(selected)' can't handle images, switching to vision model")
                #endif
                return findValidModel(preferring: visionModels, reason: "🖼️ image requires vision model")
            }

            // Use the user's selected model directly - even if not in known-good list
            // The API will return an error if it's invalid, which triggers fallback
            #if DEBUG
            print("   ✅ Using user-selected model: \(selected)")
            #endif
            return selected
        }

        // =====================================================
        // AUTO MODE LOGIC - Smart selection based on task
        // =====================================================

        // PRIORITY 1: Vision tasks (image attached)
        if analysis.isVision {
            return findValidModel(preferring: visionModels, reason: "🖼️ vision task (image attached)")
        }

        // PRIORITY 2: Coding tasks - use grok-code-fast-1
        if analysis.isCoding {
            return findValidModel(preferring: codingModels, reason: "💻 coding task (score: \(analysis.codingScore))")
        }

        // PRIORITY 3: Complex tasks (reasoning + long messages)
        if analysis.isReasoning || analysis.complexity == .complex || textLength > 1500 {
            return findValidModel(preferring: reasoningModels, reason: "🧠 reasoning/complex task")
        }

        // PRIORITY 4: Default - general tasks
        return findValidModel(preferring: defaultModels, reason: "💬 general query")
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

        // Grok Code (specialized for coding)
        if modelLower.contains("grok-code") {
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
        let dir = paths[0].appendingPathComponent("GrokCode/History")
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

// MARK: - Main View
struct DeveloperRootView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var apiKey: String = "" // Loaded from Keychain on appear
    @AppStorage("selected_model") private var selectedModel: String = "auto" // Default to Auto
    @AppStorage("chatRetentionDays") private var chatRetention: Int = 30 // 0 = Forever
    @AppStorage("safetyEnabled") private var safetyEnabled: Bool = true // Default: ON for safety

    // Feature Switch: Working Directory with Bookmark Persistence
    @AppStorage("workingDirectoryBookmark") private var workingDirectoryBookmark: Data?
    @State private var workingDirectory: URL = FileManager.default.temporaryDirectory // Safe default prevents prompt
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

    // Event Monitor (for cleanup)
    @State private var eventMonitor: Any?

    // Voice Input State
    @StateObject private var voiceManager = VoiceManager()
    @State private var isVoiceEnabled: Bool = false
    @State private var isInputAreaHovered: Bool = false  // For collapsible voice button
    @State private var isShowingMicrophonePermissionAlert: Bool = false

    // MARK: - Voice Mode Toggle (COMMENTED OUT FOR RELEASE)
    // Uncomment when ready to enable dual voice modes:
    // - Real-time Conversation Mode: Auto-send after transcription
    // - Speech-to-Text Mode: Manual send after transcription
    // @State private var isRealtimeVoiceMode: Bool = true  // Default to real-time mode

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

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            ZStack(alignment: .leading) {
                sidebarBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header (Logo + Toggle)
                    HStack {
                        if isSidebarExpanded {
                            Text("Grok Code")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.primary)
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
                        VStack(spacing: 0) {
                            // MARK: - Tab Bar
                            HStack(spacing: 0) {
                                ForEach(SidebarTab.allCases, id: \.self) { tab in
                                    Button(action: {
                                        // Update state immediately without animation wrapper
                                        selectedSidebarTab = tab
                                        if tab == .git {
                                            refreshGitChanges()
                                        }
                                    }) {
                                        VStack(spacing: 4) {
                                            Image(systemName: selectedSidebarTab == tab ? tab.selectedIcon : tab.icon)
                                                .font(.system(size: 16))
                                                .foregroundStyle(selectedSidebarTab == tab ? .primary : .secondary)

                                            // Badge for git changes
                                            if tab == .git && hasUncommittedChanges {
                                                Circle()
                                                    .fill(Color.orange)
                                                    .frame(width: 6, height: 6)
                                                    .offset(x: 8, y: -20)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle()) // Ensure entire area is tappable
                                    }
                                    .buttonStyle(.plain)
                                    .background(selectedSidebarTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .onHover { hovering in
                                        if hovering { NSCursor.pointingHand.push() }
                                        else { NSCursor.pop() }
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)

                            Divider()
                                .padding(.horizontal, 8)

                            // MARK: - Tab Content
                            Group {
                                switch selectedSidebarTab {
                                case .files:
                                    sidebarFilesTab
                                case .chats:
                                    sidebarChatsTab
                                case .git:
                                    sidebarGitTab
                                }
                            }
                            .frame(maxHeight: .infinity)

                            Spacer(minLength: 0)
                        }
                    } else {
                        // COLLAPSED TAB ICONS
                        VStack(spacing: 4) {
                            ForEach(SidebarTab.allCases, id: \.self) { tab in
                                Button(action: {
                                    // Update state immediately, let SwiftUI handle animation
                                    isSidebarExpanded = true
                                    selectedSidebarTab = tab
                                }) {
                                    ZStack {
                                        Image(systemName: tab.icon)
                                            .font(.system(size: 16))
                                            .foregroundStyle(selectedSidebarTab == tab ? .primary : .secondary)

                                        // Badge for git changes
                                        if tab == .git && hasUncommittedChanges {
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 6, height: 6)
                                                .offset(x: 8, y: -8)
                                        }
                                    }
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle()) // Ensure entire area is tappable
                                }
                                .buttonStyle(.plain)
                                .background(selectedSidebarTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                                .cornerRadius(6)
                                .help(tab.rawValue)
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() }
                                    else { NSCursor.pop() }
                                }
                            }

                            Divider()
                                .padding(.vertical, 8)

                            Button(action: createNewChat) {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .help("New Chat")
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

                        // Git Branch Indicator (if available)
                        if isSidebarExpanded, let branch = gitBranch {
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

                        // xAI Console
                        Button(action: { isShowingConsole = true }) {
                            HStack {
                                Image("xAILogo")
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                                if isSidebarExpanded {
                                    Text("Console")
                                        .font(.system(size: 14))
                                    Spacer()
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .help("xAI Console")
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() }
                            else { NSCursor.pop() }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(width: isSidebarExpanded ? 240 : 60)
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

                if isShowingConsole {
                    ConsoleWebView(onBack: { isShowingConsole = false })
                        .transition(.move(edge: .bottom))
                } else if apiKey.isEmpty {
                    LockedView(apiKey: $apiKey, onUnlock: fetchModels)
                } else if sessions.isEmpty && messages.isEmpty {
                    // Logic handled in ChatInterface for visual consistency,
                    // or we can use HeroView logic if simpler.
                    // But we moved welcome logic to ChatInterface.
                    // Let's just go to ChatInterface.
                    ChatInterface
                } else {
                    ChatInterface
                }
            }
        }

        .onAppear {
            // Migrate API key from UserDefaults to Keychain (one-time)
            KeychainHelper.shared.migrateAPIKeyFromUserDefaults()

            // Load API key from Keychain
            apiKey = KeychainHelper.shared.getAPIKey() ?? ""

            if sessions.isEmpty {
                // Load from disk
                let loaded = PersistenceController.shared.load()
                // Apply Retention
                sessions = PersistenceController.shared.cleanOldSessions(days: chatRetention, sessions: loaded)
            }
            if sessions.isEmpty {
                createNewChat()
            }
            // Restore file access permissions
            restoreDirectoryAccess()
            refreshFileList()
            refreshGitStatus()

            // Load persisted total API cost
            totalCost = UserDefaults.standard.double(forKey: "totalApiCost")

            // Auto-refresh available models on load
            fetchModels()

            // Configure Voice Manager
            voiceManager.setAPIKey(apiKey)

            // Pre-connect to voice API for instant recording when user clicks mic
            // This eliminates the connection delay on first use
            if !apiKey.isEmpty && !voiceManager.isConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    voiceManager.connect()
                }
            }
        }
        .onDisappear {
            // Clean up file system monitoring
            stopFileSystemMonitoring()
        }
        .onChange(of: apiKey) { _, newValue in
            // Save API key to Keychain when it changes
            if newValue.isEmpty {
                KeychainHelper.shared.deleteAPIKey()
            } else {
                KeychainHelper.shared.saveAPIKey(newValue)
            }
            // Update voice manager with new API key
            voiceManager.setAPIKey(newValue)
        }
        // MARK: - Voice Transcription Handler
        // Observe transcriptionVersion to react only when a COMPLETE transcription arrives
        // This avoids issues with partial delta updates and ensures proper @State updates in SwiftUI
        .onChange(of: voiceManager.transcriptionVersion) { _, newVersion in
            #if DEBUG
            print("🔔 onChange TRIGGERED! transcriptionVersion changed to: \(newVersion)")
            print("   voiceManager.transcribedText: '\(voiceManager.transcribedText)'")
            #endif

            let newText = voiceManager.transcribedText
            guard !newText.isEmpty else {
                #if DEBUG
                print("   ⚠️ transcribedText is empty, skipping update")
                #endif
                return
            }

            #if DEBUG
            print("📝 Complete transcription received (version \(voiceManager.transcriptionVersion)): \(newText)")
            print("📝 Current inputMessage: '\(inputMessage)'")
            #endif

            // Append transcribed text to input message
            if inputMessage.isEmpty {
                inputMessage = newText
            } else {
                inputMessage += " " + newText
            }

            #if DEBUG
            print("📝 Updated inputMessage: '\(inputMessage)'")
            #endif

            // Update height with smooth animation
            withAnimation(.easeInOut(duration: 0.15)) {
                inputHeight = calculateInputHeight(for: inputMessage)
            }

            // MARK: - Voice Mode Auto-send (COMMENTED OUT FOR RELEASE)
            // Uncomment when ready to enable dual voice modes:
            /*
            // REAL-TIME MODE: Auto-send the message after a brief delay
            if isRealtimeVoiceMode {
                #if DEBUG
                print("🚀 Real-time mode: Auto-sending message in 0.3s...")
                #endif

                // Brief delay to show the transcribed text before sending
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !self.inputMessage.isEmpty {
                        #if DEBUG
                        print("🚀 Auto-sending: '\(self.inputMessage)'")
                        #endif
                        self.sendMessage()
                    }
                }
            } else {
                #if DEBUG
                print("✋ Speech-to-Text mode: Waiting for manual send")
                #endif
            }
            */
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
        .alert("Microphone Permission Needed", isPresented: $isShowingMicrophonePermissionAlert) {
            Button("Open System Settings") {
                voiceManager.openMicrophoneSettings()
                isShowingMicrophonePermissionAlert = false
                voiceManager.errorMessage = nil
            }
            Button("Cancel", role: .cancel) {
                isShowingMicrophonePermissionAlert = false
                voiceManager.errorMessage = nil
            }
        } message: {
            Text("Grok needs microphone access to use voice input.\n\n1. Click \"Open System Settings\"\n2. Enable the toggle for \"Grok\"\n3. Return to Grok and try again")
        }
        .onChange(of: voiceManager.errorMessage) { _, errorMessage in
            // Show alert when microphone permission is denied
            if let error = errorMessage, error.contains("Microphone permission") {
                isShowingMicrophonePermissionAlert = true
            }
        }
        // Re-check permission when app becomes active (user may have granted it externally)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            voiceManager.checkMicrophonePermission()
            // Close alert if permission is now granted
            if voiceManager.permissionStatus == .authorized {
                isShowingMicrophonePermissionAlert = false
                voiceManager.errorMessage = nil
            }
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
    }

    var ChatInterface: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                VStack(spacing: 24) {
                    Spacer()
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Color.primary.opacity(0.1))

                    VStack(spacing: 8) {
                        Text("Grok Code")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.2))

                        Text("Let's build something together.")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.primary.opacity(0.3))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(messages.filter { !$0.isHiddenFromUI }) { message in
                                MessageBubble(message: message, requestStatus: message.isThinking ? requestStatus : "")
                                    .id(message.id)
                            }
                            if isLoadingModels || isSending {
                                // ProgressView handled in bubbles or logic
                            }
                            Color.clear.frame(height: 1).id("BOTTOM")
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 20)
                    }
                    .onChange(of: messages) {
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
        VStack(alignment: .leading, spacing: 12) {
            // Insight Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ActionChip(label: "Create Project", icon: "hammer.fill", action: {
                        inputMessage = "Create a new project for..."
                        inputHeight = calculateInputHeight(for: inputMessage)
                    })
                    ActionChip(label: "Explain Code", icon: "doc.text.magnifyingglass", action: {
                        inputMessage = "Explain the code in..."
                        inputHeight = calculateInputHeight(for: inputMessage)
                    })
                    ActionChip(label: "Refactor", icon: "arrow.triangle.2.circlepath", action: {
                        inputMessage = "Refactor this file to..."
                        inputHeight = calculateInputHeight(for: inputMessage)
                    })
                    ActionChip(label: "Search Web", icon: "globe", action: {
                        inputMessage = "Search the web for..."
                        inputHeight = calculateInputHeight(for: inputMessage)
                    })
                }
                .padding(.horizontal, 2)
            }
            .padding(.bottom, 4)

            // Image Preview
            if let imgData = inputImage, let nsImage = NSImage(data: imgData) {
                HStack {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                        .cornerRadius(8)

                    Button(action: { inputImage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
                .padding(.leading, 4)
            }


            // Input Box - Clean & Minimalistic
            HStack(alignment: .center, spacing: 8) {  // Reduced spacing for cleaner look
                // Attachment Button
                Menu {
                    Button(action: pasteImage) {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    Button(action: takeScreenshot) {
                        Label("Take Screenshot", systemImage: "camera.viewfinder")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }


                // Custom TextEditor with dynamic height
                ZStack(alignment: .topLeading) {
                    // Placeholder text
                    if inputMessage.isEmpty {
                        Text("What do you want to build?")
                            .font(.system(size: 16))
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }

                    // MARK: - Voice Mode Indicator (COMMENTED OUT FOR RELEASE)
                    // Uncomment when ready to enable dual voice modes:
                    /*
                    if inputMessage.isEmpty {
                        HStack(spacing: 6) {
                            Text("What do you want to build?")
                                .font(.system(size: 16))
                                .foregroundColor(Color(nsColor: .placeholderTextColor))

                            // Voice mode indicator (subtle)
                            if isInputAreaHovered {
                                HStack(spacing: 3) {
                                    Image(systemName: isRealtimeVoiceMode ? "bolt.fill" : "text.bubble")
                                        .font(.system(size: 9))
                                        .foregroundStyle(isRealtimeVoiceMode ? .blue.opacity(0.6) : .secondary.opacity(0.5))

                                    Text(isRealtimeVoiceMode ? "Real-time" : "Speech-to-Text")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary.opacity(0.5))
                                }
                                .transition(.opacity)
                            }
                        }
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                    }
                    */

                    // TextEditor with custom key handling
                    CustomTextEditor(
                        text: $inputMessage,
                        onSubmit: { sendMessage() },
                        onTextChange: {
                            ensureCurrentChatExists()
                            // Update height based on content with animation
                            withAnimation(.easeInOut(duration: 0.15)) {
                                inputHeight = calculateInputHeight(for: inputMessage)
                            }
                        }
                    )
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: inputHeight)
                }
                .animation(.easeInOut(duration: 0.15), value: inputHeight)

                // Model Selector
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
                            Text("Automatically selects the best model")
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
                     HStack(spacing: 4) {
                         if selectedModel == "auto" {
                             // Show "Auto" with sparkles icon
                             Image(systemName: "sparkles")
                                 .font(.system(size: 10))
                                 .foregroundStyle(.orange)
                             Text("Auto")
                                 .fontWeight(.medium)
                                 .foregroundStyle(.secondary)
                         } else {
                             // Show capability icons for selected model
                             HStack(spacing: 3) {
                                 if ModelRegistry.supportsVision(selectedModel) {
                                     Image(systemName: "eye.fill")
                                         .font(.system(size: 9))
                                         .foregroundStyle(.blue)
                                 }
                                 if ModelRegistry.isReasoning(selectedModel) {
                                     Image(systemName: "brain.head.profile")
                                         .font(.system(size: 9))
                                         .foregroundStyle(.purple)
                                 }
                                 if ModelRegistry.isFast(selectedModel) {
                                     Image(systemName: "bolt.fill")
                                         .font(.system(size: 9))
                                         .foregroundStyle(.yellow)
                                 }
                                 if ModelRegistry.isCodeSpecialized(selectedModel) {
                                     Image(systemName: "chevron.left.forwardslash.chevron.right")
                                         .font(.system(size: 9))
                                         .foregroundStyle(.green)
                                 }
                             }
                             Text(ModelRegistry.shortName(for: selectedModel))
                                 .foregroundStyle(.secondary)
                         }

                         // Warning if capabilities mismatch (Manual mode only)
                         if inputImage != nil && selectedModel != "auto" && !ModelRegistry.supportsVision(selectedModel) {
                             Image(systemName: "exclamationmark.triangle.fill")
                                 .font(.system(size: 10))
                                 .foregroundStyle(.orange)
                                 .help("Selected model does not support images. Auto-switch will override.")
                         }
                     }
                     .font(.caption)
                 }
                 .menuStyle(.borderlessButton)
                 .fixedSize()
                 .onHover { hovering in
                     if hovering { NSCursor.pointingHand.push() }
                     else { NSCursor.pop() }
                 }

                // MARK: - Voice Input Button (DISABLED - see VOICE_INPUT_ENABLED flag)
                // Voice input is disabled for this release due to duplicate transcription bug.
                // To re-enable: Set VOICE_INPUT_ENABLED = true at top of file
                if VOICE_INPUT_ENABLED {
                    // Voice Input Button - Clean & Minimalistic
                    // Only visible when: hovering input area, recording, or processing
                    if isInputAreaHovered || voiceManager.isRecording || voiceManager.isProcessing || voiceManager.isConnecting {
                        HStack(spacing: 4) {
                            // Voice Recording Button (Speech-to-Text only - no mode toggle for this release)
                            Button(action: {
                                voiceManager.toggleRecording()
                            }) {
                                ZStack {
                                    // Background circle: red when recording, orange when connecting/processing
                                    Circle()
                                        .fill(voiceManager.isRecording ? Color.red :
                                              (voiceManager.isConnecting || voiceManager.isProcessing) ? Color.orange :
                                              Color.primary.opacity(0.08))
                                        .frame(width: 28, height: 28)

                                    // Mic icon
                                    Image(systemName: voiceManager.isRecording ? "mic.fill" :
                                                     voiceManager.isConnecting ? "antenna.radiowaves.left.and.right" :
                                                     voiceManager.isProcessing ? "waveform" : "mic")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(voiceManager.isRecording || voiceManager.isConnecting || voiceManager.isProcessing ? .white : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(voiceManager.isConnecting || voiceManager.isProcessing)
                            .help(voiceManager.isConnecting ? "Connecting to voice API..." :
                                  voiceManager.isProcessing ? "Processing transcription..." :
                                  voiceManager.isRecording ? "Stop Voice Input" : "Start Voice Input (⌘M)")
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            // Subtle pulse animation when recording
                            .overlay {
                                if voiceManager.isRecording {
                                    Circle()
                                        .stroke(Color.red.opacity(0.3), lineWidth: 1.5)
                                        .frame(width: 34, height: 34)
                                        .scaleEffect(1.1)
                                        .opacity(0.8)
                                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: voiceManager.isRecording)
                                }
                            }

                            // Minimal Waveform Visualization (only when recording)
                            if voiceManager.isRecording {
                                MinimalWaveformView(audioLevel: voiceManager.audioLevel)
                                    .frame(width: 30, height: 16)
                                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            }
                        }
                        // Fade in/out animation for entire voice controls
                        .opacity(isInputAreaHovered || voiceManager.isRecording || voiceManager.isProcessing || voiceManager.isConnecting ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.2), value: isInputAreaHovered)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }

                // MARK: - Voice Mode Toggle (COMMENTED OUT FOR RELEASE)
                // Uncomment when ready to enable dual voice modes:
                /*
                // Voice Mode Toggle Button (replaces the simple voice button above)
                if isInputAreaHovered || voiceManager.isRecording || voiceManager.isProcessing || voiceManager.isConnecting {
                    HStack(spacing: 4) {
                        // Voice Mode Toggle (Real-time vs Speech-to-Text)
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isRealtimeVoiceMode.toggle()
                            }
                        }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isRealtimeVoiceMode ? Color.blue.opacity(0.15) : Color.primary.opacity(0.05))
                                    .frame(width: 24, height: 24)
                                Image(systemName: isRealtimeVoiceMode ? "bolt.fill" : "text.bubble")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isRealtimeVoiceMode ? .blue : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(isRealtimeVoiceMode ? "Real-time Mode: Auto-send\nClick to switch to Speech-to-Text" : "Speech-to-Text Mode: Manual send\nClick to switch to Real-time")

                        // Divider
                        Rectangle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(width: 1, height: 16)

                        // Voice Recording Button with mode-aware tooltip
                        // ... (rest of voice button code)
                    }
                }
                */

                Button(action: {
                     if isSending {
                         stopGeneration()
                     } else {
                         sendMessage()
                     }
                 }) {
                     Image(systemName: isSending ? "stop.fill" : "arrow.up")
                         .font(.system(size: 16, weight: .bold))
                         .frame(width: 30, height: 30)
                         .background(isSending ? Color.red : Color.primary)
                         .clipShape(Circle())
                         .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                 }
                 .buttonStyle(.plain)
                 .disabled((inputMessage.isEmpty && inputImage == nil) && !isSending)
                 .onHover { hovering in
                     if hovering && (isSending || (!inputMessage.isEmpty || inputImage != nil)) {
                         NSCursor.pointingHand.push()
                     } else if !hovering {
                         NSCursor.pop()
                     }
                 }

                // Context Window Indicator (to the right of send button)
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
                    .padding(.leading, 8)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(30)
            .overlay(
                RoundedRectangle(cornerRadius: 30)
                   .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            // Only track hover for voice button visibility when voice is enabled
            .onHover { hovering in
                if VOICE_INPUT_ENABLED {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isInputAreaHovered = hovering
                    }
                }
            }
        }
        .frame(maxWidth: 700)
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

    /// Files tab content
    private var sidebarFilesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Working Directory Header
            Button(action: selectDirectory) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workingDirectoryBookmark == nil ? "Select Folder" : workingDirectory.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if workingDirectoryBookmark != nil {
                            Text(workingDirectory.path)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(action: refreshFileList) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.3))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }

            // File Tree
            ScrollView {
                if fileTree.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(workingDirectoryBookmark == nil ? "No folder selected" : "Empty directory")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if workingDirectoryBookmark == nil {
                            Text("Click above to select a folder")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
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
                }
            }
        }
    }

    /// Chats tab content
    private var sidebarChatsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with new chat button
            HStack {
                Text("Chat History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: createNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New Chat")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Chat Sessions List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sessions) { session in
                        Button(action: { switchChat(to: session.id) }) {
                            HStack(spacing: 8) {
                                Image(systemName: session.id == currentSessionId ? "bubble.left.fill" : "bubble.left")
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.id == currentSessionId ? .primary : .secondary)
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(session.messages.count) messages")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(session.id == currentSessionId ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() }
                            else { NSCursor.pop() }
                        }
                        .contextMenu {
                            Button("Rename") {
                                sessionToRename = session
                                newChatTitle = session.title
                                isShowingRenameAlert = true
                            }
                            Button("Delete", role: .destructive) {
                                sessionToDelete = session
                                isShowingDeleteConfirmation = true
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
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

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Initialize the repository
            let initResult = self.runGitCommand(["init"])

            #if DEBUG
            print("Git init result: \(initResult ?? "nil")")
            print("Working directory: \(self.workingDirectory.path)")
            #endif

            guard initResult != nil else {
                DispatchQueue.main.async {
                    self.isInitializingRepo = false
                }
                return
            }

            // Step 2: Configure default branch name to 'main'
            _ = self.runGitCommand(["config", "init.defaultBranch", "main"])

            // Step 3: Ensure we're on main branch
            _ = self.runGitCommand(["checkout", "-b", "main"])

            // Step 4: Create a .gitignore file if it doesn't exist
            let gitignorePath = self.workingDirectory.appendingPathComponent(".gitignore")
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
            _ = self.runGitCommand(["add", "."])

            // Step 6: Create initial commit
            let commitResult = self.runGitCommand(["commit", "-m", "Initial commit"])

            #if DEBUG
            print("Git commit result: \(commitResult ?? "nil")")
            #endif

            // Step 7: Refresh UI to show the new repository state
            // Get the branch name directly before switching to main thread
            let branch = self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"])
            let status = self.runGitCommand(["status", "--porcelain"])

            DispatchQueue.main.async {
                // Update git state directly
                self.gitBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.hasUncommittedChanges = !(status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                self.gitRepositoryPath = self.workingDirectory.path

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
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runGitCommand(["reset", "HEAD", "--", path])
            DispatchQueue.main.async {
                self.refreshGitChanges()
            }
        }
    }

    /// Switch to a different branch
    func switchBranch(to branchName: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runGitCommand(["checkout", branchName])

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

        // If text is empty, return minimum height
        if text.isEmpty {
            return minHeight
        }

        // Calculate the width available for text (approximate input field width)
        // Account for padding and other UI elements
        let availableWidth: CGFloat = 600 // Approximate width of text input area

        // Create attributed string with the same font as the TextEditor
        let font = NSFont.systemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attributedString = NSAttributedString(string: text, attributes: attributes)

        // Calculate bounding rect for the text with wrapping
        let boundingRect = attributedString.boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        // Add padding (top + bottom)
        let calculatedHeight = ceil(boundingRect.height) + 12

        // Clamp between min and max
        return min(max(calculatedHeight, minHeight), maxHeight)
    }

    // MARK: - Logic

    func createNewChat() {
        // Save current if needed
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx].messages = messages
        }

        let newSession = ChatSession(id: UUID(), title: "New Chat", messages: [], lastModified: Date())
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
        // Save current
        if let idx = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            sessions[idx].messages = messages
        }

        // Load new
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        currentSessionId = id
        messages = session.messages
        isShowingConsole = false // Exit console when switching chats

        // Reset context window counters for new session
        totalTokens = 0
        sessionCost = 0.0
        contextUsage = 0.0
        lastInputTokens = 0
        lastOutputTokens = 0
        currentModelUsed = nil
    }

    func deleteChat(_ session: ChatSession) {
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
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].title = newTitle
            PersistenceController.shared.save(sessions: sessions)
        }
    }

    func refreshFileList() {
        // If no bookmark, don't show anything (or show empty)
        if workingDirectoryBookmark == nil {
            fileTree = []
            return
        }

        // Simple 1-level listing for now to avoid freezing UI
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: workingDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            fileTree = urls.map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileSystemItem(name: url.lastPathComponent, url: url, isDirectory: isDir, children: nil)
            }.sorted { lhs, rhs in
                // Sort: directories first, then alphabetically
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

        guard workingDirectoryBookmark != nil else { return }

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

        // Run git commands asynchronously to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            let repoRoot = self.runGitCommand(["rev-parse", "--show-toplevel"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let workingPath = self.workingDirectory.path

            // Only show git status if the selected folder IS the git repository root
            // Don't show parent repo status when viewing a subfolder
            let isRepoRoot = (repoRoot == workingPath)

            if isRepoRoot {
                let branch = self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"])
                let status = self.runGitCommand(["status", "--porcelain"])
                let branchList = self.runGitCommand(["branch", "--format=%(refname:short)"])

                DispatchQueue.main.async {
                    self.gitBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.hasUncommittedChanges = !(status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    self.gitRepositoryPath = repoRoot

                    // Parse branch list
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
                // Selected folder is not a git repo root (either no repo, or a subfolder of a repo)
                DispatchQueue.main.async {
                    self.gitBranch = nil
                    self.gitBranches = []
                    self.hasUncommittedChanges = false
                    self.gitRepositoryPath = nil
                }
            }
        }
    }

    /// Run a git command in the working directory
    private func runGitCommand(_ arguments: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()

        task.launchPath = "/usr/bin/git"
        task.arguments = arguments
        task.currentDirectoryURL = workingDirectory
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            }
        } catch {
            #if DEBUG
            print("Git command failed: \(error)")
            #endif
        }

        return nil
    }

    /// Refresh the list of changed files in git
    func refreshGitChanges() {
        guard workingDirectoryBookmark != nil, gitBranch != nil else {
            gitChangedFiles = []
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Get status with porcelain format
            guard let status = self.runGitCommand(["status", "--porcelain"]) else {
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

                let url = self.workingDirectory.appendingPathComponent(filePath)
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
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runGitCommand(["add", path])
            DispatchQueue.main.async {
                self.refreshGitChanges()
            }
        }
    }

    /// Discard changes to a file
    func discardChanges(_ path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runGitCommand(["checkout", "--", path])
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
        commitMessage = "" // Clear immediately for UX

        DispatchQueue.global(qos: .userInitiated).async {
            if needsStageAll {
                // No staged files - stage all changes first
                _ = self.runGitCommand(["add", "-A"])
            }
            // Commit with message
            let commitResult = self.runGitCommand(["commit", "-m", message])

            #if DEBUG
            print("Commit result: \(commitResult ?? "nil")")
            #endif

            // Refresh git status directly on background thread
            let status = self.runGitCommand(["status", "--porcelain"])
            let branch = self.runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"])
            let branchList = self.runGitCommand(["branch", "--format=%(refname:short)"])

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
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder for Grok to focus on."

        if panel.runModal() == .OK {
            if let url = panel.url {
                saveBookmark(for: url)
                workingDirectory = url
                refreshFileList()
                refreshGitStatus()

                // Start monitoring the new directory
                startFileSystemMonitoring()
            }
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
            if url.startAccessingSecurityScopedResource() {
                workingDirectory = url

                // Start monitoring the restored directory
                startFileSystemMonitoring()
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

        guard let url = URL(string: "https://api.x.ai/v1/models") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
                    self.availableModels = decoded.data.map { $0.id }.sorted()

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
        messages.append(ChatMessage(id: assistantMsgId, role: "assistant", content: "", isThinking: true))

        // 3. Resolve Model (Smart Selection) - Check the user message's imageData, not inputImage (already cleared)
        // Pass availableModels and messageText to ensure smart model selection based on task type
        let modelToUse = ModelRegistry.resolveModel(
            selected: selectedModel,
            hasImage: newUserMsg.imageData != nil,
            textLength: userMsg.count,
            messageText: userMsg,
            availableModels: availableModels
        )

        // Set initial status
        requestStatus = "Connecting..."

        performAPICall(assistantMsgId: assistantMsgId, modelID: modelToUse)
    }

    func stopGeneration() {
        currentRequestId = nil  // Invalidate current request
        isSending = false
        requestStatus = ""
        requestStartTime = nil

        // Remove thinking message if present
        if let lastMsg = messages.last, lastMsg.isThinking {
            messages.removeLast()
        }
    }

    func performAPICall(assistantMsgId: UUID, modelID: String) {
        // Capture session ID at start to prevent race condition
        let sessionIdAtStart = self.currentSessionId

        // Create unique request ID for cancellation tracking
        let requestId = UUID()
        self.currentRequestId = requestId

        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

        // System Prompt with Tool Definition
        let toolsInstruction = """
        You are Grok, an expert developer with access to the macOS terminal and file system.
        Current Working Directory: \(workingDirectory.path)
        Safety Mode: \(safetyEnabled ? "ENABLED (Destructive commands blocked)" : "DISABLED")

        CAPABILITIES:
        1. TERMINAL: Run shell commands (ls, git, mkdir, etc).
        2. READ FILE: Read file contents natively.
        3. WRITE FILE: Write content to files natively.
        4. FETCH WEB: Fetch text content from a URL.
        5. SEARCH WEB: Search the web for information (DuckDuckGo).

        TOOL USE FORMAT (Output strictly valid JSON):

        For Terminal:
        ```json
        { "tool": "terminal", "command": "ls -la" }
        ```

        For Read File:
        ```json
        { "tool": "read_file", "path": "Sources/ContentView.swift" }
        ```

        For Write File:
        ```json
        { "tool": "write_file", "path": "README.md", "content": "# My Project" }
        ```

        For Fetch Web:
        ```json
        { "tool": "fetch_web", "url": "https://example.com" }
        ```

        For Search Web:
        ```json
        { "tool": "search_web", "query": "swiftui layout guide" }
        ```

        IMPORTANT:
        - Only return ONE tool call per message.
        - Wait for the "Tool Output" before proceeding.

        Output only the JSON block when using a tool.
        After you receive the tool output, analyze it and answer the user's question.
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
                    return
                }

                // Handle HTTP errors (after retries exhausted)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    let errorMsg = APIRetryHelper.parseErrorMessage(from: data, statusCode: httpResponse.statusCode)
                    var userFriendlyError = "API Error (\(httpResponse.statusCode))"

                    // Provide context for common errors
                    if httpResponse.statusCode == 401 {
                        userFriendlyError = "Authentication failed. Please check your API key in Settings."
                    } else if httpResponse.statusCode == 429 {
                        userFriendlyError = "Rate limit exceeded. Please wait a moment and try again."
                    } else if httpResponse.statusCode == 400 {
                        // Model might not be available - try fallback with latest models first
                        #if DEBUG
                        print("⚠️ 400 error with model '\(modelID)': \(errorMsg)")
                        print("   Available models: \(self.availableModels)")
                        #endif

                        // Fallback models in order of preference (latest first, then legacy)
                        let fallbackModels = [
                            "grok-4-1-fast-non-reasoning",  // Latest fast
                            "grok-4-fast-non-reasoning",    // Fast
                            "grok-code-fast-1",             // Coding fast
                            "grok-2-1212",                  // Legacy reliable
                            "grok-beta"                     // Legacy fallback
                        ]

                        // Try to find a working fallback model
                        for fallbackModel in fallbackModels {
                            if fallbackModel != modelID {
                                #if DEBUG
                                print("   🔄 Retrying with fallback model: \(fallbackModel)")
                                #endif
                                messages[index].content = ""
                                messages[index].isThinking = true
                                requestStatus = "Retrying..."
                                self.performAPICall(assistantMsgId: assistantMsgId, modelID: fallbackModel)
                                return
                            }
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
                    return
                }

                guard let data = data else {
                    messages[index].content = "❌ No data received from server"
                    messages[index].isThinking = false
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil
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

                    // CHECK FOR TOOLS
                    if content.contains("\"tool\":") {
                        // Parse JSON from content block
                        if let action = parseToolAction(from: content) {
                            messages[index].isThinking = false
                            messages[index].toolAction = action.description

                            // Update status for tool execution (simple, generic messages)
                            switch action {
                            case .terminal:
                                requestStatus = "Running command..."
                            case .readFile:
                                requestStatus = "Reading file..."
                            case .writeFile:
                                requestStatus = "Writing file..."
                            case .fetchWeb:
                                requestStatus = "Fetching..."
                            case .searchWeb:
                                requestStatus = "Searching..."
                            case .openURL:
                                requestStatus = "Opening..."
                            case .checkServerStatus:
                                requestStatus = "Checking..."
                            }

                            // 1. Run Action ASYNCHRONOUSLY to not block UI
                            executeToolActionAsync(action) { [self] output in
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
                                let nextId = UUID()
                                messages.append(ChatMessage(id: nextId, role: "assistant", content: "", isThinking: true))
                                performAPICall(assistantMsgId: nextId, modelID: modelID)
                            }
                            return
                        }
                    }

                    messages[index].isThinking = false
                    isSending = false
                    requestStatus = ""
                    requestStartTime = nil

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
                }
            }
        }
    }

    // MARK: - Tool Logic

    enum ToolAction {
        case terminal(String)
        case readFile(String)
        case writeFile(String, String)
        case fetchWeb(String)
        case searchWeb(String)
        case openURL(String)           // Open URL in browser (with localhost handling)
        case checkServerStatus(Int)    // Check if a port is responding

        // Human-readable description for UI display
        var description: String {
            switch self {
            case .terminal(let cmd):
                return cmd
            case .readFile(let path):
                return "Read \(path)"
            case .writeFile(let path, _):
                return "Write \(path)"
            case .fetchWeb(let url):
                return "Fetch \(url)"
            case .searchWeb(let query):
                return "Search: \(query)"
            case .openURL(let url):
                return "Open \(url)"
            case .checkServerStatus(let port):
                return "Check localhost:\(port)"
            }
        }
    }

    func parseToolAction(from text: String) -> ToolAction? {
        // Robust JSON extraction
        guard let startRange = text.range(of: "{"),
              let endRange = text.range(of: "}", options: .backwards) else { return nil }

        let jsonString = String(text[startRange.lowerBound..<endRange.upperBound])
        guard let data = jsonString.data(using: .utf8) else { return nil }

        struct ToolPayload: Decodable {
            let tool: String
            let command: String?
            let path: String?
            let content: String?
            let url: String?
            let query: String?
            let port: Int?
        }

        do {
            let payload = try JSONDecoder().decode(ToolPayload.self, from: data)
            switch payload.tool {
            case "terminal":
                if let cmd = payload.command { return .terminal(cmd) }
            case "read_file":
                if let path = payload.path { return .readFile(path) }
            case "write_file":
                if let path = payload.path, let content = payload.content { return .writeFile(path, content) }
            case "fetch_web":
                if let url = payload.url { return .fetchWeb(url) }
            case "search_web":
                if let query = payload.query { return .searchWeb(query) }
            case "open_url", "open_browser":
                if let url = payload.url { return .openURL(url) }
            case "check_server", "check_port":
                if let port = payload.port { return .checkServerStatus(port) }
            default:
                return nil
            }
        } catch {
            #if DEBUG
            print("Failed to decode tool JSON: \(error)")
            #endif
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

            // === ADDITIONAL BYPASS PROTECTION ===

            // Command substitution with dangerous commands (beyond rm)
            ("`sudo", "Command substitution with sudo is blocked"),
            ("$(sudo", "Command substitution with sudo is blocked"),
            ("`chmod", "Command substitution with chmod is blocked"),
            ("$(chmod", "Command substitution with chmod is blocked"),
            ("`dd", "Command substitution with dd is blocked"),
            ("$(dd", "Command substitution with dd is blocked"),

            // Base64-encoded payload execution
            ("base64 -d", "Base64 decoding (potential payload) is blocked"),
            ("base64 --decode", "Base64 decoding (potential payload) is blocked"),
            ("base64 -D", "Base64 decoding (potential payload) is blocked"),

            // Script interpreter execution with -c flag (inline code)
            ("python -c", "Python inline execution is blocked"),
            ("python3 -c", "Python3 inline execution is blocked"),
            ("perl -e", "Perl inline execution is blocked"),
            ("ruby -e", "Ruby inline execution is blocked"),

            // Shell eval/exec (arbitrary code execution)
            ("eval ", "Shell eval is blocked"),
            ("eval\t", "Shell eval is blocked"),
            ("exec ", "Shell exec is blocked"),
            (" eval ", "Shell eval is blocked"),

            // xargs with dangerous commands
            ("xargs rm", "xargs with rm is blocked"),
            ("xargs sudo", "xargs with sudo is blocked"),
            ("xargs chmod", "xargs with chmod is blocked"),

            // Download and execute patterns
            ("curl|sh", "Download and execute is blocked"),
            ("curl|bash", "Download and execute is blocked"),
            ("curl | sh", "Download and execute is blocked"),
            ("curl | bash", "Download and execute is blocked"),
            ("wget|sh", "Download and execute is blocked"),
            ("wget|bash", "Download and execute is blocked"),
            ("wget | sh", "Download and execute is blocked"),
            ("wget | bash", "Download and execute is blocked"),
            ("curl -s", "Silent curl (potential payload download) requires review"),

            // Reverse shell patterns
            ("/dev/tcp", "TCP device access (reverse shell) is blocked"),
            ("/dev/udp", "UDP device access is blocked"),
            ("bash -i", "Interactive bash (reverse shell) is blocked"),
            ("0>&1", "File descriptor redirection (reverse shell) is blocked"),

            // Environment manipulation
            ("export PATH=", "PATH manipulation is blocked"),
            ("export LD_", "Library path manipulation is blocked"),
            ("export DYLD_", "macOS library path manipulation is blocked"),

            // History manipulation (covering tracks)
            ("history -c", "History clearing is blocked"),
            ("history -w", "History manipulation is blocked"),
            ("unset HISTFILE", "History manipulation is blocked"),

            // SSH tunneling (data exfiltration)
            ("ssh -R", "SSH reverse tunneling is blocked"),
            ("ssh -L", "SSH local tunneling is blocked"),
            ("ssh -D", "SSH dynamic tunneling is blocked"),
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

                    // Note: For SwiftUI Views (structs), we can't use weak self.
                    // The @State property wrapper handles the reference semantics internally.
                    // We capture the Binding to runningProcesses for cleanup when the process terminates.
                    let processBinding = $runningProcesses
                    task.terminationHandler = { _ in
                        DispatchQueue.main.async {
                            processBinding.wrappedValue.removeValue(forKey: processId)
                            #if DEBUG
                            print("🧹 Cleaned up terminated process: \(processId)")
                            #endif
                        }
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

                // File system monitor will automatically detect and refresh the file list

                return "Successfully wrote to \(path)"
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }

        case .fetchWeb(let urlString):
             // Network fetch with timeout protection
             let semaphore = DispatchSemaphore(value: 0)
             var result = ""

             guard let url = URL(string: urlString) else { return "Invalid URL" }

             var request = URLRequest(url: url)
             request.timeoutInterval = 15.0  // Request-level timeout

             let task = URLSession.shared.dataTask(with: request) { data, response, error in
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

             // Wait with timeout to prevent indefinite blocking
             let waitResult = semaphore.wait(timeout: .now() + 20.0)
             if waitResult == .timedOut {
                 task.cancel()
                 return "⏱️ Request timed out after 20 seconds. The server may be slow or unresponsive."
             }
             return result.isEmpty ? "No content received" : result

        case .searchWeb(let query):
            let semaphore = DispatchSemaphore(value: 0)
            var result = ""

            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else { return "Invalid Query" }

            var request = URLRequest(url: url)
            request.timeoutInterval = 15.0  // Request-level timeout
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

            // Wait with timeout to prevent indefinite blocking
            let waitResult = semaphore.wait(timeout: .now() + 20.0)
            if waitResult == .timedOut {
                task.cancel()
                return "⏱️ Search timed out after 20 seconds. Please try again."
            }
            return result.isEmpty ? "No search results found" : result

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

        // Wait with timeout to prevent indefinite blocking
        let waitResult = semaphore.wait(timeout: .now() + 5.0)
        if waitResult == .timedOut {
            task.cancel()
            return "⏱️ Server check timed out. Port \(port) may not be responding."
        }
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
                                if !requestStatus.isEmpty {
                                    Text(requestStatus)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                        } else if isToolCall(message.content) {
                            // RENDER TOOL CALL
                            ToolCallBadge(content: message.content)
                        } else {
                            // Show tool execution badge if this message executed a tool
                            if let toolAction = message.toolAction {
                                ToolExecutionBadge(action: toolAction, output: message.toolOutput)
                            }

                            // RICH MARKDOWN CONTENT
                            if !message.content.isEmpty {
                                MarkdownView(content: message.content)
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
        VStack(spacing: 20) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Enter Grok API Key")
                .font(.title2)
                .bold()

            SecureField("xAI API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(onUnlock)

            Button("Unlock") {
                onUnlock()
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HeroView: View {
    let workingDirectory: URL
    var onSelectDirectory: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "terminal")
                .font(.system(size: 60))
                .foregroundStyle(.gray.opacity(0.3))

            VStack(spacing: 8) {
                Text("Grok Code")
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

        // Disable autocomplete and text completion to prevent keyboard sounds
        // when typing @ mentions or other special characters
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

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
            #if DEBUG
            print("🔄 CustomTextEditor.updateNSView: Updating text from '\(textView.string)' to '\(text)'")
            #endif

            // Temporarily disable delegate to prevent feedback loop
            let previousDelegate = textView.delegate
            textView.delegate = nil

            // Update the text
            textView.string = text

            // Move cursor to end of text
            let newPosition = (text as NSString).length
            textView.setSelectedRange(NSRange(location: newPosition, length: 0))

            // Scroll to show cursor
            textView.scrollRangeToVisible(NSRange(location: newPosition, length: 0))

            // Make sure the text view is first responder to show the text
            if !text.isEmpty {
                textView.window?.makeFirstResponder(textView)
                #if DEBUG
                print("🔄 CustomTextEditor: Made text view first responder")
                #endif
            }

            // Re-enable delegate
            textView.delegate = previousDelegate

            // Trigger the onTextChange callback to update height
            onTextChange()

            #if DEBUG
            print("🔄 CustomTextEditor: Update complete, text is now: '\(textView.string)'")
            #endif
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
            #if DEBUG
            print("[CustomTextEditor] doCommandBy: \(commandSelector)")
            #endif

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

            // Let standard text editing commands pass through
            let allowedCommands: Set<Selector> = [
                #selector(NSResponder.deleteBackward(_:)),
                #selector(NSResponder.deleteForward(_:)),
                #selector(NSResponder.moveLeft(_:)),
                #selector(NSResponder.moveRight(_:)),
                #selector(NSResponder.moveUp(_:)),
                #selector(NSResponder.moveDown(_:)),
                #selector(NSResponder.moveToBeginningOfLine(_:)),
                #selector(NSResponder.moveToEndOfLine(_:)),
                #selector(NSResponder.moveToBeginningOfDocument(_:)),
                #selector(NSResponder.moveToEndOfDocument(_:)),
                #selector(NSResponder.selectAll(_:)),
                #selector(NSResponder.insertTab(_:)),
                #selector(NSResponder.insertBacktab(_:)),
                NSSelectorFromString("deleteWordBackward:"),
                NSSelectorFromString("deleteWordForward:"),
            ]

            if allowedCommands.contains(commandSelector) {
                return false // Let the text view handle it normally
            }

            // Suppress system beep for all other commands (autocomplete, noop, etc.)
            // This prevents the beep when typing @ or other special characters
            return true
        }
    }
}


// MARK: - Waveform Visualization Component

/// Real-time audio waveform visualization for voice input
struct WaveformView: View {
    let audioLevel: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.easeInOut(duration: 0.1), value: audioLevel)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Create wave effect with different phases for each bar
        let phase = Double(index) * 0.3
        let baseHeight: CGFloat = 4
        let maxHeight: CGFloat = 20

        // Animate based on audio level with phase offset
        let animatedLevel = sin(Date().timeIntervalSince1970 * 3 + phase) * 0.5 + 0.5
        let combinedLevel = (CGFloat(audioLevel) * 0.7 + CGFloat(animatedLevel) * 0.3)

        return baseHeight + (maxHeight - baseHeight) * combinedLevel
    }
}

// MARK: - Minimal Waveform Visualization (Clean UI)

/// Minimal, subtle waveform visualization for clean UI
struct MinimalWaveformView: View {
    let audioLevel: Float
    private let barCount = 3  // Reduced from 5 for cleaner look

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red.opacity(0.6))  // More subtle opacity
                    .frame(width: 2, height: barHeight(for: index))
                    .animation(.easeInOut(duration: 0.15), value: audioLevel)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Create wave effect with different phases for each bar
        let phase = Double(index) * 0.4
        let baseHeight: CGFloat = 3
        let maxHeight: CGFloat = 14  // Shorter max height for subtlety

        // Slower, smoother animation
        let animatedLevel = sin(Date().timeIntervalSince1970 * 2.5 + phase) * 0.5 + 0.5
        let combinedLevel = (CGFloat(audioLevel) * 0.6 + CGFloat(animatedLevel) * 0.4)

        return baseHeight + (maxHeight - baseHeight) * combinedLevel
    }
}
