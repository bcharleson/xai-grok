import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Build sidebar: multi-project session harness (threads under folders).
/// Open folder lives in the Build toolbar — keep this pane for projects/sessions.
/// Plugins / skills / slash commands stay in the official Grok TUI (`/`, `/plugins`).
struct ProjectsSidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var authManager: GrokBuildAuthManager
    var hasAPIKey: Bool
    var selectedProjectId: UUID?
    @Binding var currentThreadId: UUID
    /// Thread IDs currently producing terminal output (runtime only).
    var busyThreadIds: Set<UUID> = []
    var onNewAgent: () -> Void
    var onSelectProject: (AgentProject) -> Void
    var onSelectThread: (AgentThread, AgentProject) -> Void
    var onOpenSettings: () -> Void
    var onNewThread: (AgentProject) -> Void
    var onDeleteThread: (UUID) -> Void
    var onRenameThread: (UUID, String) -> Void
    var onArchiveThread: (UUID) -> Void
    var onUnarchiveThread: (UUID) -> Void
    var onNewWorktree: (AgentProject) -> Void
    var onSwitchBranch: (AgentProject) -> Void
    var onRemoveProject: (AgentProject) -> Void
    /// Drop a folder path onto the sidebar to open it as a project.
    var onOpenDroppedFolder: ((URL) -> Void)? = nil
    var onTogglePin: (AgentProject) -> Void = { _ in }
    @Binding var showInactiveProjects: Bool

    @State private var expandedProjects: Set<UUID> = []
    @State private var expandedArchived: Set<UUID> = []
    @State private var projectFilter = ""
    @State private var projectPendingRemoval: AgentProject?
    @State private var isDropTargeted = false

    private static let staleInterval: TimeInterval = 60 * 60 * 24 * 14 // 14 days

    private var repos: [AgentProject] { store.topLevelProjects() }

    private var filteredRepos: [AgentProject] {
        let query = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [AgentProject]
        if query.isEmpty {
            base = showInactiveProjects ? repos : repos.filter { isActiveProject($0) }
        } else {
            base = repos.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return base
    }

    private var hiddenInactiveCount: Int {
        guard !showInactiveProjects else { return 0 }
        return repos.filter { !isActiveProject($0) }.count
    }

    private func isActiveProject(_ project: AgentProject) -> Bool {
        if project.isPinned { return true }
        if project.id == selectedProjectId { return true }
        if Date().timeIntervalSince(project.lastOpened) < Self.staleInterval { return true }
        if store.activeThreads(for: project).contains(where: {
            busyThreadIds.contains($0.id) || $0.hasUnreadReady
        }) { return true }
        return false
    }

    private var activeSessionCount: Int {
        repos.reduce(0) { $0 + store.activeThreads(for: $1).count }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if repos.isEmpty {
                        emptyProjectsState
                    } else if filteredRepos.isEmpty {
                        Text("No matching projects")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                    } else {
                        ForEach(filteredRepos) { project in
                            projectSection(project)
                        }
                    }
                }
                .padding(.bottom, 24)
            }

            settingsRow
        }
        .background(isDropTargeted ? BuildPalette.rowHover.opacity(0.55) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers)
        }
        .confirmationDialog(
            projectPendingRemoval.map { "Remove “\($0.name)”?" } ?? "Remove project?",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Sidebar", role: .destructive) {
                if let project = projectPendingRemoval {
                    onRemoveProject(project)
                }
                projectPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                projectPendingRemoval = nil
            }
        } message: {
            Text("Removes this folder and its chats from the sidebar. Files on disk are not deleted.")
        }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !repos.isEmpty {
                    Text("\(repos.count) · \(activeSessionCount)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .help("\(repos.count) projects · \(activeSessionCount) active chats")
                }
            }

            if !repos.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("Filter projects", text: $projectFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(BuildPalette.rowHover)
                .clipShape(RoundedRectangle(cornerRadius: 7))

                if hiddenInactiveCount > 0 || showInactiveProjects {
                    Button {
                        showInactiveProjects.toggle()
                    } label: {
                        Text(showInactiveProjects
                             ? "Hide inactive projects"
                             : "Show \(hiddenInactiveCount) inactive")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 54)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var emptyProjectsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No projects yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Open a folder from the toolbar to start a Grok Build session.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Folder", action: onNewAgent)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
    }

    private func projectSection(_ project: AgentProject) -> AnyView {
        let active = store.activeThreads(for: project)
        let archived = store.archivedThreads(for: project)
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ProjectHeaderRow(
                    project: project,
                    isExpanded: isExpanded(project),
                    isSelected: project.id == selectedProjectId && active.isEmpty,
                    isBusy: active.contains { busyThreadIds.contains($0.id) },
                    unreadCount: active.filter { $0.hasUnreadReady && $0.id != currentThreadId }.count,
                    folderMissing: !WorkspaceStore.directoryExists(at: project.path),
                    onToggle: { toggle(project.id) },
                    onSelect: {
                        onSelectProject(project)
                        expandedProjects.insert(project.id)
                    },
                    onNewThread: { onNewThread(project) },
                    onNewWorktree: { onNewWorktree(project) },
                    onSwitchBranch: { onSwitchBranch(project) },
                    onTogglePin: { onTogglePin(project) },
                    onRemove: { projectPendingRemoval = project }
                )
                .padding(.top, 12)

                if isExpanded(project) {
                    ForEach(active) { thread in
                        threadRow(thread, project: project, isArchived: false)
                    }

                    if !archived.isEmpty {
                        archivedSection(project: project, archived: archived)
                    }

                    ForEach(store.worktrees(forRepoPath: project.path)) { worktree in
                        projectSection(worktree)
                            .padding(.leading, 16)
                    }
                }
            }
        )
    }

    private func archivedSection(project: AgentProject, archived: [AgentThread]) -> some View {
        let isOpen = expandedArchived.contains(project.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expandedArchived.remove(project.id) }
                else { expandedArchived.insert(project.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Archived")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(archived.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.leading, 50)
                .padding(.trailing, 14)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                ForEach(archived) { thread in
                    threadRow(thread, project: project, isArchived: true)
                }
            }
        }
    }

    private func threadRow(_ thread: AgentThread, project: AgentProject, isArchived: Bool) -> some View {
        ProjectThreadRow(
            title: thread.title,
            age: relativeAge(thread.lastModified),
            isSelected: thread.id == currentThreadId,
            isBusy: busyThreadIds.contains(thread.id),
            hasUnreadReady: thread.hasUnreadReady && thread.id != currentThreadId,
            isArchived: isArchived,
            onSelect: { onSelectThread(thread, project) },
            onRename: { onRenameThread(thread.id, thread.title) },
            onArchive: { onArchiveThread(thread.id) },
            onUnarchive: { onUnarchiveThread(thread.id) },
            onDelete: { onDeleteThread(thread.id) }
        )
    }

    private var settingsRow: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: onOpenSettings) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings")
                            .font(.system(size: 14, weight: .medium))
                        Text(accountSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundStyle(.primary.opacity(0.88))
                .padding(.horizontal, 16)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(accountSubtitle)
        }
        .frame(height: 64)
    }

    private func isExpanded(_ project: AgentProject) -> Bool {
        expandedProjects.contains(project.id) || project.id == selectedProjectId
    }

    private func toggle(_ id: UUID) {
        if expandedProjects.contains(id) { expandedProjects.remove(id) }
        else { expandedProjects.insert(id) }
    }

    private var accountSubtitle: String {
        if authManager.isUsingGrokBuildSession, let session = authManager.currentSession {
            if session.isSuperHeavy { return "Super Heavy • Tier 5" }
            if let tier = session.tier { return "Grok Build • Tier \(tier)" }
            return "Grok Build session"
        }
        if hasAPIKey { return "Signed in via API key" }
        return "Run grok login to connect"
    }

    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let onOpenDroppedFolder else { return false }
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            let url: URL? = {
                if let data = item as? Data {
                    return URL(dataRepresentation: data, relativeTo: nil)
                }
                if let url = item as? URL { return url }
                if let str = item as? String { return URL(fileURLWithPath: str) }
                return nil
            }()
            guard let url else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return }
            DispatchQueue.main.async {
                onOpenDroppedFolder(url)
            }
        }
        return true
    }
}

