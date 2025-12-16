//
//  AppDelegate.swift
//  Grok for Mac
//
//  Created by Brandon Charleson on 2025.
//  Copyright © 2025 Brandon Charleson. All rights reserved.
//
//  https://github.com/bcharleson/xai-grok
//  https://x.com/brandon_ai
//
//  This file is part of Grok for Mac, an unofficial native macOS client
//  for xAI's Grok AI. Grok is a product of xAI (https://x.ai).
//

import Cocoa
import WebKit
import Sparkle
import SwiftUI

enum AppMode {
    case chat
    case developer
    case console
    case grokipedia
    case xTwitter
}

// Shared observable state for mode switching
class AppModeState: ObservableObject {
    static let shared = AppModeState()
    @Published var currentMode: AppMode = .chat
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    // View Management
    var mainContainerView: NSView!
    var webView: WKWebView!
    var grokipediaWebView: WKWebView!
    var xWebView: WKWebView!
    var devViewController: NSHostingController<DeveloperRootView>?
    var currentMode: AppMode = .chat {
        didSet {
            AppModeState.shared.currentMode = currentMode
        }
    }
    
    var inputWindow: InputWindow?
    var settingsWindow: SettingsWindow?
    var aboutWindow: NSWindow?
    var statusItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set Safety Mode default to ON if not already set
        if UserDefaults.standard.object(forKey: "safetyEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "safetyEnabled")
        }
        
        // Initialize Sparkle Update Manager early
        _ = UpdateManager.shared
        
        // Setup the main menu with Edit menu for copy/paste
        setupMainMenu()
        
        // Setup Menu Bar Icon
        setupStatusBar()
        
        // Setup HotKey Manager
        HotKeyManager.shared.delegate = self
        HotKeyManager.shared.setup()
        
