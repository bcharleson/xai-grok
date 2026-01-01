//
//  HotKeyManager.swift
//  Grok for Mac
//
//  Created by Brandon Charleson on 2025.
//  Copyright © 2025 Brandon Charleson. All rights reserved.
//
//  https://github.com/bcharleson/xai-grok
//

import Cocoa
import Carbon

protocol HotKeyDelegate: AnyObject {
    func hotKeyTriggered()
}

class HotKeyManager {
    static let shared = HotKeyManager()
    weak var delegate: HotKeyDelegate?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyID = EventHotKeyID(signature: OSType(0x47524F4B), id: 1) // 'GROK', 1

    private var currentKeyCode: UInt32 = 49 // Space
    private var currentModifiers: UInt32 = UInt32(optionKey) // Option

    deinit {
        cleanup()
    }

    /// Properly releases all event handlers and hotkey registrations.
    /// Call this when the app terminates or when hotkey functionality is no longer needed.
    func cleanup() {
        // Unregister the hotkey first
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            #if DEBUG
            print("🧹 Unregistered HotKey")
            #endif
        }

        // Remove the event handler
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
            #if DEBUG
            print("🧹 Removed EventHandler")
            #endif
        }
    }
    
    // Presets
    enum ShortcutPreset: Int {
        case optionSpace = 0
        case controlSpace = 1
        case commandShiftG = 2
        case optionG = 3
        
        var name: String {
            switch self {
            case .optionSpace: return "Option + Space"
            case .controlSpace: return "Control + Space"
            case .commandShiftG: return "Command + Shift + G"
            case .optionG: return "Option + G"
            }
        }
        
        var keyCode: UInt32 {
            switch self {
            case .optionSpace: return 49 // Space
            case .controlSpace: return 49 // Space
            case .commandShiftG: return 5 // G
            case .optionG: return 5 // G
            }
        }
        
        var modifiers: UInt32 {
            switch self {
            case .optionSpace: return UInt32(optionKey)
            case .controlSpace: return UInt32(controlKey)
            case .commandShiftG: return UInt32(cmdKey | shiftKey)
            case .optionG: return UInt32(optionKey)
            }
        }
    }
    
    func setup() {
        // Clean up any existing handlers first (makes setup idempotent)
        if eventHandler != nil {
            cleanup()
        }

        // Install event handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            HotKeyManager.shared.delegate?.hotKeyTriggered()
            return noErr
        }, 1, &eventType, nil, &eventHandler)
        
        // Load preference
        let saved = UserDefaults.standard.integer(forKey: "hotkeyPreset")
        let preset = ShortcutPreset(rawValue: saved) ?? .optionSpace
        setPreset(preset)
    }
    
    func setPreset(_ preset: ShortcutPreset) {
        // Save
        UserDefaults.standard.set(preset.rawValue, forKey: "hotkeyPreset")
        
        // Register
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        
        let id = EventHotKeyID(signature: OSType(0x47524F4B), id: 1)
        RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        #if DEBUG
        print("Registered HotKey: \(preset.name)")
        #endif
    }
}
