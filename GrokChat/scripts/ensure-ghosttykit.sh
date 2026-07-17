#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CMUX_KIT="/Users/brandoncharleson/Developer/cmux/GhosttyKit.xcframework"
CMUX_GHOSTTY="/Users/brandoncharleson/Developer/cmux/Resources/ghostty"
CMUX_TERMINFO="/Users/brandoncharleson/Developer/cmux/Resources/terminfo-overlay"

if [[ ! -e "$CMUX_KIT" ]]; then
  echo "error: GhosttyKit.xcframework not found at $CMUX_KIT" >&2
  echo "Run ./scripts/setup.sh in ~/Developer/cmux first." >&2
  exit 1
fi

ln -sfn "$CMUX_KIT" "$PROJECT_DIR/GhosttyKit.xcframework"
mkdir -p "$PROJECT_DIR/Resources"
ln -sfn "$CMUX_GHOSTTY" "$PROJECT_DIR/Resources/ghostty"
ln -sfn "$CMUX_TERMINFO" "$PROJECT_DIR/Resources/terminfo"

echo "GhosttyKit and resources linked for Grok Build TUI embedding."