        // Create the main window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "" // Hide title for cleaner look
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("GrokMainWindow")
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 800, height: 600)
        window.isOpaque = true
        window.isReleasedWhenClosed = false // Keep window in memory when closed
        
        // Configure WebView
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        // Enable media capture (microphone, camera)
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.uiDelegate = self
        webView.navigationDelegate = self // For downloads
        
        // Create toolbar with compact style for tighter appearance
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact // Tighter/smaller toolbar
        
        // Set up Container View
        mainContainerView = NSView(frame: .zero)
        mainContainerView.autoresizingMask = [.width, .height]
        window.contentView = mainContainerView

        // Settings webView scaling
        webView.autoresizingMask = [.width, .height]
        webView.frame = mainContainerView.bounds
        mainContainerView.addSubview(webView)

        // Pre-load Developer View (Grok Code Agent)
        let devView = NSHostingController(rootView: DeveloperRootView())
        devView.view.autoresizingMask = [.width, .height]
        devView.view.frame = mainContainerView.bounds
        self.devViewController = devView

        // Setup Grokipedia WebView (separate config for isolated session)
        let grokipediaConfig = WKWebViewConfiguration()
        grokipediaConfig.websiteDataStore = .default()
        grokipediaConfig.mediaTypesRequiringUserActionForPlayback = []
        let grokipediaPrefs = WKWebpagePreferences()
        grokipediaPrefs.allowsContentJavaScript = true
        grokipediaConfig.defaultWebpagePreferences = grokipediaPrefs
        
        grokipediaWebView = WKWebView(frame: .zero, configuration: grokipediaConfig)
        grokipediaWebView.allowsBackForwardNavigationGestures = true
        grokipediaWebView.allowsLinkPreview = true
        grokipediaWebView.uiDelegate = self
        grokipediaWebView.navigationDelegate = self
        grokipediaWebView.autoresizingMask = [.width, .height]
        grokipediaWebView.frame = mainContainerView.bounds
        // Don't add as subview initially - just load
        
        // Pre-load Grokipedia
        if let grokipediaURL = URL(string: "https://grokipedia.com") {
            grokipediaWebView.load(URLRequest(url: grokipediaURL))
        }
        
        // Setup X.com WebView (separate config for isolated session)
        let xConfig = WKWebViewConfiguration()
        xConfig.websiteDataStore = .default()
        xConfig.mediaTypesRequiringUserActionForPlayback = []
        let xPrefs = WKWebpagePreferences()
        xPrefs.allowsContentJavaScript = true
        xConfig.defaultWebpagePreferences = xPrefs
        
        xWebView = WKWebView(frame: .zero, configuration: xConfig)
        xWebView.allowsBackForwardNavigationGestures = true
        xWebView.allowsLinkPreview = true
        xWebView.uiDelegate = self
        xWebView.navigationDelegate = self
        xWebView.autoresizingMask = [.width, .height]
        xWebView.frame = mainContainerView.bounds
        
        // Pre-load X.com
        if let xURL = URL(string: "https://x.com") {
            xWebView.load(URLRequest(url: xURL))
        }
        
        // Load Grok Chat
        if let url = URL(string: "https://grok.com") {
            webView.load(URLRequest(url: url))
        }
        
        // Show window and make key
        window.makeKeyAndOrderFront(nil)
        
        // Make the webview the first responder
        window.makeFirstResponder(webView)
        
        // Initialize Input Window (hidden by default)
        inputWindow = InputWindow()
    }
    
    func setupStatusBar() {
        // Check if user wants menu bar icon (default to true)
        if !UserDefaults.standard.bool(forKey: "showMenuBarIcon") && UserDefaults.standard.object(forKey: "showMenuBarIcon") != nil {
            return // User explicitly disabled it
        }
        
        // Set default to true on first launch
        if UserDefaults.standard.object(forKey: "showMenuBarIcon") == nil {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        }
        
        showStatusBar()
    }
    
    func showStatusBar() {
        if statusItem != nil { return } // Already showing
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            // Use custom MenuBarIcon if available, otherwise SF Symbol
            if let iconImage = NSImage(named: "MenuBarIcon") {
                iconImage.size = NSSize(width: 18, height: 18)
                button.image = iconImage
            } else {
                // Fallback: waveform.path looks similar to Grok's wavy logo
                button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Grok")
            }
        }
        
        // Create menu
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Grok", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Quick Query", action: #selector(toggleInputWindow(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Grok", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        statusItem.menu = menu
    }
    
    func hideStatusBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    
    @objc func showMainWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Grok", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",") // Cmd+, for settings
        
        // Check for Updates menu item
        let updateMenuItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateMenuItem.target = self
        appMenu.addItem(updateMenuItem)
        
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Grok", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Quick Query", action: #selector(toggleInputWindow(_:)), keyEquivalent: " ") // Option+Space is handled by HotKeyManager, this is a menu item backup
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(performClose(_:)), keyEquivalent: "w")
        
        // Edit Menu - Critical for copy/paste
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=") // Cmd+= is standard
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        
        // History Menu
        let historyMenuItem = NSMenuItem()
        mainMenu.addItem(historyMenuItem)
        let historyMenu = NSMenu(title: "History")
        historyMenuItem.submenu = historyMenu
        historyMenu.addItem(withTitle: "Back", action: #selector(goBack(_:)), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]")
        historyMenu.addItem(NSMenuItem.separator())
        historyMenu.addItem(withTitle: "Home", action: #selector(goHome(_:)), keyEquivalent: "H")
        
        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        
        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }
    
    // Don't quit when the "x" is clicked, just close the window
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep app running for hotkey support
    }
    
    // Re-open window when clicking Dock icon
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Check if window exists and is valid
            if window == nil || !window.isVisible {
                window?.makeKeyAndOrderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
    
    @objc func performClose(_ sender: Any?) {
        window?.orderOut(sender)
    }
    
    @objc func checkForUpdates(_ sender: Any?) {
        UpdateManager.shared.checkForUpdates(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleInputWindow(_ sender: Any?) {
        guard let panel = inputWindow else { return }
        
        if panel.isVisible {
            panel.orderOut(nil)
            // If main window is hidden, we effectively hide the app
            if !window.isVisible {
                NSApp.hide(nil)
            }
        } else {
            // Logic to prevent main window from jumping to front if we just want Spotlight
            // Check if app is already active
            let wasActive = NSApp.isActive
            
            if !wasActive {
                // If coming from background, we ONLY want the input window
                // So momentarily hide the main window if it's open, to prevent it jumping up
                if window.isVisible {
                    window.orderOut(nil)
                }
            }
            
            // Center floating panel on screen
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let panelRect = panel.frame
                let x = screenRect.midX - (panelRect.width / 2)
                let y = screenRect.midY + (screenRect.height / 4)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            
            // Show panel on top without affecting main window
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeFirstResponder(panel.textField)
        }
    }
    
    func submitQuery(_ query: String, to mode: AppMode = .chat) {
        // 1. Hide input window
        inputWindow?.orderOut(nil)
        
        // 2. Show main window and switch to target mode
        window.makeKeyAndOrderFront(nil)
        window.alphaValue = 1.0 // Ensure it's visible
        NSApp.activate(ignoringOtherApps: true)
        updateMode(to: mode)
        
        // 3. Route based on mode
        switch mode {
        case .xTwitter:
            // Search on X.com
            let searchURL = "https://x.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            if let url = URL(string: searchURL) {
                xWebView.load(URLRequest(url: url))
            }

        case .developer:
            // Send to Grok Code via notification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: Notification.Name("SpotlightQuery"), object: query)
            }

        case .grokipedia:
            // React-compatible input value setting + button click
            let escapedQuery = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let js = """
            (function() {
                var input = document.querySelector('input[type="text"]') || 
                            document.querySelector('textarea') ||
                            document.querySelector('input');
                
                if (input) {
                    // React-compatible value setting
                    var nativeInputValueSetter = Object.getOwnPropertyDescriptor(
                        window.HTMLInputElement.prototype, 
                        'value'
                    ).set;
                    nativeInputValueSetter.call(input, "\(escapedQuery)");
                    
                    // Trigger React events
                    input.dispatchEvent(new Event('input', { bubbles: true }));
                    input.dispatchEvent(new Event('change', { bubbles: true }));
                    
                    // Wait longer, then click submit button
                    setTimeout(() => {
                        var button = document.querySelector('button[type="submit"]') ||
                                    input.parentElement.querySelector('button') ||
                                    input.closest('form')?.querySelector('button');
                        
                        if (button) {
                            button.click();
                        }
                    }, 300);
                }
            })();
            """
            
            // Wait for page to load, then inject
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.grokipediaWebView.evaluateJavaScript(js, completionHandler: nil)
            }
            
        default: // .chat
            // Inject JS to type and submit to grok.com
            let js = """
            (function() {
                console.log('[GrokApp] Starting injection...');
                
                // Find the input element (textarea or contenteditable)
                var input = document.querySelector('textarea') || 
                            document.querySelector('[contenteditable="true"]') ||
                            document.querySelector('input[type="text"]');
                
                console.log('[GrokApp] Found input:', input);
                
                if (!input) {
                    console.log('[GrokApp] No input found!');
                    return;
                }
                
                input.focus();
                
                // Set value based on element type
                if (input.tagName === 'TEXTAREA' || input.tagName === 'INPUT') {
                    const valueSetter = Object.getOwnPropertyDescriptor(
                        input.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype, 
                        'value'
                    ).set;
                    valueSetter.call(input, \(query.debugDescription));
                    input.dispatchEvent(new Event('input', { bubbles: true }));
                } else {
                    // contenteditable
                    input.textContent = \(query.debugDescription);
                    input.dispatchEvent(new InputEvent('input', { bubbles: true, data: \(query.debugDescription) }));
                }
                
                console.log('[GrokApp] Value set, waiting...');
                
                // Wait for React/framework to process
                setTimeout(() => {
                    // Find ALL buttons and look for the submit one
                    var allButtons = document.querySelectorAll('button');
                    var submitBtn = null;
                    
                    console.log('[GrokApp] Found buttons:', allButtons.length);
                    
                    for (var btn of allButtons) {
                        var label = btn.getAttribute('aria-label') || '';
                        var text = btn.textContent || '';
                        console.log('[GrokApp] Button:', label, text);
                        
                        if (label.toLowerCase().includes('send') || 
                            text.toLowerCase().includes('send') ||
                            btn.querySelector('svg[class*="send"]')) {
                            submitBtn = btn;
                            break;
                        }
                    }
                    
                    // Also try common patterns
                    if (!submitBtn) {
                        submitBtn = document.querySelector('button[type="submit"]') ||
                                    document.querySelector('form button:last-child') ||
                                    document.querySelector('[data-testid="send-button"]');
                    }
                    
                    if (submitBtn && !submitBtn.disabled) {
                        console.log('[GrokApp] Clicking submit button');
                        submitBtn.click();
                    } else {
                        console.log('[GrokApp] No button found, simulating Enter');
                        // Simulate Enter key with all possible event properties
                        var enterEvent = new KeyboardEvent('keydown', {
                            bubbles: true,
                            cancelable: true,
                            key: 'Enter',
                            code: 'Enter',
                            keyCode: 13,
                            which: 13,
                            charCode: 13
                        });
                        input.dispatchEvent(enterEvent);
                        
                        // Also try form submission
                        var form = input.closest('form');
                        if (form) {
                            console.log('[GrokApp] Submitting form');
                            form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
                        }
                    }
                }, 200);
            })();
            """
            
            webView.evaluateJavaScript(js) { (result, error) in
            #if DEBUG
            if let error = error {
                print("JS Injection Error: \(error)")
            } else {
                print("JS executed successfully")
            }
            #endif
            }
        }
    }
    
    // Navigation Methods - works for Chat, Grokipedia, and X
    private var activeWebView: WKWebView {
        switch currentMode {
        case .grokipedia: return grokipediaWebView
        case .xTwitter: return xWebView
        default: return webView
        }
    }
    
    @objc func goBack(_ sender: Any?) { activeWebView.goBack() }
    @objc func goForward(_ sender: Any?) { activeWebView.goForward() }
    @objc func reload(_ sender: Any?) { activeWebView.reload() }
    @objc func goHome(_ sender: Any?) {
        switch currentMode {
        case .grokipedia:
            if let url = URL(string: "https://grokipedia.com") {
                grokipediaWebView.load(URLRequest(url: url))
            }
        case .xTwitter:
            if let url = URL(string: "https://x.com") {
                xWebView.load(URLRequest(url: url))
            }
        default:
            if let url = URL(string: "https://grok.com") {
                webView.load(URLRequest(url: url))
            }
        }
    }
    
    // MARK: - New Actions
    
    var zoomOverlay: NSVisualEffectView?
    var zoomTimer: Timer?
    
    func showZoomOverlay() {
        let percentage = Int(activeWebView.pageZoom * 100)
        
        // Remove existing
        zoomTimer?.invalidate()
        zoomOverlay?.removeFromSuperview()
        
        // Create Glass HUD
        let overlay = NSVisualEffectView()
        overlay.material = .hudWindow
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 10
        overlay.layer?.masksToBounds = true
        
        let width: CGFloat = 80
        let height: CGFloat = 40
        overlay.frame = NSRect(x: 0, y: 0, width: width, height: height)
        
        // Label
        let label = NSTextField(labelWithString: "\(percentage)%")
        label.font = NSFont.systemFont(ofSize: 15, weight: .bold) // Native looking font
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (height - 20) / 2, width: width, height: 20)
        overlay.addSubview(label)
        
        // Center in window
        if let contentView = window.contentView {
            let x = (contentView.bounds.width - width) / 2
            let y = (contentView.bounds.height - height) / 2
            overlay.frame.origin = NSPoint(x: x, y: y)
            contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        
        zoomOverlay = overlay
        
        // Fade out
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self?.zoomOverlay?.animator().alphaValue = 0
            }, completionHandler: {
                self?.zoomOverlay?.removeFromSuperview()
                self?.zoomOverlay = nil
            })
        }
    }
    
    @objc func newChat(_ sender: Any?) {
        if let url = URL(string: "https://grok.com") {
            webView.load(URLRequest(url: url))
        }
    }
    
    @objc func zoomIn(_ sender: Any?) {
        activeWebView.pageZoom += 0.1
        showZoomOverlay()
    }
    
    @objc func zoomOut(_ sender: Any?) {
        activeWebView.pageZoom -= 0.1
        showZoomOverlay()
    }
    
    @objc func resetZoom(_ sender: Any?) {
        activeWebView.pageZoom = 1.0
        showZoomOverlay()
    }

    
    lazy var consoleWebView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let wv = WKWebView(frame: .zero, configuration: config)
        if let url = URL(string: "https://console.x.ai/home") {
            wv.load(URLRequest(url: url))
        }
        wv.autoresizingMask = [.width, .height]
        return wv
    }()
    
    // MARK: - Mode Switching
    
    @objc func switchMode(_ sender: NSSegmentedControl) {
        let mode: AppMode
        switch sender.selectedSegment {
        case 0: mode = .chat
        case 1: mode = .developer
        case 2: mode = .console
        default: return
        }
        updateMode(to: mode)
    }
    
    func updateMode(to mode: AppMode) {
        guard mode != currentMode else { return }
        currentMode = mode
        
        // Remove current view
        mainContainerView.subviews.forEach { $0.removeFromSuperview() }
        
        switch mode {
        case .chat:
            webView.frame = mainContainerView.bounds
            mainContainerView.addSubview(webView)
            window.makeFirstResponder(webView)
        case .developer:
            if let devView = devViewController?.view {
                devView.frame = mainContainerView.bounds
                mainContainerView.addSubview(devView)
                // Focus logic if needed
            }
        case .console:
            consoleWebView.frame = mainContainerView.bounds
            mainContainerView.addSubview(consoleWebView)
            window.makeFirstResponder(consoleWebView)
        case .grokipedia:
            grokipediaWebView.frame = mainContainerView.bounds
            mainContainerView.addSubview(grokipediaWebView)
            window.makeFirstResponder(grokipediaWebView)
        case .xTwitter:
            xWebView.frame = mainContainerView.bounds
            mainContainerView.addSubview(xWebView)
            window.makeFirstResponder(xWebView)
        }
    }
}

