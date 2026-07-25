#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
scratch_path="${TMPDIR:-/tmp}/kubecode-apple-ios-build"

for target in KubecodeKit KubecodeCore KubecodeUI; do
  swift build \
    --package-path "$repo_root/apps/apple" \
    --scratch-path "$scratch_path" \
    --target "$target" \
    --sdk "$sdk_path" \
    --triple arm64-apple-ios17.0
done

echo "Apple shared targets compile for iOS using ${sdk_path}."
