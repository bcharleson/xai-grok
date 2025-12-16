# Contributing to Grok for Mac

Thank you for your interest in contributing to Grok for Mac! This is a community-driven project, and we welcome contributions from everyone.

## How to Contribute

### Reporting Bugs

If you find a bug, please [open an issue](https://github.com/bcharleson/xai-grok-cli/issues) with:
- A clear, descriptive title
- Steps to reproduce the issue
- Expected behavior vs. actual behavior
- macOS version and app version
- Screenshots if applicable

### Suggesting Features

We love new ideas! To suggest a feature:
1. Check if it's already been suggested in [Issues](https://github.com/bcharleson/xai-grok-cli/issues)
2. If not, open a new issue with the `enhancement` label
3. Describe the feature and why it would be useful
4. Include mockups or examples if possible

### Contributing Code

#### Prerequisites
- macOS 13.0 (Ventura) or later
- Xcode 15.0 or later
- Swift 5.9 or later
- Basic knowledge of Swift, SwiftUI, and AppKit

#### Getting Started

1. **Fork the repository**
   ```bash
   # Click "Fork" on GitHub, then clone your fork
   git clone https://github.com/YOUR_USERNAME/xai-grok-cli.git
   cd xai-grok-cli
   ```

2. **Open in Xcode**
   ```bash
   open GrokChat.xcodeproj
   ```

3. **Create a branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

4. **Make your changes**
   - Follow the existing code style
   - Add comments for complex logic
   - Test your changes thoroughly

5. **Commit your changes**
   ```bash
   git add .
   git commit -m "Add: Brief description of your changes"
   ```

6. **Push to your fork**
   ```bash
   git push origin feature/your-feature-name
   ```

7. **Open a Pull Request**
   - Go to the original repository
   - Click "New Pull Request"
   - Select your fork and branch
   - Describe your changes clearly

#### Code Style Guidelines

- Use Swift naming conventions (camelCase for variables/functions, PascalCase for types)
- Add `// MARK: -` comments to organize code sections
- Keep functions focused and concise
- Use meaningful variable and function names
- Add comments for non-obvious logic

#### Testing

Before submitting a PR:
- [ ] Build succeeds without warnings
- [ ] App launches and runs without crashes
- [ ] Your feature works as expected
- [ ] Existing features still work (no regressions)
- [ ] Test on both light and dark mode
- [ ] Test window resizing and edge cases

### Code Review Process

1. A maintainer will review your PR
2. They may request changes or ask questions
3. Make requested changes and push to your branch
4. Once approved, your PR will be merged!

## Development Setup

### Project Structure
```
GrokChat/
├── Sources/
│   ├── AppDelegate.swift       # Main app logic, window management
│   ├── DeveloperRootView.swift # Code mode UI
│   ├── SettingsWindow.swift    # Settings panel
│   └── InputWindow.swift       # Chat input handling
├── Resources/
│   └── Assets.xcassets/        # App icons and images
└── Info.plist                  # App configuration
```

### Key Technologies
- **Swift 5.9+** - Primary language
- **SwiftUI** - Modern UI components
- **AppKit** - Native macOS UI framework
- **WKWebView** - Web content rendering
- **Keychain** - Secure credential storage

## Questions?

Feel free to:
- Open an issue with the `question` label
- Reach out to [@b_charleson](https://x.com/b_charleson) on 𝕏

## Code of Conduct

- Be respectful and constructive
- Welcome newcomers and help them learn
- Focus on what's best for the community
- Show empathy towards other contributors

Thank you for contributing! 🚀