// MARK: - NSToolbarDelegate
extension AppDelegate: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        
        // Use smaller symbol configuration for compact buttons
        let smallConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        
        if itemIdentifier == NSToolbarItem.Identifier("back") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Back"
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?.withSymbolConfiguration(smallConfig)
            item.action = #selector(goBack(_:))
            item.target = self
            item.isBordered = true
            return item
        }
        
        if itemIdentifier == NSToolbarItem.Identifier("forward") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Forward"
            item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")?.withSymbolConfiguration(smallConfig)
            item.action = #selector(goForward(_:))
            item.target = self
            item.isBordered = true
            return item
        }
        
        if itemIdentifier == NSToolbarItem.Identifier("reload") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reload"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")?.withSymbolConfiguration(smallConfig)
            item.action = #selector(reload(_:))
            item.target = self
            item.isBordered = true
            return item
        }
        
        if itemIdentifier == NSToolbarItem.Identifier("settings") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?.withSymbolConfiguration(smallConfig)
            item.action = #selector(showSettings(_:))
            item.target = self
            item.isBordered = true
            return item
        }
        
        if itemIdentifier == NSToolbarItem.Identifier("transfer") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Transfer to Code"
            item.image = NSImage(systemSymbolName: "arrow.up.right.diamond", accessibilityDescription: "Transfer Selection")?.withSymbolConfiguration(smallConfig)
            item.action = #selector(transferContext(_:))
            item.target = self
            item.isBordered = true
            item.toolTip = "Move selected text from Chat to Code"
            return item
        }
        
        if itemIdentifier == NSToolbarItem.Identifier("modeSwitch") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            
            let switcher = ToolbarModeSwitcher(onModeChange: { [weak self] newMode in
                self?.updateMode(to: newMode)
            })
            
            let view = NSHostingView(rootView: switcher)
            view.frame = NSRect(x: 0, y: 0, width: 230, height: 30) // Minimalistic: 𝕏 | Grok | Code | Grokipedia
            
            item.view = view
            return item
        }
        
        return nil
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            NSToolbarItem.Identifier("back"),
            NSToolbarItem.Identifier("forward"),
            NSToolbarItem.Identifier("reload"),
            NSToolbarItem.Identifier("transfer"), // New Transfer Button
            .flexibleSpace,
            NSToolbarItem.Identifier("modeSwitch"), // The Toggle
            .flexibleSpace,
            NSToolbarItem.Identifier("settings")
        ]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }
    
    @objc func showAboutPanel(_ sender: Any?) {
        // If window already exists, just bring it to front
        if let existingWindow = aboutWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Create custom About window using NSStackView for proper layout
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Grok for Mac"
        window.center()
        window.isReleasedWhenClosed = false // Prevent premature deallocation

        // Use NSStackView for reliable vertical layout
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 30, left: 40, bottom: 25, right: 40)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // App Icon
        let iconView = NSImageView()
        iconView.image = NSImage(named: "AppIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 80).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 80).isActive = true
        stackView.addArrangedSubview(iconView)
        stackView.setCustomSpacing(20, after: iconView)

        // App Name
        let nameLabel = NSTextField(labelWithString: "Grok for Mac")
        nameLabel.font = .boldSystemFont(ofSize: 20)
        nameLabel.alignment = .center
        stackView.addArrangedSubview(nameLabel)

        // Version
        let versionLabel = NSTextField(labelWithString: "Version \(UpdateManager.shared.currentVersion)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        stackView.addArrangedSubview(versionLabel)
        stackView.setCustomSpacing(15, after: versionLabel)

        // Description
        let descLabel = NSTextField(labelWithString: "A free, open-source native macOS app for Grok AI.")
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.alignment = .center
        stackView.addArrangedSubview(descLabel)
        stackView.setCustomSpacing(25, after: descLabel)

        // Open Source Header
        let openSourceHeader = NSTextField(labelWithString: "✦ Open Source Community Project")
        openSourceHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        openSourceHeader.alignment = .center
        stackView.addArrangedSubview(openSourceHeader)

        // Community Message
        let communityMsg = NSTextField(labelWithString: "Contributions welcome! Report bugs or suggest features.")
        communityMsg.font = .systemFont(ofSize: 11)
        communityMsg.textColor = .secondaryLabelColor
        communityMsg.alignment = .center
        stackView.addArrangedSubview(communityMsg)
        stackView.setCustomSpacing(20, after: communityMsg)

        // GitHub Button
        let githubButton = NSButton(title: "View Source on GitHub", target: self, action: #selector(openGitHubRepo(_:)))
        githubButton.bezelStyle = .rounded
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        githubButton.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stackView.addArrangedSubview(githubButton)

        // Report Issue Button
        let issuesButton = NSButton(title: "Report an Issue", target: self, action: #selector(openGitHubIssues(_:)))
        issuesButton.bezelStyle = .rounded
        issuesButton.translatesAutoresizingMaskIntoConstraints = false
        issuesButton.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stackView.addArrangedSubview(issuesButton)
        stackView.setCustomSpacing(25, after: issuesButton)

        // Credits
        let creditsLabel = NSTextField(labelWithString: "Built by Brandon Charleson")
        creditsLabel.font = .systemFont(ofSize: 11)
        creditsLabel.textColor = .secondaryLabelColor
        creditsLabel.alignment = .center
        stackView.addArrangedSubview(creditsLabel)

        // X Profile Button
        let xButton = NSButton(title: "@brandon_ai on 𝕏", target: self, action: #selector(openXProfileInApp(_:)))
        xButton.bezelStyle = .rounded
        xButton.controlSize = .small
        stackView.addArrangedSubview(xButton)
        stackView.setCustomSpacing(20, after: xButton)

        // Disclaimer - Use NSFontDescriptor for safe italic font creation
        let disclaimerLabel = NSTextField(labelWithString: "Unofficial app. Grok is a product of xAI.")
        let italicDescriptor = NSFont.systemFont(ofSize: 10).fontDescriptor.withSymbolicTraits(.italic)
        if let italicFont = NSFont(descriptor: italicDescriptor, size: 10) {
            disclaimerLabel.font = italicFont
        } else {
            // Fallback to regular font if italic creation fails
            disclaimerLabel.font = .systemFont(ofSize: 10)
        }
        disclaimerLabel.textColor = .tertiaryLabelColor
        disclaimerLabel.alignment = .center
        stackView.addArrangedSubview(disclaimerLabel)

        // Copyright
        let copyrightLabel = NSTextField(labelWithString: "© 2025 Brandon Charleson • MIT License")
        copyrightLabel.font = .systemFont(ofSize: 10)
        copyrightLabel.textColor = .tertiaryLabelColor
        copyrightLabel.alignment = .center
        stackView.addArrangedSubview(copyrightLabel)

        // Add stack to window
        window.contentView?.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor)
        ])

        // Store reference to prevent deallocation
        self.aboutWindow = window

        window.makeKeyAndOrderFront(nil)
    }
    
    @objc func openGitHubRepo(_ sender: Any?) {
        if let url = URL(string: "https://github.com/bcharleson/xai-grok-cli") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openGitHubIssues(_ sender: Any?) {
        if let url = URL(string: "https://github.com/bcharleson/xai-grok-cli/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openXProfileInApp(_ sender: Any?) {
        // Close About window first
        aboutWindow?.close()
        aboutWindow = nil

        // Switch to X mode
        updateMode(to: .xTwitter)

        // Add small delay to let WebView fully initialize before loading
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            if let url = URL(string: "https://x.com/brandon_ai") {
                self.xWebView.load(URLRequest(url: url))
            }
        }
    }
    
    @objc func transferContext(_ sender: Any?) {
        // Works in Chat, Grokipedia, and X modes (WebView-based)
        guard currentMode == .chat || currentMode == .grokipedia || currentMode == .xTwitter else { return }
        
        activeWebView.evaluateJavaScript("window.getSelection().toString()") { [weak self] (result, error) in
            guard let self = self else { return }
            
            if let selection = result as? String, !selection.isEmpty {
                // Switch to Developer Mode
                self.updateMode(to: .developer)
                
                // Broadcast Notification
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: Notification.Name("TransferWebContext"), object: selection)
                }
            } else {
                let alert = NSAlert()
                alert.messageText = "No Text Selected"
                alert.informativeText = "Please select the text or code snippet you want to transfer to Code."
                alert.runModal()
            }
        }
    }
    
    // MARK: - GitHub Integration
    
    /// Detect GitHub URLs in selected text and offer to clone in Code
    @objc func detectAndOfferGitHubClone(_ sender: Any?) {
        // Works in X, Chat, Grokipedia modes
        guard currentMode == .chat || currentMode == .grokipedia || currentMode == .xTwitter else { return }
        
        activeWebView.evaluateJavaScript("window.getSelection().toString()") { [weak self] (result, error) in
            guard let self = self else { return }
            
            if let selection = result as? String, !selection.isEmpty {
                // Check for GitHub URLs
                let githubPattern = #"https?://github\.com/[\w\-]+/[\w\-\.]+"#
                if let regex = try? NSRegularExpression(pattern: githubPattern, options: []),
                   let match = regex.firstMatch(in: selection, options: [], range: NSRange(selection.startIndex..., in: selection)),
                   let range = Range(match.range, in: selection) {
                    
                    let githubURL = String(selection[range])
                    self.offerGitHubClone(url: githubURL)
                } else {
                    // No GitHub URL found, just transfer text
                    self.updateMode(to: .developer)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: Notification.Name("TransferWebContext"), object: selection)
                    }
                }
            } else {
                let alert = NSAlert()
                alert.messageText = "No Text Selected"
                alert.informativeText = "Select text containing a GitHub URL to clone, or any text to transfer."
                alert.runModal()
            }
        }
    }
    
    private func offerGitHubClone(url: String) {
        let alert = NSAlert()
        alert.messageText = "GitHub Repository Detected"
        alert.informativeText = "Found: \(url)\n\nWould you like to clone this repository?"
        alert.addButton(withTitle: "Clone in Code")
        alert.addButton(withTitle: "Just Transfer URL")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            // Clone in Code
            self.updateMode(to: .developer)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let cloneCommand = "Clone and analyze this GitHub repository: \(url)"
                NotificationCenter.default.post(name: Notification.Name("SpotlightQuery"), object: cloneCommand)
            }
        case .alertSecondButtonReturn:
            // Just transfer URL
            self.updateMode(to: .developer)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: Notification.Name("TransferWebContext"), object: url)
            }
        default:
            break
        }
    }
    
    /// Open current page content in Code for analysis
    @objc func openPageInCode(_ sender: Any?) {
        guard currentMode == .chat || currentMode == .grokipedia || currentMode == .xTwitter else { return }
        
        // Get the current URL and title
        guard let url = activeWebView.url?.absoluteString else { return }
        let title = activeWebView.title ?? "Web Page"
        
        updateMode(to: .developer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let query = "Analyze this page: \(title)\nURL: \(url)"
            NotificationCenter.default.post(name: Notification.Name("SpotlightQuery"), object: query)
        }
    }
}

