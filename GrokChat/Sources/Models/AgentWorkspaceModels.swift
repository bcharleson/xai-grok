import Foundation

// MARK: - Agent backend kinds (future: cursor_sdk, etc.)

enum AgentBackendKind: String, Codable, CaseIterable, Identifiable {
    case grokACP = "grok_acp"
    case cursorSDK = "cursor_sdk"
    case legacyAPI = "legacy_api"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grokACP: return "Grok CLI"
        case .cursorSDK: return "Cursor"
        case .legacyAPI: return "API"
        }
    }
}

// MARK: - Thread (conversation within a project)

struct AgentThread: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var lastModified: Date
    /// ACP session id from `grok agent stdio` after `session/new`
    var acpSessionId: String?
    /// Grok CLI session id for `grok -r` resume in embedded TUI
    var grokSessionId: String?
    var backend: AgentBackendKind
    /// Soft-hidden from the main project chat list (restorable).
    var isArchived: Bool
    /// Background session finished work while this thread was not selected.
    var hasUnreadReady: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Thread",
        messages: [ChatMessage] = [],
        lastModified: Date = Date(),
        acpSessionId: String? = nil,
        grokSessionId: String? = nil,
        backend: AgentBackendKind = .grokACP,
        isArchived: Bool = false,
        hasUnreadReady: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.lastModified = lastModified
        self.acpSessionId = acpSessionId
        self.grokSessionId = grokSessionId
        self.backend = backend
        self.isArchived = isArchived
        self.hasUnreadReady = hasUnreadReady
    }

    init(from session: ChatSession, backend: AgentBackendKind = .grokACP) {
        self.id = session.id
        self.title = session.title
        self.messages = session.messages
        self.lastModified = session.lastModified
        self.acpSessionId = nil
        self.grokSessionId = nil
        self.backend = backend
        self.isArchived = false
        self.hasUnreadReady = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, lastModified, acpSessionId, grokSessionId, backend
        case isArchived, hasUnreadReady
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
        acpSessionId = try c.decodeIfPresent(String.self, forKey: .acpSessionId)
        grokSessionId = try c.decodeIfPresent(String.self, forKey: .grokSessionId)
        backend = try c.decodeIfPresent(AgentBackendKind.self, forKey: .backend) ?? .grokACP
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        hasUnreadReady = try c.decodeIfPresent(Bool.self, forKey: .hasUnreadReady) ?? false
    }

    var asChatSession: ChatSession {
        ChatSession(id: id, title: title, messages: messages, lastModified: lastModified)
    }
}

// MARK: - Project (folder / repo scope)

struct AgentProject: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var path: String
    var threads: [AgentThread]
    var lastOpened: Date
    /// Current git branch for this checkout/worktree, if it is a git repository.
    var gitBranch: String?
    /// For worktrees, the path of the primary repository they were spun off from.
    var parentRepoPath: String?
    /// True when this project is a git worktree rather than a primary checkout.
    var isWorktree: Bool
    /// Pinned projects stay at the top of the Sessions list.
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        threads: [AgentThread] = [],
        lastOpened: Date = Date(),
        gitBranch: String? = nil,
        parentRepoPath: String? = nil,
        isWorktree: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.threads = threads
        self.lastOpened = lastOpened
        self.gitBranch = gitBranch
        self.parentRepoPath = parentRepoPath
        self.isWorktree = isWorktree
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, threads, lastOpened, gitBranch, parentRepoPath, isWorktree, isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        threads = try c.decodeIfPresent([AgentThread].self, forKey: .threads) ?? []
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? Date()
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        parentRepoPath = try c.decodeIfPresent(String.self, forKey: .parentRepoPath)
        isWorktree = try c.decodeIfPresent(Bool.self, forKey: .isWorktree) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Workspace (top-level container, Codex-style)

struct AgentWorkspace: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var projects: [AgentProject]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        projects: [AgentProject] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.projects = projects
        self.createdAt = createdAt
    }
}

// MARK: - Persisted orchestrator state

struct OrchestratorSnapshot: Codable {
    var workspaces: [AgentWorkspace]
    var selectedWorkspaceId: UUID?
    var selectedProjectId: UUID?
    var selectedThreadId: UUID?
    var schemaVersion: Int

    static let currentSchemaVersion = 1

    init(
        workspaces: [AgentWorkspace] = [],
        selectedWorkspaceId: UUID? = nil,
        selectedProjectId: UUID? = nil,
        selectedThreadId: UUID? = nil,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.workspaces = workspaces
        self.selectedWorkspaceId = selectedWorkspaceId
        self.selectedProjectId = selectedProjectId
        self.selectedThreadId = selectedThreadId
        self.schemaVersion = schemaVersion
    }
}
