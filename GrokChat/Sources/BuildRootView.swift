import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import UserNotifications

private enum BuildSurfaceMode: String, CaseIterable, Identifiable {
    case native

    var id: String { rawValue }

    var title: String {
        "Agent"
    }

    var icon: String {
        "sparkles"
    }
}

private enum BuildUtilityPaneMode: String, CaseIterable, Identifiable {
    case review
    case terminal
    case browser
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: return "Review"
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .files: return "Files"
        }
    }

    var icon: String {
        switch self {
        case .review: return "checklist"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .files: return "folder"
        }
    }

    var shortcut: String {
        switch self {
        case .review: return "^⇧G"
        case .terminal: return "⌘T"
        case .browser: return "⌘B"
        case .files: return "⌘P"
        }
    }
}

/// Build mode: native IDE chrome around the official Grok Build CLI.
struct BuildRootView: View {
    @StateObject private var grokBuildAuth = GrokBuildAuthManager.shared
    @StateObject private var store = WorkspaceStore.shared
    @StateObject private var terminalSessions = TerminalSessionManager()
    @StateObject private var updateService = GrokCLIUpdateService.shared

    @AppStorage("selected_model") private var selectedModel: String = "auto"
    @AppStorage("grok_build_surface") private var buildSurfaceRaw: String = BuildSurfaceMode.native.rawValue
    @AppStorage("workingDirectoryBookmark") private var workingDirectoryBookmark: Data?

    @State private var isSidebarExpanded = true
    @State private var utilityPaneMode: BuildUtilityPaneMode?
    @State private var currentThreadId = UUID()
    @State private var cliAvailable = GrokCLIResolver.isAvailable
    @State private var cliVersion: String?
    @State private var skipAuthGate = false
    @State private var pendingInjectText: String?
    @State private var pendingInjectSubmit = false

    @State private var sessionToRename: UUID?
    @State private var renameTitle = ""
    @State private var isShowingRenameAlert = false
    @State private var isShowingSessionSwitcher = false
    @State private var isMainDropTargeted = false
    @State private var showInactiveProjects = false
    /// Cached off the main-thread git probe — never call Process in SwiftUI body.
    @State private var selectedProjectIsDirty = false
    @State private var dirtyStatusPath: String?

    private var sidebarBg: Color { BuildPalette.sidebar }