// MARK: - HotKeyDelegate
extension AppDelegate: HotKeyDelegate {
    func hotKeyTriggered() {
        toggleInputWindow(nil)
    }
}

// MARK: - WKUIDelegate for media permissions
extension AppDelegate: WKUIDelegate {
    func webView(_ webView: WKWebView, 
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Auto-grant permission for grok.com
        if origin.host == "grok.com" || origin.host.hasSuffix(".grok.com") {
            decisionHandler(.grant)
        } else {
            decisionHandler(.prompt)
        }
    }
    
    // Handle JavaScript alerts
    func webView(_ webView: WKWebView, 
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }
    
    // Handle JavaScript confirm dialogs
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn)
    }
    
    // Handle file upload dialogs
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        
        openPanel.begin { result in
            if result == .OK {
                completionHandler(openPanel.urls)
            } else {
                completionHandler(nil)
            }
        }
    }
    
    // Handle opening links in new windows (Popups/OAuth vs External Links)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // If a popup is requested (target="_blank")
        if navigationAction.targetFrame == nil {
             if let url = navigationAction.request.url, let host = url.host?.lowercased() {
                 // Whitelist allowed domains for popups (Google Auth, etc.)
                 let allowedHosts = ["grok.com", "accounts.google.com", "apple.com", "twitter.com", "x.com"]
                 let isAllowed = allowedHosts.contains { host.contains($0) }
                 
                 if isAllowed {
                     // Internal/Auth popup -> Load in main window
                     webView.load(navigationAction.request)
                 } else {
                     // External link -> Open in Default Browser
                     NSWorkspace.shared.open(url)
                 }
             }
        }
        return nil
    }
}

