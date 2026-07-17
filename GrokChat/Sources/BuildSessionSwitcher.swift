import SwiftUI

/// Cmd+K palette: jump across projects and chats in the Build harness.
struct BuildSessionSwitcher: View {
    @ObservedObject var store: WorkspaceStore
    var busyThreadIds: Set<UUID>
    var currentThreadId: UUID
    var onSelect: (AgentThread, AgentProject) -> Void
    var onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private struct Row: Identifiable {
        let id: UUID
        let project: AgentProject
        let thread: AgentThread
        var title: String { thread.title.isEmpty ? "New Chat" : thread.title }
        var subtitle: String { project.name }
    }

    private var rows: [Row] {
        var result: [Row] = []
        for project in store.topLevelProjects() {
            for thread in store.activeThreads(for: project) {
                result.append(Row(id: thread.id, project: project, thread: thread))
            }
            for worktree in store.worktrees(forRepoPath: project.path) {
                for thread in store.activeThreads(for: worktree) {
                    result.append(Row(id: thread.id, project: worktree, thread: thread))
                }
            }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return result }
        return result.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
                || $0.project.path.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to project or chat…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isFieldFocused)
                    .onSubmit { selectFirst() }
                Button("Esc", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text(query.isEmpty ? "No sessions yet" : "No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(20)
                    } else {
                        ForEach(rows) { row in
                            Button {
                                onSelect(row.thread, row.project)
                                onDismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    if busyThreadIds.contains(row.thread.id) {
                                        ProgressView().controlSize(.mini)
                                    } else if row.thread.hasUnreadReady && row.thread.id != currentThreadId {
                                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                                    } else {
                                        Image(systemName: "bubble.left")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 12)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.title)
                                            .font(.system(size: 13, weight: row.thread.id == currentThreadId ? .semibold : .regular))
                                            .lineLimit(1)
                                        Text(row.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if row.thread.id == currentThreadId {
                                        Text("Current")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    row.thread.id == currentThreadId
                                        ? BuildPalette.rowSelected
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .onAppear { isFieldFocused = true }
    }

    private func selectFirst() {
        guard let first = rows.first else { return }
        onSelect(first.thread, first.project)
        onDismiss()
    }
}
