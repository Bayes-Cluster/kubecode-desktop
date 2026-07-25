#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${KUBECODE_APP_PATH:-${repo_root}/dist/apple/Kubecode.app}"
hdiutil_tool="${KUBECODE_HDIUTIL_TOOL:-/usr/bin/hdiutil}"
release_root="${repo_root}/dist/apple/releases"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-apple-adhoc.XXXXXX")"
cleanup() {
  rm -rf "${temporary_root}"
}
trap cleanup EXIT

if [[ ! -d "${app_root}" ]]; then
  echo "Kubecode app bundle does not exist: ${app_root}" >&2
  exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw -o - "${app_root}/Contents/Info.plist")"
release_output="${KUBECODE_RELEASE_OUTPUT:-${release_root}/Kubecode-${version}-universal-adhoc.dmg}"
checksum_output="${release_output}.sha256"
dmg_stage="${temporary_root}/dmg"

mkdir -p "${dmg_stage}" "$(dirname "${release_output}")"
ditto "${app_root}" "${dmg_stage}/Kubecode.app"
ln -s /Applications "${dmg_stage}/Applications"
"${hdiutil_tool}" create \
  -volname Kubecode \
  -srcfolder "${dmg_stage}" \
  -ov \
  -format UDZO \
  -o "${release_output}"

(
  cd "$(dirname "${release_output}")"
  shasum -a 256 "$(basename "${release_output}")" >"$(basename "${checksum_output}")"
)

echo "Packaged ${release_output}"
echo "Checksum ${checksum_output}"
