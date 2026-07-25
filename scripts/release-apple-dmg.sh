#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${KUBECODE_APP_PATH:-${repo_root}/dist/apple/Kubecode.app}"
codesign_identity="${KUBECODE_CODESIGN_IDENTITY:-}"
notary_profile="${KUBECODE_NOTARY_PROFILE:-}"
build_tool="${KUBECODE_BUILD_APP_TOOL:-${repo_root}/scripts/build-apple-app.sh}"
codesign_tool="${KUBECODE_CODESIGN_TOOL:-/usr/bin/codesign}"
ditto_tool="${KUBECODE_DITTO_TOOL:-/usr/bin/ditto}"
hdiutil_tool="${KUBECODE_HDIUTIL_TOOL:-/usr/bin/hdiutil}"
xcrun_tool="${KUBECODE_XCRUN_TOOL:-/usr/bin/xcrun}"
spctl_tool="${KUBECODE_SPCTL_TOOL:-/usr/sbin/spctl}"
dmg_smoke_tool="${KUBECODE_DMG_SMOKE_TOOL:-${repo_root}/scripts/smoke-test-apple-dmg.sh}"
release_root="${repo_root}/dist/apple/releases"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-apple-release.XXXXXX")"
cleanup() {
  rm -rf "${temporary_root}"
}
trap cleanup EXIT

if [[ "${codesign_identity}" != "Developer ID Application:"* ]]; then
  echo "KUBECODE_CODESIGN_IDENTITY must be a Developer ID Application identity" >&2
  exit 1
fi
if [[ -z "${notary_profile}" ]]; then
  echo "KUBECODE_NOTARY_PROFILE must name an existing notarytool Keychain profile" >&2
  exit 1
fi

if [[ "${KUBECODE_SKIP_APP_BUILD:-0}" != "1" ]]; then
  KUBECODE_CODESIGN_IDENTITY="${codesign_identity}" "${build_tool}"
fi
if [[ ! -d "${app_root}" ]]; then
  echo "Kubecode app bundle does not exist: ${app_root}" >&2
  exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw -o - "${app_root}/Contents/Info.plist")"
release_output="${KUBECODE_RELEASE_OUTPUT:-${release_root}/Kubecode-${version}-universal.dmg}"
mkdir -p "$(dirname "${release_output}")"

"${codesign_tool}" --verify --deep --strict --verbose=2 "${app_root}"

notarize() {
  local artifact="$1"
  local label="$2"
  local result_path="${temporary_root}/${label}-notary-result.json"
  local status
  "${xcrun_tool}" notarytool submit "${artifact}" \
    --keychain-profile "${notary_profile}" \
    --wait \
    --output-format json >"${result_path}"
  status="$(plutil -extract status raw -o - "${result_path}")"
  if [[ "${status}" != "Accepted" ]]; then
    echo "Apple notarization rejected ${label}; result: ${result_path}" >&2
    cat "${result_path}" >&2
    exit 1
  fi
}

app_archive="${temporary_root}/Kubecode.zip"
"${ditto_tool}" -c -k --keepParent "${app_root}" "${app_archive}"
notarize "${app_archive}" app
"${xcrun_tool}" stapler staple "${app_root}"
"${xcrun_tool}" stapler validate "${app_root}"
"${spctl_tool}" --assess --type execute --verbose=4 "${app_root}"

dmg_stage="${temporary_root}/dmg"
mkdir -p "${dmg_stage}"
"${ditto_tool}" "${app_root}" "${dmg_stage}/Kubecode.app"
ln -s /Applications "${dmg_stage}/Applications"
"${hdiutil_tool}" create \
  -volname Kubecode \
  -srcfolder "${dmg_stage}" \
  -ov \
  -format UDZO \
  -o "${release_output}"
"${codesign_tool}" \
  --force \
  --sign "${codesign_identity}" \
  --timestamp \
  "${release_output}"
notarize "${release_output}" dmg
"${xcrun_tool}" stapler staple "${release_output}"
"${xcrun_tool}" stapler validate "${release_output}"
"${spctl_tool}" \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "${release_output}"
"${dmg_smoke_tool}" "${release_output}"

echo "Released ${release_output}"
