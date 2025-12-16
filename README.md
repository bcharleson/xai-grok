<div align="center">

# Grok for Mac

<img src="logo/grok-logo-png.png" alt="Grok for Mac" width="128" height="128">

### The Native macOS Client for xAI's Grok

**A free, open-source, lightning-fast native Mac app for chatting with Grok AI**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0+-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-F05138.svg?logo=swift&logoColor=white)](https://swift.org)
[![Xcode 15+](https://img.shields.io/badge/Xcode-15+-147EFB.svg?logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)

[Download](#-installation) · [Features](#-features) · [Getting Started](#-getting-started) · [Build from Source](#-build-from-source) · [Contributing](#-contributing)

---

**🎬 [Watch the Video Tutorial](#)** *(Coming Soon)*

</div>

---

## 🚀 What is Grok for Mac?

**Grok for Mac** is a native macOS application that gives you direct access to xAI's powerful Grok AI models right from your desktop. No browser needed — just pure, fast, native performance.

Unlike web-based alternatives, this app is built entirely in **Swift and SwiftUI**, optimized specifically for macOS. It's lightweight (~15MB), blazing fast, and integrates seamlessly with your Mac workflow.

> **⚠️ Note:** This is an unofficial, community-built app. [Grok](https://grok.x.ai) is a product of [xAI](https://x.ai). You'll need your own [xAI API key](https://console.x.ai) to use this app.

---

## ✨ Features

### 🤖 Full Grok Model Support
Access all available Grok models through the xAI API:

| Model | Best For | Context Window |
|-------|----------|----------------|
| **Grok 4** | Complex reasoning, analysis | 256K tokens |
| **Grok 4.1 Fast** | Speed + quality balance | 2M tokens |
| **Grok 3** | General purpose | 131K tokens |
| **Grok 3 Mini** | Quick responses, cost-effective | 131K tokens |
| **Grok 2 Vision** | Image analysis | 128K tokens |
| **Grok Code** | Programming assistance | 128K tokens |

### 💬 Developer Chat Mode
A powerful chat interface designed for developers:
- **Markdown rendering** with full syntax highlighting
- **Code blocks** with copy button and language detection
- **Image attachments** — drag & drop or paste images for vision models
- **Conversation history** — saved locally, searchable, exportable
- **Multi-turn conversations** with full context preservation

### ⌨️ Global Hotkey Access
Summon Grok from anywhere on your Mac:
- **⌘⇧G** (Command+Shift+G) — Default hotkey
- Customizable: Option+Space, Control+Space, Option+G
- Works from any app, any window

### 🔒 Secure by Design
Your data stays on your machine:
- **API key stored in macOS Keychain** — Not in plain text
- **No telemetry or tracking** — We don't collect any data
- **Local conversation history** — Nothing leaves your Mac
- **Safety Mode** — Optional protection against destructive commands

### 📊 Cost & Usage Tracking
Stay on top of your API usage:
- **Real-time token counting** — Input and output tokens
- **Cost estimation** — Based on current xAI pricing
- **Context window indicator** — Know when you're approaching limits
- **Per-model pricing** — Automatically calculated

### 🎨 Native macOS Experience
Built for Mac, not ported:
- **Native SwiftUI interface** — Feels right at home on macOS
- **Dark/Light mode** — Follows system appearance
- **Menu bar icon** — Quick access without opening the full app
- **Auto-updates** — Sparkle framework keeps you current
- **Keyboard shortcuts** — Full macOS keyboard navigation

### 🔄 Multiple Modes
Switch between different interfaces:

| Mode | Description |
|------|-------------|
| **💬 Chat** | Grok web interface (grok.x.ai) |
| **👨‍💻 Code** | Developer-focused API chat with code highlighting |
| **📚 Grokipedia** | Knowledge base and research mode |
| **𝕏 Twitter** | Integrated X/Twitter access |

---

## 📦 Installation

### Option 1: Download DMG (Recommended)

1. **Download** the latest `Grok-X.X.X.dmg` from [Releases](https://github.com/bcharleson/xai-grok/releases)
2. **Open** the DMG file
3. **Drag** Grok.app to your Applications folder
4. **Launch** Grok from Applications

> **First Launch:** macOS may show a security warning. Right-click the app → Open → Open to bypass Gatekeeper.

### Option 2: Build from Source

See [Build from Source](#-build-from-source) below.

---

## 🏁 Getting Started

### 1. Get Your API Key

1. Go to [console.x.ai](https://console.x.ai)
2. Sign in with your xAI/X account
3. Create a new API key
4. Copy the key (starts with `xai-...`)

### 2. Configure the App

1. Launch **Grok for Mac**
2. Open **Settings** (⌘,)
3. Go to the **Grok Code** tab
4. Paste your API key
5. Close Settings — you're ready!

### 3. Start Chatting

- Use the **Code** mode for the developer chat interface
- Or use **Chat** mode for the web-based Grok experience
- Try the global hotkey (⌘⇧G) to summon Grok from anywhere!

---

## ⌨️ Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| **Global Hotkey** | ⌘⇧G (customizable) |
| **Settings** | ⌘, |
| **New Chat** | ⌘N |
| **Close Window** | ⌘W |
| **Minimize** | ⌘M |
| **Quit** | ⌘Q |
| **Copy** | ⌘C |
| **Paste** | ⌘V |
| **Select All** | ⌘A |
| **Back** | ⌘[ |
| **Forward** | ⌘] |
| **Reload** | ⌘R |

---

## 🔧 Settings & Configuration

Access Settings via **⌘,** or the menu bar.

### General Tab
| Setting | Description |
|---------|-------------|
| **Launch at Login** | Start Grok when you log in |
| **Show in Menu Bar** | Display icon in menu bar for quick access |
| **Auto-check for Updates** | Keep the app up to date automatically |
| **Global Shortcut** | Choose your preferred hotkey |

### Grok Code Tab
| Setting | Description |
|---------|-------------|
| **API Key** | Your xAI API key (stored in Keychain) |
| **Safety Mode** | Block potentially destructive commands |
| **Chat Retention** | How long to keep chat history (Forever/7 days/30 days) |

---

## 🛠 Build from Source

### Prerequisites

- **macOS 14.0** (Sonoma) or later
- **Xcode 15.0** or later
- **Swift 5.9** or later
- An [xAI API key](https://console.x.ai)

### Build Steps

```bash
# Clone the repository
git clone https://github.com/bcharleson/xai-grok.git
cd xai-grok

# Open in Xcode
cd GrokChat
open GrokApp.xcodeproj
```

Then in Xcode:
1. Select the **Grok** scheme
2. Choose **My Mac** as the destination
3. Press **⌘R** to build and run

### Command Line Build

```bash
cd GrokChat

# Build release version
xcodebuild -project GrokApp.xcodeproj \
           -scheme Grok \
           -configuration Release \
           build

# Find the built app
open ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Release/
```

### Create a DMG

```bash
# Use the included build script
./build-dmg.sh
```

---

## 📁 Project Structure

```
xai-grok/
├── GrokChat/                      # Main app directory
│   ├── Sources/
│   │   ├── AppDelegate.swift      # App lifecycle, window management
│   │   ├── DeveloperRootView.swift # Developer chat UI (SwiftUI)
│   │   ├── SettingsWindow.swift   # Settings panel
│   │   ├── InputWindow.swift      # Quick input window
│   │   ├── Managers/
│   │   │   ├── HotKeyManager.swift    # Global hotkey handling
│   │   │   └── UpdateManager.swift    # Sparkle auto-updates
│   │   └── Utils/
│   │       └── KeychainHelper.swift   # Secure credential storage
│   ├── Tests/
│   │   └── GrokChatTests.swift    # Unit tests
│   ├── GrokApp.xcodeproj/         # Xcode project
│   ├── Package.swift              # Swift Package Manager
│   ├── Info.plist                 # App configuration
│   ├── appcast.xml                # Sparkle update feed
│   ├── bin/                       # Sparkle tools
│   ├── build.sh                   # Build script
│   ├── build-dmg.sh               # DMG creation script
│   └── release.sh                 # Release automation
├── .github/
│   └── PULL_REQUEST_TEMPLATE.md
├── logo/                          # App icons and branding
├── LICENSE                        # MIT License
├── README.md                      # This file
└── CONTRIBUTING.md                # Contribution guidelines
```

---

## 🔧 Technical Details

| Component | Technology |
|-----------|------------|
| **Language** | Swift 5.9+ |
| **UI Framework** | SwiftUI + AppKit |
| **Minimum macOS** | 14.0 (Sonoma) |
| **API Communication** | URLSession with streaming support |
| **Credential Storage** | macOS Keychain |
| **Preferences** | UserDefaults |
| **Auto-Updates** | Sparkle 2.x |
| **Markdown Rendering** | AttributedString + custom parser |
| **Code Highlighting** | Custom Swift highlighter |

### API Integration

The app communicates directly with the [xAI API](https://docs.x.ai):
- Endpoint: `https://api.x.ai/v1/chat/completions`
- Streaming: Server-Sent Events (SSE)
- Models: Fetched dynamically from `/v1/models`
- Pricing: Automatically calculated per model

---

## 🤝 Contributing

We welcome contributions! Whether it's bug fixes, new features, or documentation improvements.

### Quick Start

1. **Fork** the repository
2. **Clone** your fork locally
3. **Create** a feature branch (`git checkout -b feature/amazing-feature`)
4. **Make** your changes
5. **Test** thoroughly
6. **Commit** (`git commit -m 'Add amazing feature'`)
7. **Push** (`git push origin feature/amazing-feature`)
8. **Open** a Pull Request

### Guidelines

- Follow Swift style conventions
- Add tests for new functionality
- Update documentation as needed
- Keep commits focused and atomic

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

---

## 🐛 Troubleshooting

### "App can't be opened because it is from an unidentified developer"
Right-click the app → **Open** → **Open**. This bypasses Gatekeeper for this app.

### API key not working
- Ensure your key starts with `xai-`
- Check that you have API credits at [console.x.ai](https://console.x.ai)
- Try regenerating your API key

### Global hotkey not working
- Check System Settings → Privacy & Security → Accessibility
- Ensure Grok has permission to control your computer
- Try a different hotkey combination in Settings

### High memory usage
- Use "Clear All Chats" in Settings to remove old conversations
- Set a retention policy (7 or 30 days) to auto-delete old chats

---

## 📄 License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE) for details.

```
MIT License

Copyright (c) 2025 Brandon Charleson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software...
```

---

## 👨‍💻 Author

<a href="https://x.com/brandon_ai">
  <img src="https://img.shields.io/badge/@brandon__ai-000000?style=for-the-badge&logo=x&logoColor=white" alt="X/Twitter">
</a>
<a href="https://github.com/bcharleson">
  <img src="https://img.shields.io/badge/@bcharleson-181717?style=for-the-badge&logo=github&logoColor=white" alt="GitHub">
</a>

**Brandon Charleson** — Creator & Maintainer

---

## 🙏 Acknowledgments

- **[xAI](https://x.ai)** — For creating Grok and providing the API
- **[Sparkle](https://sparkle-project.org)** — For the excellent auto-update framework
- **[HotKey](https://github.com/soffes/HotKey)** — For global hotkey support
- **Community Contributors** — Thank you for making this project better!

---

## ⚠️ Disclaimer

This is an **unofficial, community-built application**.

- Grok is a product of [xAI](https://x.ai)
- This project is **not affiliated with, endorsed by, or sponsored by xAI**
- You are responsible for your own API usage and costs
- Use at your own risk

---

<div align="center">

### ⭐ Star this repo if you find it useful!

[⭐ Star](https://github.com/bcharleson/xai-grok) · [🐛 Report Bug](https://github.com/bcharleson/xai-grok/issues) · [💡 Request Feature](https://github.com/bcharleson/xai-grok/issues) · [🍴 Fork](https://github.com/bcharleson/xai-grok/fork)

---

**Made with ❤️ for the Mac community**

</div>
