import SwiftUI
import AppKit

/// Inline gates shown inside Build when CLI / project / auth need attention.
/// Kept separate so BuildRootView stays focused on workspace chrome.

struct BuildMissingCLIGate: View {
    let onReady: () -> Void

    @State private var phase: Phase = .idle
    @State private var statusMessage = ""
    @State private var automationFailed = false

    private enum Phase {
        case idle
        case installing
        case timedOut
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: phase == .installing ? "arrow.down.circle" : "terminal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: phase == .installing)

            Text(phase == .installing ? "Installing Grok Build…" : "Install Grok Build")
                .font(.title3.weight(.semibold))

            Text(phaseCopy)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            if automationFailed {
                automationHelp
            }

            if phase == .installing {
                ProgressView()
                    .controlSize(.regular)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Finish any prompts in the Terminal window that opened.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 12) {
                    Button("Install Grok CLI") {
                        startInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    Button("I've installed it") {
                        recheck()
                    }
                    .buttonStyle(.bordered)

                    Button("Docs") {
                        NSWorkspace.shared.open(GrokCLIResolver.installDocsURL)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if phase == .timedOut {
                Text("Still not detected. Confirm install finished, then try again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Try again") {
                    phase = .idle
                    automationFailed = false
                    startInstall()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BuildPalette.terminal)
        .onAppear {
            if GrokCLIResolver.isAvailable {
                onReady()
            }
        }
    }

    private var phaseCopy: String {
        switch phase {
        case .idle:
            return "Build uses the official Grok CLI from xAI. One click installs it via Terminal, then this tab opens Grok Build automatically."
        case .installing:
            return "Waiting for the installer to finish. This screen updates as soon as `grok` is on your PATH."
        case .timedOut:
            return "Install may still be running, or the binary landed outside the usual paths."
        }
    }

    private var automationHelp: some View {
        VStack(spacing: 8) {
            Text("Couldn’t control Terminal automatically.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("System Settings → Privacy & Security → Automation → allow Grok to control Terminal. Or install manually from Docs, then click I’ve installed it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Open Automation Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(BuildPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func startInstall() {
        phase = .installing
        automationFailed = false
        statusMessage = "Opening Terminal…"
        let opened = GrokCLIResolver.launchInstall()
        if !opened {
            automationFailed = true
            statusMessage = "Waiting for a manual install…"
        } else {
            statusMessage = "Waiting for grok…"
        }
        GrokCLIResolver.waitUntilAvailable { found in
            if found {
                statusMessage = GrokCLIResolver.version() ?? "Installed"
                onReady()
            } else {
                phase = .timedOut
                statusMessage = ""
            }
        }
    }

    private func recheck() {
        if GrokCLIResolver.isAvailable {
            onReady()
        } else {
            statusMessage = "Still not found — start Install, or check ~/.local/bin/grok"
            phase = .timedOut
        }
    }
}

struct BuildAuthGate: View {
    @ObservedObject var authManager: GrokBuildAuthManager
    let onReady: () -> Void
    let onSkipForNow: () -> Void

    @State private var phase: Phase = .idle
    @State private var automationFailed = false

    private enum Phase {
        case idle
        case waiting
        case timedOut
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: phase == .waiting)

            Text(phase == .waiting ? "Waiting for sign-in…" : "Sign in to Grok Build")
                .font(.title3.weight(.semibold))

            Text(phaseCopy)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            if automationFailed {
                VStack(spacing: 8) {
                    Text("Couldn’t start grok login in Terminal.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Allow Automation for Terminal, or run `grok login` yourself, then click I’ve signed in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(12)
                .background(BuildPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if phase == .waiting {
                ProgressView()
                Text("Complete browser login, then return here — we detect it automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            } else {
                HStack(spacing: 12) {
                    Button("Sign in with Grok") {
                        startLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    Button("I've signed in") {
                        recheck()
                    }
                    .buttonStyle(.bordered)

                    Button("Skip for now") {
                        onSkipForNow()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let error = authManager.lastAuthError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if phase == .timedOut {
                Button("Try sign-in again") {
                    phase = .idle
                    automationFailed = false
                    startLogin()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BuildPalette.terminal)
        .onAppear {
            authManager.syncFromCLIIfNewer()
            if authManager.hasCLISessionOnDisk || authManager.isUsingGrokBuildSession {
                _ = authManager.importFromGrokBuildCLI()
                onReady()
            }
        }
    }

    private var phaseCopy: String {
        switch phase {
        case .idle:
            return "Use the same Grok Build account as the CLI / VS Code extension. Sign-in opens Terminal + browser once."
        case .waiting:
            return "Listening for ~/.grok/auth.json from a successful grok login."
        case .timedOut:
            return "No session detected yet. Finish login in the browser, then try again."
        }
    }

    private func startLogin() {
        phase = .waiting
        automationFailed = false
        let opened = authManager.launchCLILogin()
        if !opened {
            automationFailed = true
        }
        authManager.waitUntilCLISessionAvailable { found in
            if found {
                onReady()
            } else {
                phase = .timedOut
            }
        }
    }

    private func recheck() {
        authManager.syncFromCLIIfNewer()
        if authManager.importFromGrokBuildCLI() || authManager.hasCLISessionOnDisk {
            onReady()
        } else {
            phase = .timedOut
            authManager.lastAuthError = "No login found yet. Finish grok login, then click I've signed in."
        }
    }
}

struct BuildUpdateBanner: View {
    @ObservedObject var updateService: GrokCLIUpdateService
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: updateService.isUpdating ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: updateService.isUpdating)

            VStack(alignment: .leading, spacing: 2) {
                if updateService.isUpdating {
                    Text("Updating Grok Build…")
                        .font(.system(size: 12, weight: .semibold))
                    Text(updateService.statusMessage ?? "Running grok update")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let check = updateService.latestCheck, check.updateAvailable {
                    Text("Grok Build \(check.latestVersion) is available")
                        .font(.system(size: 12, weight: .semibold))
                    Text("You’re on \(check.currentVersion) (\(check.channel)). Update remounts sessions with the new CLI — your projects & chats stay.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(updateService.statusMessage ?? "Grok Build update")
                        .font(.system(size: 12, weight: .semibold))
                }
            }

            Spacer(minLength: 8)

            if updateService.isUpdating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Later") {
                    updateService.dismissPrompt()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Update & Restart") {
                    onUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(BuildPalette.panel)
    }
}

struct BuildOpenFolderGate: View {
    let onOpenFolder: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Your Grok Build harness")
                    .font(.title3.weight(.semibold))
                Text("Open a folder to start a session. Run many projects side by side — each chat is a live official Grok Build TUI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            VStack(alignment: .leading, spacing: 8) {
                emptyHint(icon: "folder.badge.plus", text: "Open Folder from the toolbar or drop a directory here")
                emptyHint(icon: "plus.bubble", text: "⌘N starts another chat in the current project")
                emptyHint(icon: "magnifyingglass", text: "⌘K jumps across all sessions")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(BuildPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button("Open Folder", action: onOpenFolder)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BuildPalette.terminal)
    }

    private func emptyHint(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct BuildConflictBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

struct BuildRemountPausedBanner: View {
    let onRestart: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(.orange)
            Text("Grok Build exited repeatedly. Sessions are paused so we don’t loop.")
                .font(.system(size: 12))
            Spacer(minLength: 8)
            Button("Restart Session", action: onRestart)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(BuildPalette.panel)
    }
}

struct BuildMissingFolderGate: View {
    let projectName: String
    let projectPath: String
    let onRelocate: () -> Void
    let onRemove: () -> Void
    let onOpenOther: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Folder not found")
                .font(.title3.weight(.semibold))
            Text("“\(projectName)” is no longer at this path. Relocate it, remove it from Build, or open a different folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text(projectPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                Button("Relocate Folder", action: onRelocate)
                    .buttonStyle(.borderedProminent)
                Button("Open Other Folder", action: onOpenOther)
                    .buttonStyle(.bordered)
                Button("Remove Project", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BuildPalette.terminal)
    }
}
