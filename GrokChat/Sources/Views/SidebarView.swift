import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                chatViewModel.newChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: selection) {
                ForEach(chatViewModel.chats) { chat in
                    Text(chat.title)
                        .lineLimit(1)
                        .tag(chat.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                chatViewModel.deleteChat(chat)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220)
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { chatViewModel.currentChat?.id },
            set: { id in
                guard let id,
                      let chat = chatViewModel.chats.first(where: { $0.id == id }) else { return }
                chatViewModel.selectChat(chat)
            }
        )
    }
}
