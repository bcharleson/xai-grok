import Foundation
import SwiftUI
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var currentChat: Chat?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentStreamingMessage: String = ""
    
    private let apiService = GrokAPIService()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadChats()
        if chats.isEmpty {
            newChat()
        } else {
            currentChat = chats.first
        }
    }
    
    func setAPIKey(_ key: String) {
        apiService.setAPIKey(key)
    }
    
    func newChat() {
        let chat = Chat()
        chats.insert(chat, at: 0)
        currentChat = chat
        saveChats()
    }
    
    func sendMessage(_ content: String) async {
        guard let currentChat = currentChat else { return }
        
        let userMessage = Message(role: .user, content: content)
        self.currentChat?.messages.append(userMessage)
        
        isLoading = true
        errorMessage = nil
        currentStreamingMessage = ""
        
        let assistantMessage = Message(role: .assistant, content: "")
        self.currentChat?.messages.append(assistantMessage)
        
        do {
            var fullResponse = ""
            
            for try await chunk in apiService.sendMessage(messages: currentChat.messages.dropLast()) {
                fullResponse += chunk
                currentStreamingMessage = fullResponse
                
                // Safely update the last message without force-unwrapping
                if var chat = self.currentChat,
                   let lastIndex = chat.messages.indices.last,
                   let lastMessage = chat.messages.last {
                    chat.messages[lastIndex] = Message(
                        id: lastMessage.id,
                        role: lastMessage.role,
                        content: fullResponse,
                        timestamp: lastMessage.timestamp
                    )
                    self.currentChat = chat
                }
            }
            
            updateChatTitle(for: currentChat)
            saveChats()
        } catch {
            errorMessage = error.localizedDescription
            if self.currentChat?.messages.count ?? 0 > 0 {
                self.currentChat?.messages.removeLast()
            }
        }
        
        isLoading = false
        currentStreamingMessage = ""
    }
    
    func deleteChat(_ chat: Chat) {
        chats.removeAll { $0.id == chat.id }
        if currentChat?.id == chat.id {
            currentChat = chats.first
        }
        saveChats()
    }
    
    func selectChat(_ chat: Chat) {
        currentChat = chat
    }
    
    private func updateChatTitle(for chat: Chat) {
        guard var updatedChat = chats.first(where: { $0.id == chat.id }),
              updatedChat.title == "New Chat",
              let firstUserMessage = updatedChat.messages.first(where: { $0.role == .user }) else { return }
        
        let title = String(firstUserMessage.content.prefix(50))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !title.isEmpty {
            updatedChat.title = title
            updatedChat.updatedAt = Date()
            
            if let index = chats.firstIndex(where: { $0.id == chat.id }) {
                chats[index] = updatedChat
                if currentChat?.id == chat.id {
                    currentChat = updatedChat
                }
            }
        }
    }
    
    private func saveChats() {
        if let encoded = try? JSONEncoder().encode(chats) {
            UserDefaults.standard.set(encoded, forKey: "saved_chats")
        }
    }
    
    private func loadChats() {
        if let data = UserDefaults.standard.data(forKey: "saved_chats"),
           let decoded = try? JSONDecoder().decode([Chat].self, from: data) {
            chats = decoded
        }
    }
}