    private var conflictWarning: String? {
        guard let project = store.selectedProject else { return nil }
        let active = store.activeThreads(for: project)
        let busyHere = active.filter { terminalSessions.busyThreadIds.contains($0.id) }
        if busyHere.count >= 2 {
            return "Multiple chats are active in \(project.name). They share one worktree — watch for conflicting edits."
        }
        if selectedProjectIsDirty && busyHere.count >= 1 && active.count >= 2 {
            return "\(project.name) has uncommitted changes and more than one chat open. Prefer one writing agent at a time."
        }
        return nil
    }
    private var needsAuthGate: Bool {
        !skipAuthGate
            && !grokBuildAuth.hasCLISessionOnDisk
            && !grokBuildAuth.isUsingGrokBuildSession
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(BuildPalette.divider)
                .frame(width: 1)
                .ignoresSafeArea()
            contentShell
        }
        .animation(.easeInOut(duration: 0.22), value: isSidebarExpanded)
        .onAppear {
            buildSurfaceRaw = BuildSurfaceMode.native.rawValue
            terminalSessions.preferredModel = selectedModel
            GrokGhosttyApp.shared.initializeIfNeeded()
            enterBuildWorkspace()
        }
        .onChange(of: selectedModel) { _, newValue in
            terminalSessions.preferredModel = newValue
        }
        .onChange(of: store.selectedProject?.path) { _, _ in
            refreshDirtyStatusAsync()
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildDidBecomeActive)) { _ in
            enterBuildWorkspace()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenProjectFolder"))) { _ in
            startNewAgent()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebToBuildBridge.openProjectAtPath)) { notification in
            guard let url = notification.object as? URL else { return }
            if let prompt = notification.userInfo?["prompt"] as? String, !prompt.isEmpty {
                pendingInjectText = prompt
                pendingInjectSubmit = (notification.userInfo?["submit"] as? Bool) ?? true
            }
            openProject(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildNewSession)) { _ in
            if let project = store.selectedProject {
                startNewThread(in: project)
            } else {
                startNewAgent()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildOpenSessionSwitcher)) { _ in
            isShowingSessionSwitcher = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildArchiveCurrentSession)) { _ in
            archiveThread(currentThreadId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildSelectNextProject)) { _ in
            cycleProject(delta: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildSelectPreviousProject)) { _ in
            cycleProject(delta: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildSelectNextThread)) { _ in
            cycleThread(delta: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .buildSelectPreviousThread)) { _ in
            cycleThread(delta: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SpotlightQuery"))) { notification in
            guard let query = notification.object as? String, !query.isEmpty else { return }
            injectIntoGrokBuild(query, submit: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TransferWebContext"))) { notification in
            guard let text = notification.object as? String, !text.isEmpty else { return }
            injectIntoGrokBuild(text, submit: false)
        }
        .preferredColorScheme(.dark)
        .background(BuildPalette.terminal)
        .alert("Rename Thread", isPresented: $isShowingRenameAlert) {
            TextField("Title", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = sessionToRename {
                    store.renameThread(id, title: renameTitle)
                }
            }
        }
        .overlay {
            if isShowingSessionSwitcher {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { isShowingSessionSwitcher = false }
                    BuildSessionSwitcher(
                        store: store,
                        busyThreadIds: terminalSessions.busyThreadIds,
                        currentThreadId: currentThreadId,
                        onSelect: activateThread,
                        onDismiss: { isShowingSessionSwitcher = false }
                    )
                }
                .transition(.opacity)
                .zIndex(50)
            }
        }
    }

    private var contentShell: some View {
        HSplitView {
            mainPane
                .frame(minWidth: 520)

            if let mode = utilityPaneMode {
                BuildUtilityPane(
                    mode: mode,
                    store: store,
                    terminalContent: AnyView(terminalUtilityContent),
                    onSelectMode: openUtilityPane,
                    onClose: { utilityPaneMode = nil }
                )
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 680)
            }
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        if !cliAvailable {
            BuildMissingCLIGate {
                cliAvailable = GrokCLIResolver.isAvailable
                cliVersion = cliAvailable ? GrokCLIResolver.version() : nil
                enterBuildWorkspace()
            }
        } else if needsAuthGate {
            BuildAuthGate(
                authManager: grokBuildAuth,
                onReady: {
                    skipAuthGate = false
                    enterBuildWorkspace()
                },
                onSkipForNow: {
                    skipAuthGate = true
                    enterBuildWorkspace()
                }
            )
        } else {
            terminalPrimaryPane
        }
    }

    private var buildSurface: BuildSurfaceMode {
        get { BuildSurfaceMode(rawValue: buildSurfaceRaw) ?? .native }
        nonmutating set { buildSurfaceRaw = newValue.rawValue }
    }

    private var terminalHeaderSubtitle: String {
        if let path = store.selectedProject?.path {
            if let version = cliVersion {
                return "\(path) · \(version)"
            }
            return path
        }
        return "Choose a folder to launch Grok Build"
    }

    private var terminalPrimaryPane: some View {
        VStack(spacing: 0) {
            terminalHeader
            Divider()
            if updateService.shouldPrompt || updateService.isUpdating {
                BuildUpdateBanner(updateService: updateService, onUpdate: performCLIUpdateAndRestart)
                Divider()
            }
            if let warning = conflictWarning {
                BuildConflictBanner(message: warning)
                Divider()
            }
            if terminalSessions.remountPausedThreadIds.contains(currentThreadId) {
                BuildRemountPausedBanner {
                    terminalSessions.manualRemount(threadId: currentThreadId)
                }
                Divider()
            }
            if let project = store.selectedProject {
                if WorkspaceStore.directoryExists(at: project.path) {
                    terminalUtilityContent
                } else {
                    BuildMissingFolderGate(
                        projectName: project.name,
                        projectPath: project.path,
                        onRelocate: { relocateProject(project) },
                        onRemove: { removeMissingProject(project) },
                        onOpenOther: startNewAgent
                    )
                }
            } else {
                BuildOpenFolderGate(onOpenFolder: startNewAgent)
            }
        }
        .background(BuildPalette.terminal)
        .overlay {
            if isMainDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isMainDropTargeted) { providers in
            handleMainPaneDrop(providers)
        }
    }

    private var terminalHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedProject?.name ?? "Grok Build")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(terminalHeaderSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            Button { isShowingSessionSwitcher = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Jump to session (⌘K)")
            .keyboardShortcut("k", modifiers: .command)

            Button(action: startNewAgent) {
                Label("Open Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Open workspace folder (⌘O)")
            .keyboardShortcut("o", modifiers: .command)

            Button {
                if let project = store.selectedProject {
                    startNewThread(in: project)
                } else {
                    startNewAgent()
                }
            } label: {
                Image(systemName: "plus.bubble")
            }
            .buttonStyle(.borderless)
            .help("New chat in current project (⌘N)")
            .keyboardShortcut("n", modifiers: .command)

            Button {
                Task {
                    await updateService.checkForUpdates()
                    if updateService.latestCheck?.updateAvailable != true,
                       let message = updateService.statusMessage {
                        presentUpdateNotice(message)
                    }
                }
            } label: {
                Image(systemName: updateService.isChecking || updateService.isUpdating
                      ? "arrow.triangle.2.circlepath"
                      : (updateService.shouldPrompt ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath"))
            }
            .buttonStyle(.borderless)
            .disabled(updateService.isChecking || updateService.isUpdating || !cliAvailable)
            .help(updateService.shouldPrompt
                  ? "Update Grok Build CLI"
                  : "Check for Grok Build updates")

            Button(action: { openUtilityPane(.review) }) {
                Image(systemName: "checklist")
            }
            .buttonStyle(.borderless)
            .help("Review changes")

            Button(action: { openUtilityPane(.browser) }) {
                Image(systemName: "globe")
            }
            .buttonStyle(.borderless)
            .help("Open browser")

            Button(action: { openUtilityPane(.files) }) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open files")
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(BuildPalette.terminal)
    }

    @ViewBuilder
    private var terminalUtilityContent: some View {
        if terminalSessions.mountedSessions.isEmpty {
            ProgressView("Starting Grok Build…")
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BuildPalette.terminal)
                .onAppear {
                    if let project = store.selectedProject {
                        ensureThreadAndMount(project: project)
                    }
                }
        } else {
            terminalStack
        }
    }

    private func openUtilityPane(_ mode: BuildUtilityPaneMode) {
        if let project = store.selectedProject,
           let thread = store.selectedThread ?? project.threads.first {
            mountAndActivate(thread: thread, project: project)
        }
        utilityPaneMode = mode
    }

    /// All visited threads stay mounted; only the active one receives input (cmux-style).
    private var terminalStack: some View {
        ZStack {
            ForEach(terminalSessions.mountedSessions, id: \.threadId) { session in
                let isActive = terminalSessions.activeThreadId == session.threadId
                GrokGhosttyTerminalView(
                    sessionId: session.id,
                    executable: session.executable,
                    arguments: session.arguments,
                    workingDirectory: session.projectPath,
                    isActive: isActive,
                    isVisibleInUI: isActive
                )
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
                .zIndex(isActive ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BuildPalette.terminal)
    }

    private var sidebar: some View {
        ZStack(alignment: .leading) {
            sidebarBg.ignoresSafeArea()

            VStack(spacing: 0) {
                if isSidebarExpanded {
                    ProjectsSidebarView(
                        store: store,
                        authManager: grokBuildAuth,
                        hasAPIKey: false,
                        selectedProjectId: store.snapshot.selectedProjectId,
                        currentThreadId: $currentThreadId,
                        busyThreadIds: terminalSessions.busyThreadIds,
                        onNewAgent: startNewAgent,
                        onSelectProject: activateProject,
                        onSelectThread: activateThread,
                        onOpenSettings: openSettings,
                        onNewThread: startNewThread,
                        onDeleteThread: deleteThread,
                        onRenameThread: { id, title in
                            sessionToRename = id
                            renameTitle = title
                            isShowingRenameAlert = true
                        },
                        onArchiveThread: archiveThread,
                        onUnarchiveThread: unarchiveThread,
                        onNewWorktree: startNewWorktree,
                        onSwitchBranch: requestSwitchBranch,
                        onRemoveProject: removeProjectFromSidebar,
                        onOpenDroppedFolder: openProject,
                        onTogglePin: { store.toggleProjectPinned($0.id) },
                        showInactiveProjects: $showInactiveProjects
                    )
                } else {
                    Button { withAnimation(.easeInOut(duration: 0.22)) { isSidebarExpanded.toggle() } } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Expand sidebar")
                    .padding(.top, 58)

                    Spacer()
                    Button(action: startNewAgent) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("New Agent")
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(width: isSidebarExpanded ? 260 : 60)
    }

    /// Click Build → resume last workspace and land in live Grok Build.
    private func enterBuildWorkspace() {
        cliAvailable = GrokCLIResolver.isAvailable
        cliVersion = cliAvailable ? GrokCLIResolver.version() : nil
        if cliAvailable {
            terminalSessions.invalidatePlaceholderSessions()
            updateService.checkIfNeeded()
        }
        grokBuildAuth.bootstrapFromCLIIfNeeded()
        grokBuildAuth.syncFromCLIIfNewer()

        if store.selectedProject == nil {
            restoreProjectFromBookmarkIfNeeded()
        }

        refreshDirtyStatusAsync()

        // Don't mount while install/auth gates own the main pane.
        guard cliAvailable, !needsAuthGate else {
            focusBuildWindowSoon()
            return
        }

        guard let project = store.selectedProject else {
            focusBuildWindowSoon()
            return
        }

        guard WorkspaceStore.directoryExists(at: project.path) else {
            // Stale sidebar entry — do not spawn a broken terminal session.
            terminalSessions.removeSessions(forProjectPath: project.path)
            focusBuildWindowSoon()
            return
        }

        ensureThreadAndMount(project: project)
        flushPendingInjectIfPossible()
        focusBuildWindowSoon()
    }

    /// Probe dirty worktree off the main thread. Sync `git` inside SwiftUI layout
    /// crashed the app (EXC_BAD_ACCESS via waitUntilExit during NSHostingView.layout).
    private func refreshDirtyStatusAsync() {
        guard let path = store.selectedProject?.path else {
            selectedProjectIsDirty = false
            dirtyStatusPath = nil
            return
        }
        if dirtyStatusPath != path {
            // Clear stale banner while the new path is checked.
            selectedProjectIsDirty = false
            dirtyStatusPath = path
        }
        Task.detached(priority: .utility) {
            let dirty = GitService.hasUncommittedChanges(at: path)
            await MainActor.run {
                guard dirtyStatusPath == path else { return }
                selectedProjectIsDirty = dirty
            }
        }
    }

    private func ensureThreadAndMount(project: AgentProject) {
        guard WorkspaceStore.directoryExists(at: project.path) else {
            terminalSessions.removeSessions(forProjectPath: project.path)
            return
        }
        let thread: AgentThread
        if let selected = store.selectedThread, project.threads.contains(where: { $0.id == selected.id }) {
            thread = selected
        } else if let first = project.threads.first {
            thread = first
            store.select(threadId: first.id)
        } else {
            thread = store.createThread(title: "Grok Build")
        }
        currentThreadId = thread.id
        mountAndActivate(thread: thread, project: project)
    }

    private func relocateProject(_ project: AgentProject) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the new location for \(project.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        terminalSessions.removeSessions(forProjectPath: project.path)
        store.updateProjectPath(id: project.id, to: url)
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            workingDirectoryBookmark = bookmark
        }
        if GitService.isRepository(at: url.path),
           let branch = GitService.currentBranch(at: url.path) {
            store.setBranch(branch, for: project.id)
        }
        enterBuildWorkspace()
    }

    private func removeMissingProject(_ project: AgentProject) {
        removeProjectFromSidebar(project)
    }

    /// Drop a project (and its worktrees) from the harness sidebar. Disk untouched.
    private func removeProjectFromSidebar(_ project: AgentProject) {
        let worktreePaths = store.worktrees(forRepoPath: project.path).map(\.path)
        terminalSessions.removeSessions(forProjectPath: project.path)
        for path in worktreePaths {
            terminalSessions.removeSessions(forProjectPath: path)
        }
        store.removeProject(id: project.id)
        if let next = store.selectedProject {
            activateProject(next)
        } else {
            enterBuildWorkspace()
        }
    }

    private func restoreProjectFromBookmarkIfNeeded() {
        guard let data = workingDirectoryBookmark else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let project = store.ensureDefaultWorkspace(projectPath: url)
        if GitService.isRepository(at: project.path),
           let branch = GitService.currentBranch(at: project.path) {
            store.setBranch(branch, for: project.id)
        }
        if project.threads.isEmpty {
            _ = store.createThread(title: "Grok Build")
        }
    }

    private func injectIntoGrokBuild(_ text: String, submit: Bool) {
        pendingInjectText = text
        pendingInjectSubmit = submit
        enterBuildWorkspace()
        flushPendingInjectIfPossible(attemptsRemaining: 8)
    }

    private func flushPendingInjectIfPossible(attemptsRemaining: Int = 0) {
        guard let text = pendingInjectText else { return }
        let submit = pendingInjectSubmit
        let sent = terminalSessions.sendToActiveSession(text, submit: submit)
        if sent {
            pendingInjectText = nil
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            flushPendingInjectIfPossible(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func focusBuildWindowSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            terminalSessions.focusActiveSession()
        }
    }

    private func performCLIUpdateAndRestart() {
        Task {
            await updateService.performUpdateAndRestart {
                restartBuildSessionsAfterCLIUpdate()
            }
        }
    }

    private func restartBuildSessionsAfterCLIUpdate() {
        // Drop every PTY, re-resolve the new `grok` binary, resume with stored session IDs.
        // Harness UI state (projects/threads/pins) is untouched — only the CLI process restarts.
        let resumeTargets: [(UUID, String, String?)] = store.topLevelProjects().flatMap { project in
            store.activeThreads(for: project).map { thread in
                (thread.id, project.path, thread.grokSessionId)
            }
        }
        let selected = currentThreadId
        terminalSessions.clearAllSessions()
        cliAvailable = GrokCLIResolver.isAvailable
        cliVersion = cliAvailable ? GrokCLIResolver.version() : nil
        terminalSessions.preferredModel = selectedModel
        guard cliAvailable else {
            focusBuildWindowSoon()
            return
        }
        for (threadId, path, sessionId) in resumeTargets {
            guard WorkspaceStore.directoryExists(at: path) else { continue }
            _ = terminalSessions.remount(
                threadId: threadId,
                projectPath: path,
                grokSessionId: sessionId,
                model: selectedModel,
                continueMostRecent: sessionId == nil
            )
        }
        if resumeTargets.contains(where: { $0.0 == selected }) {
            terminalSessions.activate(threadId: selected)
            currentThreadId = selected
        } else if let project = store.selectedProject {
            ensureThreadAndMount(project: project)
        }
        focusBuildWindowSoon()
    }

    private func presentUpdateNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Grok Build"
        alert.informativeText = message
        if updateService.latestCheck?.updateAvailable == true {
            alert.addButton(withTitle: "Update & Restart")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                performCLIUpdateAndRestart()
            } else {
                updateService.dismissPrompt()
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func startNewAgent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a project folder for Grok Build"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    private func openProject(_ url: URL) {
        let project = store.ensureDefaultWorkspace(projectPath: url)
        if GitService.isRepository(at: project.path),
           let branch = GitService.currentBranch(at: project.path) {
            store.setBranch(branch, for: project.id)
        }
        if project.threads.isEmpty {
            _ = store.createThread(title: "Grok Build")
        }
        ensureThreadAndMount(project: store.selectedProject ?? project)
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            workingDirectoryBookmark = bookmark
        }
        flushPendingInjectIfPossible(attemptsRemaining: 8)
        focusBuildWindowSoon()
    }

    // MARK: - Git worktree / branch actions

    private func startNewWorktree(for project: AgentProject) {
        guard GitService.isRepository(at: project.path) else {
            presentGitError("\(project.name) is not a git repository.")
            return
        }
        guard let branch = promptForBranchName() else { return }
        switch GitService.createWorktree(repoPath: project.path, branch: branch) {
        case .success(let worktreePath):
            store.addWorktreeProject(
                name: branch,
                path: worktreePath,
                branch: branch,
                parentRepoPath: project.path
            )
            let thread = store.createThread(title: "Agent 0")
            if let worktree = store.selectedProject {
                mountAndActivate(thread: thread, project: worktree)
            }
        case .failure(let error):
            presentGitError(error.localizedDescription)
        }
    }

    private func requestSwitchBranch(for project: AgentProject) {
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

    private func switchBranch(for project: AgentProject, to branch: String) {
        switch GitService.switchBranch(branch, at: project.path) {
        case .success:
            store.setBranch(branch, for: project.id)
        case .failure(let error):
            presentGitError(error.localizedDescription)
        }
    }

    private func promptForBranchName() -> String? {
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

    private func presentGitError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Git"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func activateProject(_ project: AgentProject) {
        store.select(projectId: project.id)
        let threads = store.activeThreads(for: project)
        if let thread = threads.first ?? project.threads.first {
            activateThread(thread, project: project)
        }
    }

    private func activateThread(_ thread: AgentThread, project: AgentProject) {
        store.select(threadId: thread.id)
        store.setThreadUnread(thread.id, unread: false)
        currentThreadId = thread.id
        mountAndActivate(thread: thread, project: project)
    }

    private func startNewThread(in project: AgentProject) {
        guard WorkspaceStore.directoryExists(at: project.path) else { return }
        let thread = store.createThread(inProjectId: project.id, title: "New Chat")
        activateThread(thread, project: project)
    }

    private func archiveThread(_ threadId: UUID) {
        store.archiveThread(threadId)
        if currentThreadId == threadId {
            if let project = store.selectedProject,
               let next = store.activeThreads(for: project).first {
                activateThread(next, project: project)
            }
        }
    }

    private func unarchiveThread(_ threadId: UUID) {
        store.unarchiveThread(threadId)
        if let project = store.selectedProject,
           let thread = project.threads.first(where: { $0.id == threadId }) {
            activateThread(thread, project: project)
        }
    }

    private func cycleProject(delta: Int) {
        let projects = store.topLevelProjects()
        guard !projects.isEmpty else { return }
        let currentId = store.snapshot.selectedProjectId
        let idx = projects.firstIndex(where: { $0.id == currentId }) ?? 0
        let next = projects[(idx + delta + projects.count) % projects.count]
        activateProject(next)
    }

    private func cycleThread(delta: Int) {
        guard let project = store.selectedProject else { return }
        let threads = store.activeThreads(for: project)
        guard !threads.isEmpty else { return }
        let idx = threads.firstIndex(where: { $0.id == currentThreadId }) ?? 0
        let next = threads[(idx + delta + threads.count) % threads.count]
        activateThread(next, project: project)
    }

    private func handleMainPaneDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                if let data = item as? Data {
                    return URL(dataRepresentation: data, relativeTo: nil)
                }
                if let url = item as? URL { return url }
                return nil
            }()
            guard let url else { return }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            DispatchQueue.main.async {
                if exists && isDir.boolValue {
                    openProject(url)
                } else if exists {
                    // File drop → paste path into active Grok Build session.
                    injectIntoGrokBuild(url.path, submit: false)
                }
            }
        }
        return true
    }

    private func mountAndActivate(thread: AgentThread, project: AgentProject) {
        guard WorkspaceStore.directoryExists(at: project.path) else {
            terminalSessions.removeSessions(forProjectPath: project.path)
            return
        }
        guard GrokCLIResolver.isAvailable else { return }
        guard terminalSessions.ensureMounted(
            threadId: thread.id,
            projectPath: project.path,
            grokSessionId: thread.grokSessionId,
            model: selectedModel
        ) != nil else { return }
        terminalSessions.activate(threadId: thread.id)
    }

    private func openSettings() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showSettings(nil)
        }
    }

    private func deleteThread(_ threadId: UUID) {
        terminalSessions.removeSession(for: threadId)
        store.deleteThread(threadId)
        if let next = store.selectedThread, let project = store.selectedProject {
            currentThreadId = next.id
            mountAndActivate(thread: next, project: project)
        }
    }
}

extension Notification.Name {
    /// Posted when the toolbar Build mode becomes active (AppDelegate Build branch only).
    static let buildDidBecomeActive = Notification.Name("BuildDidBecomeActive")
}

// MARK: - Build tab palette

/// Appearance-adaptive colors tuned for a dark, IDE-style Build tab while still
/// reading well in light mode.
enum BuildPalette {
    static var sidebar: Color { Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1)) }
    static var terminal: Color { Color(nsColor: NSColor(calibratedWhite: 0.075, alpha: 1)) }
    static var panel: Color { Color(nsColor: NSColor(calibratedWhite: 0.155, alpha: 1)) }
    static var composer: Color { Color(nsColor: NSColor(calibratedWhite: 0.18, alpha: 1)) }
    static var divider: Color { Color.white.opacity(0.08) }
    static var rowHover: Color { Color.white.opacity(0.065) }

    /// Selected row background.
    static var rowSelected: Color { Color.white.opacity(0.10) }
}

