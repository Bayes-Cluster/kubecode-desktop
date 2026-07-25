#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="${repo_root}/apps/apple"
build_root="${KUBECODE_LOCALIZATION_BUILD_ROOT:-${apple_root}/.build/localization}"
metadata_directory="${KUBECODE_LOCALIZATION_METADATA:-${build_root}/stringsdata}"

rm -rf "${build_root}"
mkdir -p "${metadata_directory}"

# SwiftPM has no Xcode scheme in this repository. Ask the actual executable
# target to emit compiler localization metadata into a dedicated directory so
# the validator covers the same source that ships in the standalone app.
swift build \
  --package-path "${apple_root}" \
  --scratch-path "${build_root}/swiftpm" \
  --target KubecodeApp \
  --configuration debug \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path \
  -Xswiftc "${metadata_directory}"

if ! find "${metadata_directory}" -type f -name '*.stringsdata' -print -quit | grep -q .; then
  echo "Compiler localization metadata was not generated" >&2
  exit 1
fi
validator="${build_root}/apple-localization-validator"

swiftc \
  "${repo_root}/scripts/apple-localization-validator.swift" \
  -o "${validator}"
"${validator}" \
  "${metadata_directory}" \
  "${apple_root}/Sources/KubecodeApp/Resources/en.lproj/Localizable.strings" \
  "${apple_root}/Sources/KubecodeApp/Resources/zh-Hans.lproj/Localizable.strings"
