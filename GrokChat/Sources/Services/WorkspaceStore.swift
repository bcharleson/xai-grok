import Foundation
import Combine

/// Persists workspace → project → thread hierarchy and selection state.
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var snapshot: OrchestratorSnapshot

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrokBuild/Orchestrator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    private init() {
        snapshot = Self.loadFromDisk()
    }

    // MARK: - Selection

    var selectedWorkspace: AgentWorkspace? {
        guard let id = snapshot.selectedWorkspaceId else { return snapshot.workspaces.first }
        return snapshot.workspaces.first { $0.id == id } ?? snapshot.workspaces.first
    }

    var selectedProject: AgentProject? {
        guard let ws = selectedWorkspace else { return nil }
        guard let id = snapshot.selectedProjectId else { return ws.projects.first }
        return ws.projects.first { $0.id == id } ?? ws.projects.first
    }

    var selectedThread: AgentThread? {
        guard let project = selectedProject else { return nil }
        guard let id = snapshot.selectedThreadId else {
            return project.threads.first(where: { !$0.isArchived }) ?? project.threads.first
        }
        return project.threads.first { $0.id == id }
    }

    func select(workspaceId: UUID) {
        snapshot.selectedWorkspaceId = workspaceId
        if let ws = snapshot.workspaces.first(where: { $0.id == workspaceId }),
           snapshot.selectedProjectId == nil || ws.projects.first(where: { $0.id == snapshot.selectedProjectId }) == nil {
            snapshot.selectedProjectId = ws.projects.first?.id
        }
        snapshot.selectedThreadId = selectedProject?.threads.first?.id
        persist()
    }

    func select(projectId: UUID) {
        snapshot.selectedProjectId = projectId
        let threads = selectedProject?.threads ?? []
        snapshot.selectedThreadId = threads.first(where: { !$0.isArchived })?.id ?? threads.first?.id
        if let wsIdx = indexOfSelectedWorkspace(),
           let pIdx = snapshot.workspaces[wsIdx].projects.firstIndex(where: { $0.id == projectId }) {
            snapshot.workspaces[wsIdx].projects[pIdx].lastOpened = Date()
        }
        persist()
    }

    func select(threadId: UUID) {
        snapshot.selectedThreadId = threadId
        persist()
    }

    // MARK: - Mutations

    @discardableResult
    func ensureDefaultWorkspace(projectPath: URL, projectName: String? = nil) -> AgentProject {
        if snapshot.workspaces.isEmpty {
            migrateLegacySessions(projectPath: projectPath)
        }

        let path = projectPath.standardizedFileURL.path
        if let existing = findProject(path: path) {
            select(projectId: existing.id)
            return existing
        }

        let name = projectName ?? projectPath.lastPathComponent
        let project = AgentProject(name: name, path: path)
        addProject(project, to: selectedWorkspace?.id ?? ensureWorkspace(named: "My Workspace").id)
        return project
    }

    @discardableResult
    func createThread(title: String = "New Thread") -> AgentThread {
        guard let projectId = selectedProject?.id else {
            return AgentThread(title: title)
        }
        return createThread(inProjectId: projectId, title: title)
    }

    /// Create a thread under a specific project (selects that project + thread).
    @discardableResult
    func createThread(inProjectId projectId: UUID, title: String = "New Thread") -> AgentThread {
        let thread = AgentThread(title: title)
        for wsIdx in snapshot.workspaces.indices {
            guard let pIdx = snapshot.workspaces[wsIdx].projects.firstIndex(where: { $0.id == projectId }) else { continue }
            snapshot.workspaces[wsIdx].projects[pIdx].threads.insert(thread, at: 0)
            snapshot.workspaces[wsIdx].projects[pIdx].lastOpened = Date()
            snapshot.selectedWorkspaceId = snapshot.workspaces[wsIdx].id
            snapshot.selectedProjectId = projectId
            snapshot.selectedThreadId = thread.id
            persist()
            return thread
        }
        return thread
    }

    func updateThread(_ thread: AgentThread) {
        mutateThread(id: thread.id) { $0 = thread }
    }

    func setACPSessionId(_ sessionId: String, for threadId: UUID) {
        mutateThread(id: threadId) { $0.acpSessionId = sessionId }
    }

    func setGrokSessionId(_ sessionId: String, for threadId: UUID) {
        mutateThread(id: threadId) { $0.grokSessionId = sessionId }
    }

    func deleteThread(_ threadId: UUID) {
        for wsIdx in snapshot.workspaces.indices {
            for pIdx in snapshot.workspaces[wsIdx].projects.indices {
                guard snapshot.workspaces[wsIdx].projects[pIdx].threads.contains(where: { $0.id == threadId }) else { continue }
                snapshot.workspaces[wsIdx].projects[pIdx].threads.removeAll { $0.id == threadId }
                if snapshot.selectedThreadId == threadId {
                    let remaining = snapshot.workspaces[wsIdx].projects[pIdx].threads
                    snapshot.selectedThreadId = remaining.first(where: { !$0.isArchived })?.id ?? remaining.first?.id
                }
                persist()
                return
            }
        }
    }

    func renameThread(_ threadId: UUID, title: String) {
        mutateThread(id: threadId) { $0.title = title }
    }

    func archiveThread(_ threadId: UUID) {
        mutateThread(id: threadId) {
            $0.isArchived = true
            $0.hasUnreadReady = false
        }
        if snapshot.selectedThreadId == threadId {
            let remaining = selectedProject?.threads ?? []
            snapshot.selectedThreadId = remaining.first(where: { !$0.isArchived })?.id ?? remaining.first?.id
            persist()
        }
    }

    func unarchiveThread(_ threadId: UUID) {
        mutateThread(id: threadId) { $0.isArchived = false }
    }

    func setThreadUnread(_ threadId: UUID, unread: Bool) {
        mutateThread(id: threadId) { $0.hasUnreadReady = unread }
    }

    func activeThreads(for project: AgentProject) -> [AgentThread] {
        project.threads
            .filter { !$0.isArchived }
            .sorted { $0.lastModified > $1.lastModified }
    }

    func archivedThreads(for project: AgentProject) -> [AgentThread] {
        project.threads
            .filter(\.isArchived)
            .sorted { $0.lastModified > $1.lastModified }
    }

    /// Apply a mutation to a thread regardless of which project contains it.
    private func mutateThread(id: UUID, _ body: (inout AgentThread) -> Void) {
        for wsIdx in snapshot.workspaces.indices {
            for pIdx in snapshot.workspaces[wsIdx].projects.indices {
                if let tIdx = snapshot.workspaces[wsIdx].projects[pIdx].threads.firstIndex(where: { $0.id == id }) {
                    body(&snapshot.workspaces[wsIdx].projects[pIdx].threads[tIdx])
                    persist()
                    return
                }
            }
        }
    }

    /// Remove a project from its workspace (and any worktrees spun from it).
    /// Does not delete files on disk — only the harness entry.
    func removeProject(id: UUID) {
        for wsIdx in snapshot.workspaces.indices {
            guard let pIdx = snapshot.workspaces[wsIdx].projects.firstIndex(where: { $0.id == id }) else { continue }
            let removed = snapshot.workspaces[wsIdx].projects[pIdx]
            let normalizedPath = URL(fileURLWithPath: removed.path).standardizedFileURL.path

            snapshot.workspaces[wsIdx].projects.removeAll { project in
                if project.id == id { return true }
                guard project.isWorktree, let parent = project.parentRepoPath else { return false }
                return URL(fileURLWithPath: parent).standardizedFileURL.path == normalizedPath
            }

            if snapshot.selectedProjectId == id
                || snapshot.workspaces[wsIdx].projects.first(where: { $0.id == snapshot.selectedProjectId }) == nil {
                let next = snapshot.workspaces[wsIdx].projects.first(where: { !$0.isWorktree })
                    ?? snapshot.workspaces[wsIdx].projects.first
                snapshot.selectedProjectId = next?.id
                let threads = next?.threads ?? []
                snapshot.selectedThreadId = threads.first(where: { !$0.isArchived })?.id ?? threads.first?.id
            }
            persist()
            return
        }
    }

    /// Point an existing project at a new on-disk folder (relocate after move/delete).
    func updateProjectPath(id: UUID, to url: URL) {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        mutateProject(id: id) { project in
            project.path = path
            project.name = name
            project.lastOpened = Date()
        }
        select(projectId: id)
    }

    static func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    @discardableResult
    func addProject(_ project: AgentProject, to workspaceId: UUID) -> AgentProject {
        guard let wsIdx = snapshot.workspaces.firstIndex(where: { $0.id == workspaceId }) else { return project }
        snapshot.workspaces[wsIdx].projects.insert(project, at: 0)
        snapshot.selectedWorkspaceId = workspaceId
        snapshot.selectedProjectId = project.id
        snapshot.selectedThreadId = project.threads.first?.id
        persist()
        return project
    }

    func allThreadsFlat() -> [AgentThread] {
        snapshot.workspaces.flatMap { $0.projects.flatMap(\.threads) }
    }

    func allProjectsSorted() -> [AgentProject] {
        snapshot.workspaces
            .flatMap(\.projects)
            .sorted { $0.lastOpened > $1.lastOpened }
    }

    func project(forPath path: String) -> AgentProject? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return findProject(path: normalized)
    }

    // MARK: - Git branches & worktrees

    /// Top-level repositories (primary checkouts): pinned first, then most-recently-opened.
    func topLevelProjects() -> [AgentProject] {
        snapshot.workspaces
            .flatMap(\.projects)
            .filter { !$0.isWorktree }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.lastOpened > rhs.lastOpened
            }
    }

    func setProjectPinned(_ projectId: UUID, pinned: Bool) {
        mutateProject(id: projectId) { $0.isPinned = pinned }
    }

    func toggleProjectPinned(_ projectId: UUID) {
        mutateProject(id: projectId) { $0.isPinned.toggle() }
    }

    /// Worktrees spun off from the given repository path, most-recently-opened first.
    func worktrees(forRepoPath repoPath: String) -> [AgentProject] {
        let normalized = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        return snapshot.workspaces
            .flatMap(\.projects)
            .filter { $0.isWorktree && $0.parentRepoPath == normalized }
            .sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Record the active git branch for a project anywhere in the hierarchy.
    func setBranch(_ branch: String?, for projectId: UUID) {
        mutateProject(id: projectId) { $0.gitBranch = branch }
    }

    /// Add a worktree as a distinct project entry tied to its parent repository.
    @discardableResult
    func addWorktreeProject(
        name: String,
        path: String,
        branch: String,
        parentRepoPath: String
    ) -> AgentProject {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedParent = URL(fileURLWithPath: parentRepoPath).standardizedFileURL.path
        if let existing = findProject(path: normalizedPath) {
            select(projectId: existing.id)
            return existing
        }
        let project = AgentProject(
            name: name,
            path: normalizedPath,
            gitBranch: branch,
            parentRepoPath: normalizedParent,
            isWorktree: true
        )
        let workspaceId = selectedWorkspace?.id ?? ensureWorkspace(named: "My Workspace").id
        return addProject(project, to: workspaceId)
    }

    /// Apply a mutation to a project regardless of which workspace contains it.
    private func mutateProject(id: UUID, _ body: (inout AgentProject) -> Void) {
        for wsIdx in snapshot.workspaces.indices {
            if let pIdx = snapshot.workspaces[wsIdx].projects.firstIndex(where: { $0.id == id }) {
                body(&snapshot.workspaces[wsIdx].projects[pIdx])
                persist()
                return
            }
        }
    }

    /// Keep at most one empty draft thread per project.
    func pruneDuplicateEmptyThreads() {
        var changed = false
        for wsIdx in snapshot.workspaces.indices {
            for pIdx in snapshot.workspaces[wsIdx].projects.indices {
                var seenEmpty = false
                var kept: [AgentThread] = []
                for thread in snapshot.workspaces[wsIdx].projects[pIdx].threads {
                    let isEmptyDraft = thread.messages.isEmpty
                        && (thread.title == "New Chat" || thread.title == "New Thread")
                    if isEmptyDraft {
                        if seenEmpty { changed = true; continue }
                        seenEmpty = true
                    }
                    kept.append(thread)
                }
                if kept.count != snapshot.workspaces[wsIdx].projects[pIdx].threads.count {
                    snapshot.workspaces[wsIdx].projects[pIdx].threads = kept
                    changed = true
                }
            }
        }
        if changed { persist() }
    }

    // MARK: - Private

    @discardableResult
    private func ensureWorkspace(named: String) -> AgentWorkspace {
        if let first = snapshot.workspaces.first { return first }
        let ws = AgentWorkspace(name: named)
        snapshot.workspaces = [ws]
        snapshot.selectedWorkspaceId = ws.id
        persist()
        return ws
    }

    private func findProject(path: String) -> AgentProject? {
        for ws in snapshot.workspaces {
            if let p = ws.projects.first(where: { $0.path == path }) { return p }
        }
        return nil
    }

    private func indexOfSelectedWorkspace() -> Int? {
        guard let id = selectedWorkspace?.id else { return nil }
        return snapshot.workspaces.firstIndex { $0.id == id }
    }

    private func indexOfSelectedProject(workspaceIndex wsIdx: Int) -> Int? {
        guard let id = selectedProject?.id else { return nil }
        return snapshot.workspaces[wsIdx].projects.firstIndex { $0.id == id }
    }

    private func migrateLegacySessions(projectPath: URL) {
        let legacy = PersistenceController.shared.load()
        let threads = legacy.map { AgentThread(from: $0) }
        let project = AgentProject(
            name: projectPath.lastPathComponent,
            path: projectPath.path,
            threads: threads
        )
        let ws = AgentWorkspace(name: "My Workspace", projects: [project])
        snapshot = OrchestratorSnapshot(
            workspaces: [ws],
            selectedWorkspaceId: ws.id,
            selectedProjectId: project.id,
            selectedThreadId: threads.first?.id
        )
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[WorkspaceStore] persist failed: \(error)")
            #endif
        }
    }

    private static func loadFromDisk() -> OrchestratorSnapshot {
        let url = WorkspaceStore.sharedStoreURL
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(OrchestratorSnapshot.self, from: data) else {
            return OrchestratorSnapshot()
        }
        return snap
    }

    private static var sharedStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrokBuild/Orchestrator", isDirectory: true)
        return dir.appendingPathComponent("workspaces.json")
    }
}

