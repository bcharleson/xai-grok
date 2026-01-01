import SwiftUI

// Note: This view is not currently used - DeveloperRootView is the main view
// Keeping this as a placeholder for potential future use

struct ContentView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settingsManager: SettingsManager

    var body: some View {
        Text("ContentView - Not in use")
            .frame(minWidth: 800, minHeight: 600)
    }
}
