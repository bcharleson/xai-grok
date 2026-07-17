//
//  main.swift
//  Grok for Mac
//
//  Created by Brandon Charleson on 2025.
//  Copyright © 2025 Brandon Charleson. All rights reserved.
//
//  https://github.com/bcharleson/xai-grok
//

import Cocoa

// Ghostty requires one-time global initialization before any libghostty API call.
GrokGhosttyBootstrap.bootstrapProcess()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
