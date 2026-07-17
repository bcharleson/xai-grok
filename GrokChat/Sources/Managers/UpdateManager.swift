//
//  UpdateManager.swift
//  Grok for Mac
//
//  Created by Brandon Charleson on 2025.
//  Copyright © 2025 Brandon Charleson. All rights reserved.
//
//  https://github.com/bcharleson/xai-grok
//

import Cocoa
import Sparkle

/// Manages application updates using Sparkle framework.
///
/// Release builds start the updater against the production feed
/// (`https://www.topoffunnel.com/downloads/appcast.xml`).
/// Debug / local fork builds keep Sparkle initialized but do not start
/// background checks so development machines do not hit the live channel.
class UpdateManager: NSObject {

    static let shared = UpdateManager()

    /// The Sparkle updater controller
    private var updaterController: SPUStandardUpdaterController!

    /// True when Info.plist has a real feed URL and ED25519 public key.
    private let isConfiguredForUpdates: Bool

    /// True when the updater has been started (Release + configured).
    private(set) var isUpdaterRunning: Bool = false

    /// The underlying updater for programmatic access
    var updater: SPUUpdater {
        return updaterController.updater
    }

    private override init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let hasRealFeed = !feed.isEmpty
            && !feed.contains("example.com")
            && feed.hasPrefix("https://")
        let hasRealKey = !key.isEmpty
            && !key.contains("YOUR_PUBLIC_KEY")
            && key.count >= 32
        isConfiguredForUpdates = hasRealFeed && hasRealKey

        super.init()

        #if DEBUG
        let shouldStart = false
        #else
        let shouldStart = isConfiguredForUpdates
        #endif

        updaterController = SPUStandardUpdaterController(
            startingUpdater: shouldStart,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        isUpdaterRunning = shouldStart

        #if DEBUG
        print("[UpdateManager] Debug build — Sparkle not started (feed=\(feed))")
        #endif
    }

    // MARK: - Public Methods

    /// Check for updates (called from menu item)
    @objc func checkForUpdates(_ sender: Any?) {
        guard isConfiguredForUpdates else {
            #if DEBUG
            print("[UpdateManager] Skipping update check — Sparkle not configured")
            #endif
            return
        }
        if !isUpdaterRunning {
            do {
                try updaterController.updater.start()
                isUpdaterRunning = true
            } catch {
                #if DEBUG
                print("[UpdateManager] Failed to start updater: \(error.localizedDescription)")
                #endif
                return
            }
        }
        updaterController.checkForUpdates(sender)
    }

    /// Check for updates silently in background
    func checkForUpdatesInBackground() {
        guard isConfiguredForUpdates, isUpdaterRunning else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Returns true if an update check can be performed
    var canCheckForUpdates: Bool {
        guard isConfiguredForUpdates else { return false }
        return updater.canCheckForUpdates
    }

    /// Configure automatic update settings
    func configureAutomaticUpdates(enabled: Bool) {
        guard isConfiguredForUpdates else { return }
        updater.automaticallyChecksForUpdates = enabled
    }

    /// Configure automatic download of updates
    func configureAutomaticDownloads(enabled: Bool) {
        guard isConfiguredForUpdates else { return }
        updater.automaticallyDownloadsUpdates = enabled
    }

    /// Set the update check interval (in seconds)
    func setUpdateCheckInterval(_ interval: TimeInterval) {
        guard isConfiguredForUpdates else { return }
        updater.updateCheckInterval = interval
    }

    /// Get current app version string
    var currentVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Get current build number
    var currentBuild: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

// MARK: - SPUUpdaterDelegate
extension UpdateManager: SPUUpdaterDelegate {

    /// Called when a valid update is found
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        #if DEBUG
        print("[UpdateManager] Found valid update: \(item.displayVersionString) (build \(item.versionString))")
        #endif
    }

    /// Called when no update is found
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        #if DEBUG
        print("[UpdateManager] No update available or error: \(error.localizedDescription)")
        #endif
    }

    /// Called when update check fails
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        #if DEBUG
        print("[UpdateManager] Update aborted: \(error.localizedDescription)")
        #endif
    }

    /// Called when update is about to be installed
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        #if DEBUG
        print("[UpdateManager] Will install update: \(item.displayVersionString)")
        #endif
    }
}
