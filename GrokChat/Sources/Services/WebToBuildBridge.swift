import Foundation
import AppKit

/// Bridges 𝕏 / Grok web surfaces into the native Build harness.
enum WebToBuildBridge {
    static let messageHandlerName = "nativeGrokBuild"

    static let openProjectAtPath = Notification.Name("OpenProjectAtPath")
    static let openNativeBuild = Notification.Name("OpenNativeBuild")

    /// JS injected on grok.com to route the web “Grok Build” promo into the Mac harness.
    static let grokBuildCTAScript = """
    (function() {
      if (window.__grokMacNativeBuildHook) return;
      window.__grokMacNativeBuildHook = true;

      function openNative(payload) {
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload || { action: 'openNativeBuild' });
        } catch (e) {}
      }

      function textOf(el) {
        return (el && (el.innerText || el.textContent) || '').replace(/\\s+/g, ' ').trim();
      }

      function isBuildCard(el) {
        if (!el) return false;
        const t = textOf(el);
        return /Grok Build/i.test(t) && (/Try Free|curl -fsSL|x\\.ai\\/cli|Early access/i.test(t));
      }

      function closestCard(node) {
        let el = node;
        for (let i = 0; i < 8 && el; i++) {
          if (isBuildCard(el)) return el;
          el = el.parentElement;
        }
        return null;
      }

      function restyleCard(card) {
        if (!card || card.dataset.grokMacEnhanced === '1') return;
        card.dataset.grokMacEnhanced = '1';

        // Prefer a clear in-app CTA over the web install curl.
        const buttons = Array.from(card.querySelectorAll('button, a, [role="button"]'));
        buttons.forEach(function(btn) {
          const label = textOf(btn);
          if (/Try Free|Install|Get started/i.test(label)) {
            btn.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              openNative({ action: 'openNativeBuild', source: 'cta' });
            }, true);
            try {
              if (/Try Free/i.test(label)) btn.textContent = 'Open in App';
            } catch (e) {}
          }
        });

        // Soften the curl install affordance — Mac app already wraps the CLI.
        Array.from(card.querySelectorAll('*')).forEach(function(node) {
          const t = textOf(node);
          if (/curl -fsSL https:\\/\\/x\\.ai\\/cli\\/install\\.sh/i.test(t) && t.length < 120) {
            node.style.opacity = '0.35';
            node.title = 'CLI install is handled by the Mac app — use Open in App';
          }
        });
      }

      function scan() {
        const candidates = Array.from(document.querySelectorAll('div, section, article, aside'));
        candidates.forEach(function(el) {
          if (isBuildCard(el)) restyleCard(el);
        });
      }

      document.addEventListener('click', function(e) {
        const card = closestCard(e.target);
        if (!card) return;
        const t = textOf(e.target);
        if (/Try Free|Open in App|curl|install\\.sh|Grok Build/i.test(t)) {
          // Card chrome click → native Build (avoid trapping unrelated nested links).
          if (/Try Free|Open in App|install/i.test(t) || /curl -fsSL/i.test(t)) {
            e.preventDefault();
            e.stopPropagation();
            openNative({ action: 'openNativeBuild', source: 'card-click' });
          }
        }
      }, true);

      const obs = new MutationObserver(function() { scan(); });
      obs.observe(document.documentElement, { childList: true, subtree: true });
      scan();
    })();
    """

    static func githubRepoURL(in text: String) -> String? {
        let pattern = #"https?://github\.com/([\w.-]+)/([\w.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3,
              let full = Range(match.range, in: text) else { return nil }
        var url = String(text[full])
        // Strip trailing path noise (issues, tree, etc.) → owner/repo
        if let owner = Range(match.range(at: 1), in: text),
           let repo = Range(match.range(at: 2), in: text) {
            let repoName = String(text[repo]).replacingOccurrences(of: ".git", with: "")
            url = "https://github.com/\(text[owner])/\(repoName)"
        }
        return url
    }

    static func defaultCloneDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferred = home.appendingPathComponent("Developer", isDirectory: true)
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let fallback = home.appendingPathComponent("Documents/GrokBuild", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func localPathIfCloned(githubURL: String) -> URL? {
        guard let repo = repoName(from: githubURL) else { return nil }
        let candidate = defaultCloneDirectory().appendingPathComponent(repo, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path)
        else { return nil }
        return candidate
    }

    static func repoName(from githubURL: String) -> String? {
        guard let url = URL(string: githubURL) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[1].replacingOccurrences(of: ".git", with: "")
    }

    /// Clone (or reuse) a GitHub repo under ~/Developer.
    static func cloneOrOpenRepository(
        githubURL: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if let existing = localPathIfCloned(githubURL: githubURL) {
            completion(.success(existing))
            return
        }
        guard let repo = repoName(from: githubURL) else {
            completion(.failure(CloneError.invalidURL))
            return
        }
        let dest = defaultCloneDirectory().appendingPathComponent(repo, isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let git = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            guard let git else {
                DispatchQueue.main.async { completion(.failure(CloneError.gitMissing)) }
                return
            }
            try? FileManager.default.createDirectory(at: defaultCloneDirectory(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["clone", "--depth", "1", githubURL, dest.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(dest)) }
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "git clone failed"
                    DispatchQueue.main.async { completion(.failure(CloneError.failed(msg))) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    enum CloneError: LocalizedError {
        case invalidURL
        case gitMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid GitHub URL"
            case .gitMissing: return "git not found"
            case .failed(let msg): return msg
            }
        }
    }

    static func structuredPrompt(selection: String?, pageTitle: String?, pageURL: String?) -> String {
        if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var parts = ["Context from the Mac app web view:", selection.trimmingCharacters(in: .whitespacesAndNewlines)]
            if let pageURL, !pageURL.isEmpty {
                parts.append("Source: \(pageURL)")
            }
            return parts.joined(separator: "\n\n")
        }
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = pageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, let url, !title.isEmpty, !url.isEmpty {
            return "Analyze this page and help me act on it.\n\nTitle: \(title)\nURL: \(url)"
        }
        if let url, !url.isEmpty {
            return "Open and analyze: \(url)"
        }
        return "Help me with what I was looking at in the browser."
    }
}
