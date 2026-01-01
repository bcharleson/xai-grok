# GrokChat - Native macOS Client for xAI Grok

A beautiful, native SwiftUI macOS application for interacting with xAI's Grok AI model.

## Features

- Native macOS app built with SwiftUI
- Clean, modern chat interface
- Multiple chat sessions with history
- Real-time streaming responses
- Secure API key storage
- Customizable settings (model selection, temperature, font size)
- Full keyboard shortcuts support
- Dark mode support

## Requirements

- macOS 13.0 or later
- xAI API key (get yours at [console.x.ai](https://console.x.ai))
- Xcode 14.0+ (for building from source)

## Quick Start

### Option 1: Run Pre-built App

1. Open the pre-built app:
   ```bash
   cd GrokChat
   open GrokChat.app
   ```

2. On first launch, go to Settings (⌘,) and add your xAI API key

3. Start chatting with Grok!

### Option 2: Build from Source

1. Clone or download this repository

2. Build and run:
   ```bash
   cd GrokChat
   ./build.sh
   open GrokChat.app
   ```

### Option 3: Development with Xcode

1. Open Terminal and run:
   ```bash
   cd GrokChat
   swift package generate-xcodeproj
   open GrokChat.xcodeproj
   ```

2. Build and run in Xcode (⌘R)

## Configuration

### API Key Setup

1. Get your API key from [console.x.ai](https://console.x.ai)
2. Open GrokChat
3. Go to Preferences (⌘,)
4. Navigate to the API tab
5. Enter your API key

During the beta period, you get $25 of free API credits per month.

### Available Models

- `grok-beta` (default)
- `grok-2` (coming soon)
- `grok-2-mini` (coming soon)

## Usage

### Keyboard Shortcuts

- **New Chat**: ⌘N
- **Settings**: ⌘,
- **Send Message**: Return
- **Copy Message**: Right-click on any message

### Features in Detail

- **Chat History**: All conversations are saved locally
- **Search**: Find previous conversations quickly
- **Streaming**: See responses as they're generated
- **Temperature Control**: Adjust response creativity (0.0 - 2.0)

## Development

### Project Structure

```
GrokChat/
├── Sources/
│   ├── Models/          # Data models
│   ├── Views/           # SwiftUI views
│   ├── ViewModels/      # View models
│   ├── Services/        # API service
│   └── GrokChatApp.swift
├── Package.swift
├── build.sh
└── README.md
```

### Building for Distribution

To create a release build:

```bash
swift build -c release
```

The executable will be in `.build/release/GrokChat`

## Troubleshooting

### API Key Issues
- Ensure your API key is valid and has available credits
- Check your internet connection
- Verify the API endpoint is accessible

### Build Issues
- Ensure you have Xcode Command Line Tools installed
- Run `xcode-select --install` if needed
- Make sure you're on macOS 13.0 or later

## License

This project is provided as-is for educational and personal use.

## Acknowledgments

Built with SwiftUI and the xAI Grok API.