// MARK: - Git worktree / branch helper

enum GitError: LocalizedError {
    case gitUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitUnavailable: return "git was not found on this system."
        case .commandFailed(let message): return message
        }
    }
}

/// Thin wrapper around the `git` CLI for branch / worktree operations driven from the sidebar.
enum GitService {
    private static let candidatePaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]

    static func resolveGit() -> String? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func isRepository(at path: String) -> Bool {
        run(["rev-parse", "--is-inside-work-tree"], cwd: path)?.status == 0
    }

    /// True when the worktree has staged/unstaged/untracked changes.
    static func hasUncommittedChanges(at path: String) -> Bool {
        guard isRepository(at: path) else { return false }
        guard let result = run(["status", "--porcelain"], cwd: path), result.status == 0 else {
            return false
        }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func currentBranch(at path: String) -> String? {
        guard let result = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path), result.status == 0 else {
            return nil
        }
        return normalizeBranchName(result.stdout)
    }

    static func localBranches(at path: String) -> [String] {
        guard let result = run(["branch", "--format=%(refname:short)"], cwd: path), result.status == 0 else {
            return []
        }
        return parseBranchList(result.stdout)
    }

    /// Create a git worktree for `branch` (creating the branch if it does not exist) and return its path.
    static func createWorktree(repoPath: String, branch: String) -> Result<String, GitError> {
        guard resolveGit() != nil else { return .failure(.gitUnavailable) }

        let target = worktreePath(repoPath: repoPath, branch: branch)
        let parent = URL(fileURLWithPath: target).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let args = worktreeAddArguments(
            branch: branch,
            targetPath: target,
            branchExists: localBranches(at: repoPath).contains(branch)
        )

        guard let result = run(args, cwd: repoPath) else { return .failure(.gitUnavailable) }
        guard result.status == 0 else {
            return .failure(.commandFailed(failureMessage(stdout: result.stdout, stderr: result.stderr)))
        }
        return .success(target)
    }

    /// Switch the checkout at `path` to `branch` in place.
    static func switchBranch(_ branch: String, at path: String) -> Result<Void, GitError> {
        guard resolveGit() != nil else { return .failure(.gitUnavailable) }
        guard let result = run(["checkout", branch], cwd: path) else { return .failure(.gitUnavailable) }
        guard result.status == 0 else {
            return .failure(.commandFailed(failureMessage(stdout: result.stdout, stderr: result.stderr)))
        }
        return .success(())
    }

    // MARK: - Pure helpers (no process execution, unit-testable)

    /// File-system safe component for a branch name (slashes become dashes).
    static func sanitizedBranchComponent(_ branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// Directory where a worktree for `branch` is created, derived purely from inputs.
    /// Layout: <repoParent>/.grok-worktrees/<repoName>/<sanitizedBranch>
    static func worktreePath(repoPath: String, branch: String) -> String {
        let repoURL = URL(fileURLWithPath: repoPath).standardizedFileURL
        return repoURL.deletingLastPathComponent()
            .appendingPathComponent(".grok-worktrees", isDirectory: true)
            .appendingPathComponent(repoURL.lastPathComponent, isDirectory: true)
            .appendingPathComponent(sanitizedBranchComponent(branch), isDirectory: true)
            .path
    }

    /// `git worktree add` arguments, creating the branch when it does not already exist.
    static func worktreeAddArguments(branch: String, targetPath: String, branchExists: Bool) -> [String] {
        branchExists
            ? ["worktree", "add", targetPath, branch]
            : ["worktree", "add", "-b", branch, targetPath]
    }

    /// Parse `git branch --format=%(refname:short)` output into trimmed, non-empty names.
    static func parseBranchList(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Normalize `git rev-parse --abbrev-ref HEAD` output; nil for detached/empty HEAD.
    static func normalizeBranchName(_ output: String) -> String? {
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branch.isEmpty || branch == "HEAD") ? nil : branch
    }

    /// Prefer stderr for failure messages, falling back to stdout, trimmed.
    static func failureMessage(stdout: String, stderr: String) -> String {
        (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ args: [String], cwd: String) -> (status: Int32, stdout: String, stderr: String)? {
        guard let git = resolveGit() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }
}
