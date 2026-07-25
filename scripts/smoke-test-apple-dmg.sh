#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dmg_path="${1:-${KUBECODE_DMG_PATH:-}}"
hdiutil_tool="${KUBECODE_HDIUTIL_TOOL:-/usr/bin/hdiutil}"
xcrun_tool="${KUBECODE_XCRUN_TOOL:-/usr/bin/xcrun}"
spctl_tool="${KUBECODE_SPCTL_TOOL:-/usr/sbin/spctl}"
codesign_tool="${KUBECODE_CODESIGN_TOOL:-/usr/bin/codesign}"
bundle_smoke_tool="${KUBECODE_BUNDLE_SMOKE_TOOL:-${repo_root}/scripts/smoke-test-apple-bundle.sh}"
mount_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-dmg-smoke.XXXXXX")"
mounted=0
cleanup() {
  if [[ "${mounted}" == "1" ]]; then
    "${hdiutil_tool}" detach "${mount_root}" -quiet || true
  fi
  rm -rf "${mount_root}"
}
trap cleanup EXIT

if [[ -z "${dmg_path}" || ! -f "${dmg_path}" ]]; then
  echo "Kubecode release DMG does not exist: ${dmg_path}" >&2
  exit 1
fi

"${xcrun_tool}" stapler validate "${dmg_path}"
"${spctl_tool}" \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "${dmg_path}"
"${hdiutil_tool}" attach \
  -readonly \
  -nobrowse \
  -mountpoint "${mount_root}" \
  "${dmg_path}" >/dev/null
mounted=1

app_root="${mount_root}/Kubecode.app"
if [[ ! -d "${app_root}" ]]; then
  echo "Release DMG does not contain Kubecode.app" >&2
  exit 1
fi
if [[ ! -L "${mount_root}/Applications" \
  || "$(readlink "${mount_root}/Applications")" != "/Applications" ]]; then
  echo "Release DMG does not contain the Applications install link" >&2
  exit 1
fi

"${codesign_tool}" --verify --deep --strict --verbose=2 "${app_root}"
"${xcrun_tool}" stapler validate "${app_root}"
"${spctl_tool}" --assess --type execute --verbose=4 "${app_root}"
KUBECODE_APP_PATH="${app_root}" "${bundle_smoke_tool}"

echo "Read-only notarized DMG payload passed standalone Runtime smoke."