// MARK: - WKNavigationDelegate for downloads
extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // 1. External Link Logic
        // Open non-app links in the default browser (Safari/Chrome)
        if let url = navigationAction.request.url, let host = url.host?.lowercased() {
             // Whitelist allowed domains for main window (App + Auth providers)
             let allowedHosts = ["grok.com", "twitter.com", "x.com", "google.com", "accounts.google.com", "apple.com"]
             let isAllowed = allowedHosts.contains { host.contains($0) }
             
             // If not allowed and it's a link click, open in external browser
             if !isAllowed && navigationAction.navigationType == .linkActivated {
                 NSWorkspace.shared.open(url)
                 decisionHandler(.cancel, preferences)
                 return
             }
        }
        
        // 2. Download Logic
        // Check if this is a download link
        if let url = navigationAction.request.url {
            let ext = url.pathExtension.lowercased()
            let downloadableExtensions = ["pdf", "zip", "dmg", "pkg", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "json", "xml", "mp3", "mp4", "mov", "avi", "png", "jpg", "jpeg", "gif", "svg"]
            
            if downloadableExtensions.contains(ext) || navigationAction.shouldPerformDownload {
                // Trigger download
                if #available(macOS 11.3, *) {
                    decisionHandler(.download, preferences)
                } else {
                    // Fallback for older macOS - open in browser
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel, preferences)
                }
                return
            }
        }
        
        decisionHandler(.allow, preferences)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            if #available(macOS 11.3, *) {
                decisionHandler(.download)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
    
    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    
    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
    
    // Handle navigation errors
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        #if DEBUG
        print("Navigation failed: \(error.localizedDescription)")
        #endif
        showLoadError(error)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        #if DEBUG
        print("Provisional navigation failed: \(error.localizedDescription)")
        #endif
        showLoadError(error)
    }
    
    private func showLoadError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to load Grok"
        alert.informativeText = "\(error.localizedDescription)\n\nClick Retry to try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "https://grok.com") {
                webView.load(URLRequest(url: url))
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
        print("Page loaded successfully: \(webView.url?.absoluteString ?? "unknown")")
        #endif
    }
}