// MARK: - Native ACP Build pane

private struct BuildNativeAgentPane: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var authManager: GrokBuildAuthManager
    @ObservedObject var orchestrator: AgentOrchestrator

    let selectedModel: String
    @Binding var mode: GrokBuildMode

    let onOpenProject: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenReview: () -> Void
    let onOpenBrowser: () -> Void
    let onOpenFiles: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var prompt = ""
    @State private var isSending = false
    @State private var requestStatus = ""
    @State private var activeAssistantMessageId: UUID?

    private var project: AgentProject? { store.selectedProject }
    private var thread: AgentThread? { store.selectedThread }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let project, let thread {
                conversation(project: project, thread: thread)
            } else {
                noProjectView
            }
        }
        .background(BuildPalette.terminal)
        .onAppear {
            loadSelectedThread()
            prewarmIfNeeded()
        }
        .onChange(of: store.snapshot.selectedThreadId) { _, _ in
            loadSelectedThread()
            prewarmIfNeeded()
        }
        .onChange(of: store.snapshot.selectedProjectId) { _, _ in
            loadSelectedThread()
            prewarmIfNeeded()
        }
        .onChange(of: mode) { _, _ in
            prewarmIfNeeded()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project?.name ?? "Grok Build")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(project?.path ?? "Choose a project folder to start")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            GrokBuildModePicker(mode: $mode)

            Button(action: onOpenProject) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Open project")

            Button(action: onOpenReview) {
                Image(systemName: "checklist")
            }
            .buttonStyle(.borderless)
            .help("Review changes")

            Button(action: onOpenTerminal) {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Open Grok terminal")

            Button(action: onOpenBrowser) {
                Image(systemName: "globe")
            }
            .buttonStyle(.borderless)
            .help("Open browser")

            Button(action: onOpenFiles) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open files")
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(BuildPalette.terminal)
    }

    private func conversation(project: AgentProject, thread: AgentThread) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            BuildWelcomeView(projectName: project.name, mode: mode)
                                .padding(.top, 48)
                        } else {
                            ForEach(messages.filter { !$0.isHiddenFromUI }) { message in
                                BuildMessageRow(
                                    message: message,
                                    isActive: message.id == activeAssistantMessageId,
                                    status: message.id == activeAssistantMessageId ? requestStatus : ""
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            Divider()
            composer(project: project, thread: thread)
        }
    }

    private func composer(project: AgentProject, thread: AgentThread) -> some View {
        VStack(spacing: 10) {
            if !requestStatus.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(requestStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 840)
            }

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Ask for follow-up changes")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary.opacity(0.58))
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                    }

                    TextEditor(text: $prompt)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(height: composerTextHeight)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                HStack(spacing: 12) {
                    Button(action: {}) {
                        Image(systemName: "plus")
                            .font(.system(size: 17))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Attach files")

                    Button(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 14))
                            Text("Full access")
                                .font(.system(size: 14, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.orange)
                    .help("Agent permissions")

                    Spacer(minLength: 16)

                    Button(action: {}) {
                        HStack(spacing: 7) {
                            Text("5.5")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("Medium")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Model")

                    Button(action: {}) {
                        Image(systemName: "mic")
                            .font(.system(size: 15))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dictate")

                    Button(action: { send(project: project, thread: thread) }) {
                        Image(systemName: isSending ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(BuildPalette.terminal)
                            .frame(width: 36, height: 36)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending)
                    .opacity(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending ? 0.55 : 1)
                    .help(isSending ? "Stop" : "Send")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: 840)
            .background(BuildPalette.composer)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.035), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(BuildPalette.terminal)
    }

    private var composerTextHeight: CGFloat {
        let explicitLines = prompt.components(separatedBy: .newlines).count
        let wrappedLines = max(1, prompt.count / 78 + explicitLines)
        return min(150, max(78, CGFloat(wrappedLines) * 22 + 38))
    }

    private var noProjectView: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Start a Grok Build agent")
                .font(.title3.weight(.semibold))
            Text("Choose a project folder. The native agent view uses your Grok CLI login and keeps the terminal available when needed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Open Project", action: onOpenProject)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadSelectedThread() {
        messages = thread?.messages ?? []
        activeAssistantMessageId = nil
        requestStatus = ""
        isSending = false
    }

    private func persist(threadId: UUID? = nil) {
        guard var selected = store.selectedThread else { return }
        if let threadId, selected.id != threadId { return }
        selected.messages = messages
        selected.lastModified = Date()
        if let first = messages.first(where: { $0.role == "user" }),
           selected.title == "New Thread" || selected.title.hasPrefix("Agent ") {
            selected.title = String(first.content.prefix(48))
        }
        store.updateThread(selected)
    }

    private func prewarmIfNeeded() {
        guard mode != .chat,
              let project,
              let thread,
              GrokCLIResolver.isAvailable else { return }
        authManager.syncFromCLIIfNewer()
        let projectURL = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath()
        let acpModel = ModelRegistry.resolveACPModel(selected: selectedModel)
        guard !orchestrator.hasWarmSession(
            threadId: thread.id,
            projectPath: projectURL,
            mode: mode,
            model: acpModel
        ) else { return }
        orchestrator.warmSession(
            projectPath: projectURL,
            mode: mode,
            threadId: thread.id,
            model: acpModel
        )
    }

    private func send(project: AgentProject, thread: AgentThread) {
        if isSending {
            orchestrator.stop()
            isSending = false
            requestStatus = ""
            activeAssistantMessageId = nil
            return
        }

        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        authManager.syncFromCLIIfNewer()

        let userMessage = ChatMessage(role: "user", content: text)
        let assistantId = UUID()
        messages.append(userMessage)
        messages.append(ChatMessage(id: assistantId, role: "assistant", content: "", isThinking: true))
        persist(threadId: thread.id)

        isSending = true
        activeAssistantMessageId = assistantId
        requestStatus = orchestrator.hasWarmSession(
            threadId: thread.id,
            projectPath: URL(fileURLWithPath: project.path),
            mode: mode,
            model: ModelRegistry.resolveACPModel(selected: selectedModel)
        ) ? "Grok CLI..." : "Starting Grok CLI..."

        let projectURL = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath()
        _ = projectURL.startAccessingSecurityScopedResource()
        let acpModel = ModelRegistry.resolveACPModel(selected: selectedModel)

        orchestrator.sendPrompt(
            text: text,
            threadId: thread.id,
            projectPath: projectURL,
            mode: mode,
            model: acpModel,
            assistantMessageId: assistantId,
            onUpdate: { _, update in
                update(&messages)
                persist(threadId: thread.id)
            },
            onComplete: {
                isSending = false
                requestStatus = ""
                activeAssistantMessageId = nil
                persist(threadId: thread.id)
                projectURL.stopAccessingSecurityScopedResource()
            },
            onStatusChange: { status in
                requestStatus = status
            },
            onFailure: nil
        )
    }
}

// MARK: - Utility panes

private struct BuildUtilityPane: View {
    let mode: BuildUtilityPaneMode
    @ObservedObject var store: WorkspaceStore
    let terminalContent: AnyView
    let onSelectMode: (BuildUtilityPaneMode) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(BuildPalette.terminal)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(BuildUtilityPaneMode.allCases) { item in
                    Button {
                        onSelectMode(item)
                    } label: {
                        HStack {
                            Label(item.title, systemImage: item.icon)
                            Spacer()
                            Text(item.shortcut)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .medium))
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(BuildPalette.rowHover)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close pane")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .review:
            BuildReviewPane(project: store.selectedProject)
        case .terminal:
            terminalContent
        case .browser:
            BuildBrowserPane(project: store.selectedProject)
        case .files:
            BuildFilesPane(project: store.selectedProject)
        }
    }
}

private struct BuildReviewPane: View {
    let project: AgentProject?
    @State private var statusLines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private enum StatusResult {
        case success([String])
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project?.name ?? "No project")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Working tree review")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(14)

            Divider()

            if project == nil {
                utilityEmptyState(icon: "checklist", title: "Open a project", subtitle: "Review shows git changes for the selected workspace.")
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                utilityEmptyState(icon: "exclamationmark.triangle", title: "Review unavailable", subtitle: errorMessage)
            } else if statusLines.isEmpty {
                utilityEmptyState(icon: "checkmark.circle", title: "No local changes", subtitle: "The selected project has a clean working tree.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(statusLines, id: \.self) { line in
                            HStack(spacing: 8) {
                                Text(String(line.prefix(2)))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(statusColor(line))
                                    .frame(width: 24, alignment: .leading)
                                Text(String(line.dropFirst(3)))
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task(id: project?.id) {
            refresh()
        }
    }

    private func refresh() {
        guard let project else { return }
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runGitStatus(at: project.path)
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let lines):
                    statusLines = lines
                case .failure(let message):
                    statusLines = []
                    errorMessage = message
                }
            }
        }
    }

    private func statusColor(_ line: String) -> Color {
        if line.hasPrefix("A") || line.hasPrefix("??") { return .green }
        if line.hasPrefix("D") || line.dropFirst().hasPrefix("D") { return .red }
        if line.hasPrefix("M") || line.dropFirst().hasPrefix("M") { return .orange }
        return .secondary
    }

    private func runGitStatus(at path: String) -> StatusResult {
        guard let git = GitService.resolveGit() else { return .failure("git was not found on this system.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["status", "--short"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error.localizedDescription)
        }
        if process.terminationStatus != 0 {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message?.isEmpty == false ? message! : "This folder is not a git repository.")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return .success(text.split(separator: "\n").map(String.init))
    }
}

private struct BuildFilesPane: View {
    let project: AgentProject?
    @State private var filter = ""
    @State private var items: [BuildFileItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Filter files...", text: $filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)

            Divider()

            if project == nil {
                utilityEmptyState(icon: "folder", title: "Open a project", subtitle: "Files appear for the selected workspace.")
            } else if filteredItems.isEmpty {
                utilityEmptyState(icon: "doc.text.magnifyingglass", title: "No files", subtitle: filter.isEmpty ? "This folder is empty." : "No files match the filter.")
            } else {
                List(filteredItems, children: \.children) { item in
                    HStack(spacing: 7) {
                        Image(systemName: item.isDirectory ? "folder" : icon(for: item.name))
                            .font(.system(size: 11))
                            .foregroundStyle(item.isDirectory ? .orange : .secondary)
                            .frame(width: 14)
                        Text(item.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !item.isDirectory {
                            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                        }
                    }
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        }
                        if !item.isDirectory {
                            Button("Open") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .task(id: project?.id) {
            reload()
        }
    }

    private var filteredItems: [BuildFileItem] {
        guard !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        return filterItems(items, query: filter.lowercased())
    }

    private func reload() {
        guard let project else {
            items = []
            return
        }
        items = BuildFileItem.loadChildren(at: URL(fileURLWithPath: project.path), depth: 0)
    }

    private func filterItems(_ source: [BuildFileItem], query: String) -> [BuildFileItem] {
        source.compactMap { item in
            let children = filterItems(item.children ?? [], query: query)
            if item.name.lowercased().contains(query) || !children.isEmpty {
                var copy = item
                copy.children = children
                return copy
            }
            return nil
        }
    }

    private func icon(for name: String) -> String {
        if name.hasSuffix(".swift") { return "swift" }
        if name.hasSuffix(".md") { return "doc.richtext" }
        if name.hasSuffix(".json") { return "curlybraces" }
        return "doc.text"
    }
}

private struct BuildFileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [BuildFileItem]?

    static func loadChildren(at url: URL, depth: Int, maxDepth: Int = 2) -> [BuildFileItem] {
        guard depth <= maxDepth,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .sorted { lhs, rhs in
                let lhsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rhsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if lhsDir != rhsDir { return lhsDir && !rhsDir }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .prefix(250)
            .map { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return BuildFileItem(
                    id: child.path,
                    name: child.lastPathComponent,
                    path: child.path,
                    isDirectory: isDir,
                    children: isDir ? loadChildren(at: child, depth: depth + 1, maxDepth: maxDepth) : nil
                )
            }
    }

    private static let ignoredNames: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".next", "dist", "build"
    ]
}

private struct BuildBrowserPane: View {
    let project: AgentProject?
    @State private var address = "http://localhost:3000"
    @State private var targetURL = URL(string: "http://localhost:3000")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    loadAddress()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                TextField("Enter a URL", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(loadAddress)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: loadAddress) {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(.borderless)
            }
            .padding(10)

            Divider()

            BuildWebView(url: targetURL)
                .overlay(alignment: .bottomLeading) {
                    if let project {
                        Text(project.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
        }
    }

    private func loadAddress() {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !value.contains("://") {
            value = "http://\(value)"
        }
        if let url = URL(string: value) {
            address = value
            targetURL = url
        }
    }
}

private struct BuildWebView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url, webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}

private func utilityEmptyState(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 30))
            .foregroundStyle(.secondary)
        Text(title)
            .font(.system(size: 14, weight: .semibold))
        Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private struct BuildWelcomeView: View {
    let projectName: String
    let mode: GrokBuildMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grok Build Agent")
                        .font(.system(size: 18, weight: .semibold))
                    Text("\(projectName) · \(mode.displayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Ask for code changes, repo analysis, tests, or terminal work. The app talks to the official Grok CLI agent instead of reimplementing the build engine.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BuildMessageRow: View {
    let message: ChatMessage
    let isActive: Bool
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.role == "user" ? "person.crop.circle" : "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(message.role == "user" ? .secondary : Color.accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(message.role == "user" ? "You" : "Grok Build")
                        .font(.system(size: 12, weight: .semibold))
                    if isActive, !status.isEmpty {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if message.isThinking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(status.isEmpty ? "Thinking..." : status)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                let visibleLines = AgentActivityLine.visibleLines(from: message.activityLines, isLive: message.isThinking || isActive)
                if !visibleLines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleLines) { line in
                            BuildActivityLineView(line: line)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BuildActivityLineView: View {
    let line: AgentActivityLine

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: line.isInProgress ? "circle.dotted" : line.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(line.isInProgress ? Color.accentColor : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.system(size: 12, weight: .medium))
                if let detail = line.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