// MARK: - Rows

private struct ProjectHeaderRow: View {
    let project: AgentProject
    let isExpanded: Bool
    let isSelected: Bool
    let isBusy: Bool
    let unreadCount: Int
    let folderMissing: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onNewThread: () -> Void
    let onNewWorktree: () -> Void
    let onSwitchBranch: () -> Void
    let onTogglePin: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: folderMissing ? "folder.badge.questionmark" : "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(folderMissing ? Color.orange : Color.primary.opacity(0.84))
                .frame(width: 17)
            if project.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 10, height: 10)
                    .help("Agent working in this project")
            } else if unreadCount > 0 {
                Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                    .help("\(unreadCount) chat\(unreadCount == 1 ? "" : "s") ready")
            }
            Spacer(minLength: 0)
            if let branch = project.gitBranch, !branch.isEmpty, !(isHovered || isSelected) {
                Text(branch)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isHovered || isSelected {
                Button(action: onTogglePin) {
                    Image(systemName: project.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(project.isPinned ? "Unpin" : "Pin to top")

                Button(action: onNewThread) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New chat")

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from sidebar")
            }
        }
        .foregroundStyle(.primary.opacity(0.84))
        .padding(.horizontal, 16)
        .frame(height: 27)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
            if !isExpanded { onToggle() }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("New Chat", action: onNewThread)
            Button(project.isPinned ? "Unpin" : "Pin to Top", action: onTogglePin)
            Button(isExpanded ? "Collapse" : "Expand", action: onToggle)
            Divider()
            Button("New Worktree…", action: onNewWorktree)
            Button("Switch Branch…", action: onSwitchBranch)
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
            Divider()
            Button("Remove from Sidebar…", role: .destructive, action: onRemove)
        }
    }

    private var rowBackground: Color {
        if isSelected { return BuildPalette.rowSelected }
        if isHovered { return BuildPalette.rowHover }
        return .clear
    }
}

