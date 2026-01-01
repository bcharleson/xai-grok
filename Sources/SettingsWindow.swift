//
//  SettingsWindow.swift
//  Grok for Mac
//
//  Created by Brandon Charleson on 2025.
//  Copyright © 2025 Brandon Charleson. All rights reserved.
//
//  https://github.com/bcharleson/xai-grok
//

import Cocoa
import ServiceManagement
import Sparkle
import WebKit

class SettingsWindow: NSWindow {
    
    private var apiKeyField: NSSecureTextField!
    private var safetyCheckbox: NSButton!
    private var retentionPopup: NSPopUpButton!
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 350),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = "Settings"
        self.center()
        self.isReleasedWhenClosed = false
        setupUI()
    }
    
    private func setupUI() {
        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        tabView.autoresizingMask = [.width, .height]
        
        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = createGeneralView()
        
        let grokItem = NSTabViewItem(identifier: "grok")
        grokItem.label = "Grok Code"
        grokItem.view = createGrokView()
        
        tabView.addTabViewItem(generalItem)
        tabView.addTabViewItem(grokItem)
        
        self.contentView = tabView
    }
    
    private func createGeneralView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        
        let stack = NSStackView(frame: container.bounds.insetBy(dx: 40, dy: 40))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        
        // Launch at Login
        let launchToggle = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stack.addArrangedSubview(launchToggle)
        
        // Menu Bar Icon (default to ON if key doesn't exist)
        let menuBarToggle = NSButton(checkboxWithTitle: "Show in Menu Bar", target: self, action: #selector(toggleMenuBarIcon(_:)))
        let showMenuBar = UserDefaults.standard.object(forKey: "showMenuBarIcon") == nil ? true : UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        menuBarToggle.state = showMenuBar ? .on : .off
        stack.addArrangedSubview(menuBarToggle)
        
        // Auto-update
        let autoUpdateToggle = NSButton(checkboxWithTitle: "Automatically check for updates", target: self, action: #selector(toggleAutoUpdate(_:)))
        autoUpdateToggle.state = UpdateManager.shared.updater.automaticallyChecksForUpdates ? .on : .off
        stack.addArrangedSubview(autoUpdateToggle)
        
        stack.addArrangedSubview(createSeparator())
        
        // Global Shortcut
        let shortcutsLabel = NSTextField(labelWithString: "Global Shortcut")
        shortcutsLabel.font = .systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(shortcutsLabel)
        
        let hotkeyDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
        hotkeyDropdown.addItems(withTitles: [
            "Option + Space",
            "Control + Space",
            "Command + Shift + G",
            "Option + G"
        ])
        hotkeyDropdown.selectItem(at: UserDefaults.standard.integer(forKey: "hotkeyPreset"))
        hotkeyDropdown.target = self
        hotkeyDropdown.action = #selector(hotkeyChanged(_:))
        stack.addArrangedSubview(hotkeyDropdown)
        
        stack.addArrangedSubview(createSeparator())
        
        // Updates
        let updatesLabel = NSTextField(labelWithString: "Updates")
        updatesLabel.font = .systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(updatesLabel)
        
        let versionString = "Version \(UpdateManager.shared.currentVersion) (Build \(UpdateManager.shared.currentBuild))"
        let versionLabel = NSTextField(labelWithString: versionString)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)
        
        let updateButton = NSButton(title: "Check for Updates...", target: self, action: #selector(checkForUpdates(_:)))
        updateButton.bezelStyle = .rounded
        stack.addArrangedSubview(updateButton)
        
        return container
    }
    
    private func createGrokView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 350))
        
        let stack = NSStackView(frame: container.bounds.insetBy(dx: 40, dy: 40))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        
        // API Key Section
        let apiLabel = NSTextField(labelWithString: "Grok API Key")
        apiLabel.font = .systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(apiLabel)
        
        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "sk-..."
        apiKeyField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged(_:))
        // Load API key from Keychain (secure storage)
        if let key = KeychainHelper.shared.getAPIKey() {
            apiKeyField.stringValue = key
        }
        stack.addArrangedSubview(apiKeyField)
        
        stack.addArrangedSubview(createSeparator())
        
        // Security Section
        let securityLabel = NSTextField(labelWithString: "Security & Safety")
        securityLabel.font = .systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(securityLabel)
        
        safetyCheckbox = NSButton(checkboxWithTitle: "Enable Safety Mode (Block destructive commands)", target: self, action: #selector(safetyToggled(_:)))
        // Check if key exists, if not use default of true (ON)
        if UserDefaults.standard.object(forKey: "safetyEnabled") == nil {
            safetyCheckbox.state = .on // Default: ON
        } else {
            safetyCheckbox.state = UserDefaults.standard.bool(forKey: "safetyEnabled") ? .on : .off
        }
        stack.addArrangedSubview(safetyCheckbox)
        
        stack.addArrangedSubview(createSeparator())
        
        // History Section
        let historyLabel = NSTextField(labelWithString: "Chat History")
        historyLabel.font = .systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(historyLabel)
        
        let retentionStack = NSStackView()
        retentionStack.orientation = .horizontal
        retentionStack.spacing = 8
        
        retentionStack.addArrangedSubview(NSTextField(labelWithString: "Retention Policy:"))
        
        retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        retentionPopup.addItem(withTitle: "Forever") // Tag 0
        retentionPopup.addItem(withTitle: "7 Days")  // Tag 7
        retentionPopup.addItem(withTitle: "30 Days") // Tag 30
        
        // Map tags to items
        retentionPopup.item(at: 0)?.tag = 0
        retentionPopup.item(at: 1)?.tag = 7
        retentionPopup.item(at: 2)?.tag = 30
        
        // Select current
        let currentRetention = UserDefaults.standard.integer(forKey: "chatRetentionDays")
        if currentRetention == 7 { retentionPopup.selectItem(withTag: 7) }
        else if currentRetention == 30 { retentionPopup.selectItem(withTag: 30) }
        else { retentionPopup.selectItem(withTag: 0) }
        
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged(_:))
        retentionStack.addArrangedSubview(retentionPopup)
        
        stack.addArrangedSubview(retentionStack)
        
        let clearButton = NSButton(title: "Clear All History", target: self, action: #selector(clearHistory(_:)))
        clearButton.bezelStyle = .rounded
        stack.addArrangedSubview(clearButton)
        
        return container
    }
    
    private func createSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
    
    // MARK: - Actions
    
    @objc func apiKeyChanged(_ sender: NSSecureTextField) {
        // Save API key to Keychain (secure storage)
        let key = sender.stringValue
        if key.isEmpty {
            KeychainHelper.shared.deleteAPIKey()
        } else {
            KeychainHelper.shared.saveAPIKey(key)
        }
        // Notify the app that API key changed
        NotificationCenter.default.post(name: Notification.Name("APIKeyChanged"), object: key)
    }
    
    @objc func safetyToggled(_ sender: NSButton) {
        let isEnabled = sender.state == .on
        UserDefaults.standard.set(isEnabled, forKey: "safetyEnabled")
        // Force update across app
        NotificationCenter.default.post(name: Notification.Name("SafetyModeChanged"), object: isEnabled)
    }
    
    @objc func retentionChanged(_ sender: NSPopUpButton) {
        guard let selectedItem = sender.selectedItem else { return }
        UserDefaults.standard.set(selectedItem.tag, forKey: "chatRetentionDays")
    }
    
    @objc func clearHistory(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Clear all chat history?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // Clear WebKit data stores
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            let date = Date(timeIntervalSince1970: 0)
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: date) {
                // Notify that history was cleared
                NotificationCenter.default.post(name: Notification.Name("ReloadGrokHistory"), object: nil)
            }
        }
    }
    
    @objc func toggleMenuBarIcon(_ sender: NSButton) {
        let isOn = sender.state == .on
        UserDefaults.standard.set(isOn, forKey: "showMenuBarIcon")
        if let appDelegate = NSApp.delegate as? AppDelegate {
            if isOn { appDelegate.showStatusBar() } else { appDelegate.hideStatusBar() }
        }
    }
    
    @objc func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            #if DEBUG
            print("Failed to toggle launch at login: \(error)")
            #endif
        }
    }
    
    @objc func toggleAutoUpdate(_ sender: NSButton) {
        UpdateManager.shared.configureAutomaticUpdates(enabled: sender.state == .on)
    }
    
    @objc func hotkeyChanged(_ sender: NSPopUpButton) {
        if let preset = HotKeyManager.ShortcutPreset(rawValue: sender.indexOfSelectedItem) {
            HotKeyManager.shared.setPreset(preset)
        }
    }
    
    @objc func checkForUpdates(_ sender: Any?) {
        UpdateManager.shared.checkForUpdates(sender)
    }
}