// MARK: - WKDownloadDelegate
@available(macOS 11.3, *)
extension AppDelegate: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // Save to Downloads folder
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var destinationURL = downloadsURL.appendingPathComponent(suggestedFilename)
        
        // If file exists, add number suffix
        var counter = 1
        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        let ext = destinationURL.pathExtension
        
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            let newName = "\(baseName) (\(counter)).\(ext)"
            destinationURL = downloadsURL.appendingPathComponent(newName)
            counter += 1
        }
        
        completionHandler(destinationURL)
    }
    
    func downloadDidFinish(_ download: WKDownload) {
        // Show notification or play sound
        NSSound(named: .init("Glass"))?.play()
        #if DEBUG
        print("Download finished!")
        #endif
    }
    
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        #if DEBUG
        print("Download failed: \(error.localizedDescription)")
        #endif
        
        let alert = NSAlert()
        alert.messageText = "Download Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

struct ToolbarModeSwitcher: View {
    @ObservedObject var modeState = AppModeState.shared
    var onModeChange: (AppMode) -> Void
    @AppStorage("hasSeenGrokCode") private var hasSeenGrokCode = false
    @AppStorage("hasSeenGrokipedia") private var hasSeenGrokipedia = false
    @AppStorage("hasSeenX") private var hasSeenX = false
    @Environment(\.colorScheme) var colorScheme
    
