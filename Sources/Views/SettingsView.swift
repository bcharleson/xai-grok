import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var showingAPIKey = false
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            APISettingsView(showingAPIKey: $showingAPIKey)
                .tabItem {
                    Label("API", systemImage: "key")
                }
            
            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $settingsManager.selectedModel) {
                    ForEach(SettingsManager.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                
                HStack {
                    Text("Temperature: \(settingsManager.temperature, specifier: "%.1f")")
                    Slider(value: $settingsManager.temperature, in: 0...2, step: 0.1)
                }
                
                Toggle("Stream responses", isOn: $settingsManager.streamResponses)
            } header: {
                Text("Chat Settings")
                    .font(.headline)
            }
            
            Section {
                Button("Reset to Defaults") {
                    settingsManager.resetToDefaults()
                }
            }
        }
        .padding()
    }
}

struct APISettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Binding var showingAPIKey: Bool
    @State private var tempAPIKey = ""
    
    var body: some View {
        Form {
            Section {
                HStack {
                    if showingAPIKey {
                        TextField("API Key", text: $tempAPIKey)
                            .onAppear {
                                tempAPIKey = settingsManager.apiKey
                            }
                            .onChange(of: tempAPIKey) { _, newValue in
                                settingsManager.apiKey = newValue
                            }
                    } else {
                        SecureField("API Key", text: $tempAPIKey)
                            .onAppear {
                                tempAPIKey = settingsManager.apiKey
                            }
                            .onChange(of: tempAPIKey) { _, newValue in
                                settingsManager.apiKey = newValue
                            }
                    }
                    
                    Button(action: {
                        showingAPIKey.toggle()
                    }) {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
                
                Text("Get your API key from [console.x.ai](https://console.x.ai)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if settingsManager.isAPIKeySet {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API key is set")
                            .font(.caption)
                    }
                }
            } header: {
                Text("xAI API Configuration")
                    .font(.headline)
            }
            
            Section {
                Text("During the beta period, you get $25 of free API credits per month.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Font Size: \(Int(settingsManager.fontSize))")
                    Slider(value: $settingsManager.fontSize, in: 10...20, step: 1)
                }
                
                Picker("Color Scheme", selection: $settingsManager.colorScheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            } header: {
                Text("Appearance")
                    .font(.headline)
            }
        }
        .padding()
    }
}