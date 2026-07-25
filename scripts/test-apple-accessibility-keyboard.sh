#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product_version="$(sw_vers -productVersion)"
major_version="${product_version%%.*}"

case "$major_version" in
  26) ;;
  *)
    echo "Accessibility/keyboard acceptance requires macOS 26; found ${product_version}." >&2
    exit 1
    ;;
esac

swift test \
  --package-path "$repo_root/apps/apple" \
  --filter MacOSAccessibilityKeyboardAcceptanceTests

echo "macOS ${product_version} accessibility/keyboard automated acceptance passed."
echo "Complete the same-version VoiceOver and Full Keyboard Access checklist in docs/qa/MACOS_ACCESSIBILITY_KEYBOARD.md."