    // Button sizes for minimalistic design
    private let xButtonWidth: CGFloat = 32  // Just the logo
    private let grokButtonWidth: CGFloat = 50
    private let codeButtonWidth: CGFloat = 50
    private let wikiButtonWidth: CGFloat = 85 // "Grokipedia" is longer
    private let buttonHeight: CGFloat = 24
    private let cornerRadius: CGFloat = 6
    
    private var totalWidth: CGFloat {
        xButtonWidth + grokButtonWidth + codeButtonWidth + wikiButtonWidth + 4
    }
    
    private var thumbWidth: CGFloat {
        switch modeState.currentMode {
        case .xTwitter: return xButtonWidth
        case .chat: return grokButtonWidth
        case .developer, .console: return codeButtonWidth
        case .grokipedia: return wikiButtonWidth
        }
    }
    
    private var thumbOffset: CGFloat {
        switch modeState.currentMode {
        case .xTwitter: 
            return -(totalWidth - xButtonWidth) / 2 + 2
        case .chat: 
            return -(totalWidth - xButtonWidth * 2 - grokButtonWidth) / 2 + 2
        case .developer, .console: 
            return (totalWidth - wikiButtonWidth * 2 - codeButtonWidth) / 2 - 2
        case .grokipedia: 
            return (totalWidth - wikiButtonWidth) / 2 - 2
        }
    }
    
