import SwiftUI

/// Legacy workspace → project → thread sidebar kept for reference while the active
/// Build shell uses `ProjectsSidebarView`.
struct WorkspaceSidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var currentThreadId: UUID
    var onSelectThread: (UUID) -> Void
    var onNewThread: () -> Void
    var onDeleteThread: (UUID) -> Void
    var onRenameThread: (UUID, String) -> Void

    @State private var expandedWorkspaces: Set<UUID> = []
    @State private var expandedProjects: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.snapshot.workspaces) { workspace in
                        workspaceSection(workspace)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Workspaces")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onNewThread) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New Thread")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: AgentWorkspace) -> some View {
        let isExpanded = expandedWorkspaces.contains(workspace.id)
            || store.snapshot.selectedWorkspaceId == workspace.id

        DisclosureGroup(isExpanded: Binding(
            get: { expandedWorkspaces.contains(workspace.id) || store.snapshot.selectedWorkspaceId == workspace.id },
            set: { expanded in
                if expanded { expandedWorkspaces.insert(workspace.id) }
                else { expandedWorkspaces.remove(workspace.id) }
            }
        )) {
            ForEach(workspace.projects) { project in
                projectSection(project, workspaceId: workspace.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(workspace.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .onAppear {
            expandedWorkspaces.insert(workspace.id)
        }
    }

    @ViewBuilder
    private func projectSection(_ project: AgentProject, workspaceId: UUID) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedProjects.contains(project.id) || store.snapshot.selectedProjectId == project.id },
            set: { expanded in
                if expanded { expandedProjects.insert(project.id) }
                else { expandedProjects.remove(project.id) }
            }
        )) {
            ForEach(project.threads) { thread in
                threadRow(thread, project: project, workspaceId: workspaceId)
            }
        } label: {
            Button {
                store.select(workspaceId: workspaceId)
                store.select(projectId: project.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text(project.path)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .onAppear {
            expandedProjects.insert(project.id)
        }
    }

    private func threadRow(_ thread: AgentThread, project: AgentProject, workspaceId: UUID) -> some View {
        let isSelected = thread.id == currentThreadId
        return Button {
            store.select(workspaceId: workspaceId)
            store.select(projectId: project.id)
            store.select(threadId: thread.id)
            onSelectThread(thread.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(thread.messages.count) msgs")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        if thread.backend == .grokACP {
                            Text("CLI")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .cornerRadius(3)
                        }
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") {
                onRenameThread(thread.id, thread.title)
            }
            Button("Delete", role: .destructive) {
                onDeleteThread(thread.id)
            }
        }
    }
}
