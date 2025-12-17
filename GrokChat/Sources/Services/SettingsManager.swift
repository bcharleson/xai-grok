import Foundation
import SwiftUI

class SettingsManager: ObservableObject {
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("selectedModel") var selectedModel: String = "grok-beta"
    @AppStorage("temperature") var temperature: Double = 0.7
    @AppStorage("streamResponses") var streamResponses: Bool = true
    @AppStorage("fontSize") var fontSize: Double = 14
    @AppStorage("colorScheme") var colorScheme: String = "system"
    
    static let availableModels = [
        "grok-beta",
        "grok-2",
        "grok-2-mini"
    ]
    
    var isAPIKeySet: Bool {
        !apiKey.isEmpty
    }
    
    func resetToDefaults() {
        selectedModel = "grok-beta"
        temperature = 0.7
        streamResponses = true
        fontSize = 14
        colorScheme = "system"
    }
}