    var body: some View {
        ZStack {
            // Layer 1: Track (Bottom) - with proper clip
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.88))
            
            // Layer 2: Active Thumb (Middle) - Fully Opaque, No Blending
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.28) : Color.white)
                .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                .frame(width: thumbWidth, height: buttonHeight)
                .offset(x: thumbOffset)
                .animation(.snappy(duration: 0.2), value: modeState.currentMode)
            
            // Layer 3: Labels (Top) - Minimalistic Typography Only
            HStack(spacing: 0) {
                // 𝕏 Button - Logo only
                Button(action: {
                    onModeChange(.xTwitter)
                    hasSeenX = true
                }) {
                    Text("𝕏")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(modeState.currentMode == .xTwitter ? (colorScheme == .dark ? .white : .black) : .secondary)
                        .frame(width: xButtonWidth, height: buttonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }

                // Grok Button - Bold typography
                Button(action: { onModeChange(.chat) }) {
                    Text("Grok")
                        .font(.system(size: 12, weight: .bold, design: .default))
                        .foregroundStyle(modeState.currentMode == .chat ? (colorScheme == .dark ? .white : .black) : .secondary)
                        .frame(width: grokButtonWidth, height: buttonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }

                // Code Button - Bold typography
                Button(action: {
                    onModeChange(.developer)
                    hasSeenGrokCode = true
                }) {
                    Text("Code")
                        .font(.system(size: 12, weight: .bold, design: .default))
                        .foregroundStyle((modeState.currentMode == .developer || modeState.currentMode == .console) ? (colorScheme == .dark ? .white : .black) : .secondary)
                        .frame(width: codeButtonWidth, height: buttonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }

                // Grokipedia Button - Bold typography
                Button(action: {
                    onModeChange(.grokipedia)
                    hasSeenGrokipedia = true
                }) {
                    Text("Grokipedia")
                        .font(.system(size: 12, weight: .bold, design: .default))
                        .foregroundStyle(modeState.currentMode == .grokipedia ? (colorScheme == .dark ? .white : .black) : .secondary)
                        .frame(width: wikiButtonWidth, height: buttonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
        }
        .frame(width: totalWidth, height: buttonHeight + 4)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous))
    }
}
