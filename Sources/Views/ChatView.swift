import SwiftUI

struct ChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            if let currentChat = chatViewModel.currentChat {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(currentChat.messages) { message in
                                MessageView(message: message, isStreaming: 
                                    message.id == currentChat.messages.last?.id && 
                                    chatViewModel.isLoading && 
                                    message.role == .assistant
                                )
                                .id(message.id)
                            }
                            
                            if chatViewModel.isLoading && !chatViewModel.currentStreamingMessage.isEmpty {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Grok is thinking...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: currentChat.messages.count) {
                        withAnimation {
                            proxy.scrollTo(currentChat.messages.last?.id, anchor: .bottom)
                        }
                    }
                }
                
                Divider()
                
                MessageInputView(text: $messageText, isLoading: chatViewModel.isLoading) {
                    Task {
                        await sendMessage()
                    }
                }
                .focused($isTextFieldFocused)
            } else {
                EmptyChatView()
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Error", isPresented: Binding(
            get: { chatViewModel.errorMessage != nil },
            set: { _ in chatViewModel.errorMessage = nil }
        )) {
            Button("OK") {
                chatViewModel.errorMessage = nil
            }
        } message: {
            Text(chatViewModel.errorMessage ?? "An error occurred")
        }
    }
    
    private func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        messageText = ""
        await chatViewModel.sendMessage(text)
    }
}

struct MessageView: View {
    let message: Message
    let isStreaming: Bool
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settingsManager: SettingsManager
    
    var displayContent: String {
        if isStreaming && message.role == .assistant {
            return chatViewModel.currentStreamingMessage.isEmpty ? message.content : chatViewModel.currentStreamingMessage
        }
        return message.content
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .assistant {
                // Grok message on left
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grok")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(Color.gray)  // Secondary gray
                    Text(displayContent)
                        .font(.system(size: CGFloat(settingsManager.fontSize), weight: .regular, design: .default))  // Approx Inter
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.gray.opacity(0.2))  // Gray bubble
                        .cornerRadius(10)
                        .textSelection(.enabled)
                }
                Spacer()
            } else {
                Spacer()
                // User message on right
                VStack(alignment: .trailing, spacing: 4) {
                    Text("You")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(Color.gray)
                    Text(displayContent)
                        .font(.system(size: CGFloat(settingsManager.fontSize), weight: .regular, design: .default))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.blue)  // Blue bubble
                        .cornerRadius(10)
                        .textSelection(.enabled)
                }
            }
            
            Spacer()
            
            Menu {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayContent, forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .opacity(0.6)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(#colorLiteral(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))  // Dark gray bg
    }
}

struct MessageInputView: View {
    @Binding var text: String
    let isLoading: Bool
    let onSubmit: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            TextField("Message Grok...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(8)
                .background(Color.gray.opacity(0.2))  // Gray fill
                .cornerRadius(8)
                .foregroundColor(.white)
                .onSubmit {
                    if !isLoading {
                        onSubmit()
                    }
                }
                .disabled(isLoading)
            
            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)  // Accent blue
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding()
        .background(Color(#colorLiteral(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))  // Dark gray
    }
}

struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No chat selected")
                .font(.title2)
                .foregroundColor(.secondary)
            
            Text("Create a new chat to start")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}