private struct ProjectThreadRow: View {
    let title: String
    let age: String
    let isSelected: Bool
    let isBusy: Bool
    let hasUnreadReady: Bool
    let isArchived: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onArchive: () -> Void
    let onUnarchive: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if hasUnreadReady {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            } else if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
            }

            Text(title.isEmpty ? "New Thread" : title)
                .font(.system(size: 13, weight: isSelected || hasUnreadReady ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 2) {
                    if isArchived {
                        rowActionButton(systemName: "arrow.uturn.backward", help: "Restore", action: onUnarchive)
                    } else {
                        rowActionButton(systemName: "archivebox", help: "Archive", action: onArchive)
                    }
                    rowActionButton(systemName: "pencil", help: "Rename", action: onRename)
                    rowActionButton(systemName: "trash", help: "Delete", action: onDelete)
                }
            } else {
                Text(age)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.78))
        .padding(.leading, hasUnreadReady || isBusy ? 34 : 50)
        .padding(.trailing, 10)
        .frame(height: 29)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            if isArchived {
                Button("Restore", action: onUnarchive)
            } else {
                Button("Archive", action: onArchive)
            }
            Button("Rename", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if isArchived {
                Button("Restore", action: onUnarchive)
                    .tint(.accentColor)
            } else {
                Button("Archive", action: onArchive)
                    .tint(.orange)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func rowActionButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var rowBackground: Color {
        if isSelected { return BuildPalette.rowSelected }
        if isHovered { return BuildPalette.rowHover }
        return .clear
    }
}

private func relativeAge(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(max(1, seconds))s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 30 { return "\(days)d" }
    let months = days / 30
    if months < 12 { return "\(months)mo" }
    return "\(months / 12)y"
}
