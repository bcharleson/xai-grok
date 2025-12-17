import SwiftUI

struct ContentView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settingsManager: SettingsManager
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ChatView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            chatViewModel.setAPIKey(settingsManager.apiKey)
        }
        .onChange(of: settingsManager.apiKey) { newValue in
            chatViewModel.setAPIKey(newValue)
        }
    }
}