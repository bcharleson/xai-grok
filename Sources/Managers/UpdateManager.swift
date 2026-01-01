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

/// Manages application updates using Sparkle framework
class UpdateManager: NSObject {
    
    static let shared = UpdateManager()
    
    /// The Sparkle updater controller
    private var updaterController: SPUStandardUpdaterController!
    
    /// The underlying updater for programmatic access
    var updater: SPUUpdater {
        return updaterController.updater
    }
    
    private override init() {
        super.init()

        // Initialize Sparkle with standard UI
        // startingUpdater: true enables the updater so it can check for updates
        // This is REQUIRED for both manual and automatic update checks to work
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }
    
    // MARK: - Public Methods
    
    /// Check for updates (called from menu item)
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
    
    /// Check for updates silently in background
    func checkForUpdatesInBackground() {
        updater.checkForUpdatesInBackground()
    }
    
    /// Returns true if an update check can be performed
    var canCheckForUpdates: Bool {
        return updater.canCheckForUpdates
    }
    
    /// Configure automatic update settings
    func configureAutomaticUpdates(enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }
    
    /// Configure automatic download of updates
    func configureAutomaticDownloads(enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
    }
    
    /// Set the update check interval (in seconds)
    func setUpdateCheckInterval(_ interval: TimeInterval) {
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

