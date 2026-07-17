import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var authManager = GrokBuildAuthManager.shared
    @State private var showingAPIKey = false
    
    var body: some View {
        TabView {
            // Account - Grok Build (primary seamless path)
            AccountSettingsView(authManager: authManager)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
            
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            APISettingsView(showingAPIKey: $showingAPIKey)
                .tabItem {
                    Label("API Key", systemImage: "key")
                }
            
            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Account Settings (Grok Build seamless auth)

struct AccountSettingsView: View {
    @ObservedObject var authManager: GrokBuildAuthManager
    
    var body: some View {
        Form {
            Section {
                if authManager.isUsingGrokBuildSession, let session = authManager.currentSession {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("Active: Grok Build Super Heavy")
                                .font(.headline)
                                .foregroundColor(.green)
                        }
                        
                        if let email = session.email {
                            Text(email)
                                .font(.subheadline)
                        }
                        
                        if session.isSuperHeavy {
                            Text("Tier 5 • Full subscription limits")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        
                        Button("Sign Out of Grok Build") {
                            authManager.signOut()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                } else if let detected = authManager.detectGrokBuildCLISession() {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Grok Build CLI detected on this Mac")
                            .font(.headline)
                        
                        if let email = detected.email {
                            Text(email)
                                .foregroundColor(.secondary)
                        }
                        
                        if detected.isSuperHeavy {
                            Text("Super Heavy (Tier 5) available")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        
                        Button("Continue with Grok Build (Recommended)") {
                            if authManager.importFromGrokBuildCLI() {
                                // Session imported from ~/.grok/auth.json
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Text("This uses your existing Grok Build subscription instead of an API key.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Not connected to Grok Build")
                            .font(.headline)
                        Text("Sign in with the Grok CLI — same OAuth flow as the VS Code extension.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button("Sign in with Grok CLI") {
                            authManager.launchCLILogin()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        
                        Button("I've logged in — import session") {
                            _ = authManager.importFromGrokBuildCLI()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!authManager.hasCLISessionOnDisk)
                    }
                }
            } header: {
                Text("Grok Build Authentication")
                    .font(.headline)
            }
            
            Section {
                Text("For the best experience (Super Heavy limits), use your existing Grok Build CLI or Mac app login. API Key is available as an alternative.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            GrokCLIAdapterTestSection()
        }
        .padding()
    }
}

// MARK: - CLI adapter health check

struct GrokCLIAdapterTestSection: View {
    @State private var isProbing = false
    @State private var probeResult: GrokBuildACPProbeResult?
    @State private var probeError: String?

    private var testFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer", isDirectory: true)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Grok CLI adapter (ACP)")
                    .font(.headline)

                Text("Runs `grok agent stdio` → initialize → session/new → test prompt in \(testFolder.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(isProbing ? "Testing…" : "Test Grok CLI connection") {
                    runProbe()
                }
                .buttonStyle(.bordered)
                .disabled(isProbing || !GrokCLIResolver.isAvailable)

                if !GrokCLIResolver.isAvailable {
                    Text("Grok CLI not found. Install with `curl -fsSL https://grok.com/install.sh | bash` then `grok login`.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if let probeError {
                    Text(probeError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if let result = probeResult {
                    if result.success {
                        Label("Adapter OK", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("initialize \(result.initializeMs)ms · session/new \(result.sessionNewMs ?? 0)ms · prompt \(result.promptMs ?? 0)ms")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let preview = result.responsePreview {
                            Text(String(preview.prefix(120)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Label("Adapter failed", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(result.errorMessage ?? "Unknown error")
                            .font(.caption)
                            .foregroundColor(.red)
                        if let stderr = result.stderr, !stderr.isEmpty {
                            Text(String(stderr.suffix(400)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Diagnostics")
                .font(.headline)
        }
    }

    private func runProbe() {
        isProbing = true
        probeResult = nil
        probeError = nil
        _ = testFolder.startAccessingSecurityScopedResource()
        AgentOrchestrator.shared.runHarnessProbe(projectPath: testFolder) { result in
            isProbing = false
            probeResult = result
        }
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
                            .onChange(of: tempAPIKey) { newValue in
                                settingsManager.apiKey = newValue
                            }
                    } else {
                        SecureField("API Key", text: $tempAPIKey)
                            .onAppear {
                                tempAPIKey = settingsManager.apiKey
                            }
                            .onChange(of: tempAPIKey) { newValue in
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