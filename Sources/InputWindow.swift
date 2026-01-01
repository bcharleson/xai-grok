//
//  InputWindow.swift
//  Grok for Mac
//
//  Created by Brandon Charleson on 2025.
//  Copyright © 2025 Brandon Charleson. All rights reserved.
//
//  https://github.com/bcharleson/xai-grok
//

import Cocoa

// Custom Text Field to catch Escape key
class SearchTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle Cut/Copy/Paste/Select All shortcuts standardly
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "x":
                if let editor = currentEditor() { editor.cut(nil) }
                return true
            case "c":
                if let editor = currentEditor() { editor.copy(nil) }
                return true
            case "v":
                if let editor = currentEditor() { editor.paste(nil) }
                return true
            case "a":
                if let editor = currentEditor() { editor.selectAll(nil) }
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    
    override func cancelOperation(_ sender: Any?) {
        // When Escape is pressed in text field, close the window
        self.window?.close()
    }
}

class InputWindow: NSPanel {
    // Minimum width to fit all mode buttons with proper spacing (5 buttons now)
    // 50 + 50 + 60 + 60 + 95 + (4 * 4 spacing) = 331
    private static let minWindowWidth: CGFloat = 480
    private static let defaultWindowWidth: CGFloat = 700
    private static let windowHeight: CGFloat = 60

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWindowWidth, height: Self.windowHeight),
            // .fullSizeContentView helps remove system window chrome artifacts
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Set minimum size to ensure mode switcher always fits
        self.minSize = NSSize(width: Self.minWindowWidth, height: Self.windowHeight)
        self.maxSize = NSSize(width: 1200, height: Self.windowHeight)

        // Critical for removing square corners
        self.isOpaque = false
        self.backgroundColor = .clear
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden

        self.hasShadow = true
        self.isMovableByWindowBackground = true

        setupUI()
    }
    
    var textField: NSTextField!
    var modeSelector: NSPopUpButton!
    var selectedMode: AppMode = .chat
    
    private var submitButton: HandCursorButton!

    private func setupUI() {
        // Create visual effect view directly as content view for cleanest rendering
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.defaultWindowWidth, height: Self.windowHeight))
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        visualEffect.autoresizingMask = [.width, .height]

        self.contentView = visualEffect

        // Create segmented mode switcher
        setupModeSwitcher(in: visualEffect)

        // Input Field - uses autoresizing to adapt to window width
        textField = SearchTextField(frame: NSRect(x: 16, y: 12, width: Self.defaultWindowWidth - 72, height: 36))
        textField.cell = VerticallyCenteredTextFieldCell()
        textField.isBordered = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.font = .systemFont(ofSize: 22, weight: .light)
        textField.textColor = .labelColor
        textField.placeholderString = "Ask Grok..."
        textField.stringValue = ""
        textField.isEditable = true
        textField.isSelectable = true
        textField.target = self
        textField.action = #selector(onEnter(_:))
        textField.autoresizingMask = [.width]
        visualEffect.addSubview(textField)

        // Submit Button - stays at right edge
        submitButton = HandCursorButton(frame: NSRect(x: Self.defaultWindowWidth - 50, y: 12, width: 36, height: 36))
        submitButton.bezelStyle = .shadowlessSquare
        submitButton.isBordered = false
        submitButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        submitButton.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        submitButton.contentTintColor = .secondaryLabelColor
        submitButton.target = self
        submitButton.action = #selector(onEnter(_:))
        submitButton.autoresizingMask = [.minXMargin]
        visualEffect.addSubview(submitButton)

        // Initially hide text field and show mode switcher
        textField.isHidden = true
        submitButton.isHidden = true
    }

    private var modeSwitcherView: NSView!
    private var modeButtons: [NSButton] = []
    private var selectionIndicator: NSView!

    // Button layout constants
    // Order: 𝕏 | Chat | Grok | Code | Grokipedia
    private static let buttonHeight: CGFloat = 32
    private static let buttonSpacing: CGFloat = 4
    private static let modeButtonWidths: [CGFloat] = [50, 50, 60, 60, 95] // 𝕏, Chat, Grok, Code, Grokipedia
    private static var modeSwitcherTotalWidth: CGFloat {
        modeButtonWidths.reduce(0, +) + CGFloat(modeButtonWidths.count - 1) * buttonSpacing
    }

    private func setupModeSwitcher(in parent: NSView) {
        let modes = ["𝕏", "Chat", "Grok", "Code", "Grokipedia"]
        let buttonHeight = Self.buttonHeight
        let spacing = Self.buttonSpacing
        let buttonWidths = Self.modeButtonWidths
        let totalWidth = Self.modeSwitcherTotalWidth

        // Container for the mode switcher - centered with autoresizing
        modeSwitcherView = NSView(frame: NSRect(
            x: (parent.bounds.width - totalWidth) / 2,
            y: (Self.windowHeight - buttonHeight) / 2,
            width: totalWidth,
            height: buttonHeight
        ))
        modeSwitcherView.wantsLayer = true
        // Keep centered when window resizes
        modeSwitcherView.autoresizingMask = [.minXMargin, .maxXMargin]

        // Selection indicator (pill background) - starts at Grok button position
        let grokButtonWidth = buttonWidths[2] // Grok is default (index 2)
        let grokButtonX = buttonWidths[0] + spacing + buttonWidths[1] + spacing // Position after 𝕏 and Chat.X buttons
        selectionIndicator = NSView(frame: NSRect(x: grokButtonX, y: 0, width: grokButtonWidth, height: buttonHeight))
        selectionIndicator.wantsLayer = true
        selectionIndicator.layer?.cornerRadius = 8
        selectionIndicator.layer?.cornerCurve = .continuous
        selectionIndicator.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        // Subtle shadow for depth
        selectionIndicator.shadow = NSShadow()
        selectionIndicator.layer?.shadowColor = NSColor.black.withAlphaComponent(0.1).cgColor
        selectionIndicator.layer?.shadowOffset = CGSize(width: 0, height: -1)
        selectionIndicator.layer?.shadowRadius = 2
        selectionIndicator.layer?.shadowOpacity = 1
        modeSwitcherView.addSubview(selectionIndicator)

        // Create mode buttons with variable widths
        var xOffset: CGFloat = 0
        for (index, title) in modes.enumerated() {
            let buttonWidth = buttonWidths[index]
            let button = ModeButton(frame: NSRect(
                x: xOffset,
                y: 0,
                width: buttonWidth,
                height: buttonHeight
            ))
            button.title = title
            button.font = .systemFont(ofSize: 14, weight: index == 2 ? .medium : .regular)
            button.isBordered = false
            button.bezelStyle = .inline
            button.tag = index
            button.target = self
            button.action = #selector(modeTapped(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 8

            // Style based on selection
            if index == 2 { // Grok is default (index 2)
                button.contentTintColor = .labelColor
            } else {
                button.contentTintColor = .secondaryLabelColor
            }

            modeButtons.append(button)
            modeSwitcherView.addSubview(button)

            xOffset += buttonWidth + spacing
        }

        // Position indicator on default selection (Grok = index 2)
        updateSelectionIndicator(to: 2, animated: false)

        parent.addSubview(modeSwitcherView)

        // Hidden popup for compatibility
        modeSelector = NSPopUpButton(frame: .zero)
        modeSelector.isHidden = true
        modeSelector.addItems(withTitles: modes)
        modeSelector.selectItem(at: 2)
        parent.addSubview(modeSelector)
    }

    private func updateSelectionIndicator(to index: Int, animated: Bool) {
        guard index < modeButtons.count else { return }

        let button = modeButtons[index]
        let newFrame = NSRect(
            x: button.frame.origin.x,
            y: button.frame.origin.y,
            width: button.frame.width,
            height: button.frame.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                selectionIndicator.animator().frame = newFrame
            }
        } else {
            selectionIndicator.frame = newFrame
        }

        // Update button styles
        for (i, btn) in modeButtons.enumerated() {
            btn.font = .systemFont(ofSize: 14, weight: i == index ? .medium : .regular)
            btn.contentTintColor = i == index ? .labelColor : .secondaryLabelColor
        }
    }

    @objc func modeTapped(_ sender: NSButton) {
        let index = sender.tag

        // Update selection indicator with animation
        updateSelectionIndicator(to: index, animated: true)

        // Update internal state
        modeSelector.selectItem(at: index)

        // Order: 𝕏 (0), Chat.X (1), Grok (2), Code (3), Grokipedia (4)
        switch index {
        case 0: selectedMode = .xTwitter
        case 1: selectedMode = .chatX
        case 2: selectedMode = .chat
        case 3: selectedMode = .developer
        case 4: selectedMode = .grokipedia
        default: selectedMode = .chat
        }

        // Transition to input mode
        transitionToInputMode()
    }

    private func transitionToInputMode() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            modeSwitcherView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.modeSwitcherView.isHidden = true
            self?.textField.isHidden = false
            self?.submitButton.isHidden = false
            self?.textField.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self?.textField.animator().alphaValue = 1
            }
            self?.makeFirstResponder(self?.textField)
        }

        // Update placeholder
        switch selectedMode {
        case .xTwitter: textField.placeholderString = "Search X..."
        case .chatX: textField.placeholderString = "Chat with Grok..."
        case .chat: textField.placeholderString = "Ask Grok..."
        case .developer: textField.placeholderString = "What do you want to build?"
        case .grokipedia: textField.placeholderString = "Search Grokipedia..."
        default: textField.placeholderString = "Ask Grok..."
        }
    }

    func resetToModeSwitcher() {
        textField.stringValue = ""
        textField.isHidden = true
        submitButton.isHidden = true
        modeSwitcherView.isHidden = false
        modeSwitcherView.alphaValue = 1
    }

    @objc func modeChanged(_ sender: NSPopUpButton) {
        // Order: 𝕏 (0), Chat.X (1), Grok (2), Code (3), Grokipedia (4)
        switch sender.indexOfSelectedItem {
        case 0: selectedMode = .xTwitter
        case 1: selectedMode = .chatX
        case 2: selectedMode = .chat
        case 3: selectedMode = .developer
        case 4: selectedMode = .grokipedia
        default: selectedMode = .chat
        }
    }
    
    @objc func onEnter(_ sender: Any?) {
        guard !textField.stringValue.isEmpty else { return }
        
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.submitQuery(textField.stringValue, to: selectedMode)
            textField.stringValue = "" // Clear
        }
    }
    
    // Standard Cocoa way to handle Escape
    override func cancelOperation(_ sender: Any?) {
        self.close()
    }
    
    // Also catch direct key events just in case
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            self.close()
        } else {
            super.keyDown(with: event)
        }
    }
    
    override var canBecomeKey: Bool {
        return true
    }
}

// Custom button for hand cursor
class HandCursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// Custom mode button with hover effects
class ModeButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButton()
    }

    private func setupButton() {
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)

        // Ensure proper text rendering
        if let cell = self.cell as? NSButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.animator().alphaValue = 0.7
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.animator().alphaValue = 1.0
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// Helper for vertical centering
class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let newRect = super.drawingRect(forBounds: rect)
        let textSize = self.cellSize(forBounds: rect)
        let heightDelta = newRect.size.height - textSize.height
        if heightDelta > 0 {
            // Added slight +offset to push it down if it feels too high
            return NSRect(x: newRect.origin.x, y: newRect.origin.y + (heightDelta / 2) + 1, width: newRect.size.width, height: textSize.height)
        }
        return newRect
    }
}
