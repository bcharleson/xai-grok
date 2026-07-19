# Grok for Mac — Release Workflow

**Authoritative copy:** [`../cursor/RELEASE_WORKFLOW.md`](../cursor/RELEASE_WORKFLOW.md)

That document is the exact flow used for **1.0.89 (build 56)** — archive → notarize → Sparkle-sign → publish to topoffunnel.com.

## Quick path (after you have a notarized app)

```bash
cd ~/Developer/xai-grok-macos/GrokChat

# Confirm production Sparkle key (NEVER generate a new one)
"/Users/brandoncharleson/Documents/DeveloperProjects/xAI Grok/GrokChat/bin/generate_keys" -p
# Must print: a+vXV7cwhCxuoSLMpuoX8e1G8O223alkm0FX+QxYHlk=
# Private key stays in Keychain only — never commit eddsa_private_key*

./scripts/ship-sparkle-release.sh \
  --app "$HOME/Library/Developer/Xcode/Archives/YYYY-MM-DD/.../Submissions/<UUID>/Grok.app" \
  --version 1.0.90 \
  --build 57 \
  --notes $'What changed line 1\nWhat changed line 2'
```

Full step-by-step (version bump, archive, export, staple) is in the cursor doc.
