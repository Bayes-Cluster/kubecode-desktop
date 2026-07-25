#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-release-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

app_root="${test_root}/Kubecode.app"
runtime_root="${app_root}/Contents/Resources/Runtime"
mkdir -p \
  "${app_root}/Contents/MacOS" \
  "${runtime_root}/arm64" \
  "${runtime_root}/x86_64" \
  "${runtime_root}/shared"
for executable in \
  "${app_root}/Contents/MacOS/Kubecode" \
  "${runtime_root}/arm64/kubecode-server" \
  "${runtime_root}/arm64/node" \
  "${runtime_root}/x86_64/kubecode-server" \
  "${runtime_root}/x86_64/node"; do
  printf 'mock Mach-O\n' >"${executable}"
  chmod +x "${executable}"
done
printf '#!/bin/sh\n' >"${runtime_root}/shared/claude-agent-acp"
chmod +x "${runtime_root}/shared/claude-agent-acp"
cp "${repo_root}/apps/apple/Packaging/Info.plist" "${app_root}/Contents/Info.plist"

command_log="${test_root}/commands.log"
mock_codesign="${test_root}/codesign"
mock_file="${test_root}/file"
cat >"${mock_codesign}" <<'MOCK'
#!/bin/sh
printf 'codesign %s\n' "$*" >>"${KUBECODE_TEST_COMMAND_LOG}"
MOCK
cat >"${mock_file}" <<'MOCK'
#!/bin/sh
case "$2" in
  */Kubecode|*/kubecode-server|*/node) printf 'Mach-O 64-bit executable\n' ;;
  *) printf 'ASCII text\n' ;;
esac
MOCK
chmod +x "${mock_codesign}" "${mock_file}"

KUBECODE_APP_PATH="${app_root}" \
KUBECODE_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
KUBECODE_CODESIGN_TOOL="${mock_codesign}" \
KUBECODE_FILE_TOOL="${mock_file}" \
KUBECODE_TEST_COMMAND_LOG="${command_log}" \
  "${repo_root}/scripts/sign-apple-app.sh"

sign_line_count="$(grep -c '^codesign ' "${command_log}")"
if [[ "${sign_line_count}" -ne 7 ]]; then
  echo "Expected five nested signatures, one app signature, and one verification" >&2
  exit 1
fi
for line_number in 1 2 3 4 5; do
  sign_line="$(sed -n "${line_number}p" "${command_log}")"
  if [[ "${sign_line}" != *"--options runtime"* \
    || "${sign_line}" != *"--timestamp"* ]]; then
    echo "Nested executable was not signed with Hardened Runtime and timestamp" >&2
    exit 1
  fi
done
app_sign_line="$(sed -n '6p' "${command_log}")"
verify_line="$(sed -n '7p' "${command_log}")"
if [[ "${app_sign_line}" != *"--entitlements "* \
  || "${app_sign_line}" != *"${app_root}" ]]; then
  echo "Containing app was not signed last with explicit entitlements" >&2
  exit 1
fi
if [[ "${verify_line}" != "codesign --verify --deep --strict --verbose=2 ${app_root}" ]]; then
  echo "Final strict signature verification is missing" >&2
  exit 1
fi

mock_tool="${test_root}/mock-tool"
cat >"${mock_tool}" <<'MOCK'
#!/bin/sh
tool="${KUBECODE_MOCK_TOOL_NAME:-tool}"
printf '%s %s\n' "${tool}" "$*" >>"${KUBECODE_TEST_COMMAND_LOG}"
case "${tool} $*" in
  "ditto -c -k --keepParent "*)
    output=""
    for argument in "$@"; do output="${argument}"; done
    : >"${output}"
    ;;
  "ditto "*) cp -R "$1" "$2" ;;
  "hdiutil create "*)
    previous=""
    for argument in "$@"; do
      if [ "${previous}" = "-o" ]; then : >"${argument}"; fi
      previous="${argument}"
    done
    ;;
  "xcrun notarytool submit "*)
    status="${KUBECODE_MOCK_NOTARY_STATUS:-Accepted}"
    case "${KUBECODE_MOCK_REJECT_ARTIFACT:-}:$3" in
      app:*.zip|dmg:*.dmg) status="Invalid" ;;
    esac
    printf \
      '{"status":"%s","id":"mock-submission"}\n' \
      "${status}"
    ;;
esac
MOCK
chmod +x "${mock_tool}"

make_named_mock() {
  local name="$1"
  local path="${test_root}/${name}"
  cat >"${path}" <<MOCK
#!/bin/sh
KUBECODE_MOCK_TOOL_NAME="${name}" exec "${mock_tool}" "\$@"
MOCK
  chmod +x "${path}"
  printf '%s' "${path}"
}

mock_ditto="$(make_named_mock ditto)"
mock_hdiutil="$(make_named_mock hdiutil)"
mock_xcrun="$(make_named_mock xcrun)"
mock_spctl="$(make_named_mock spctl)"
mock_smoke="$(make_named_mock smoke)"
: >"${command_log}"

if KUBECODE_APP_PATH="${app_root}" \
  KUBECODE_CODESIGN_IDENTITY="-" \
  KUBECODE_NOTARY_PROFILE="test-profile" \
  "${repo_root}/scripts/release-apple-dmg.sh" >/dev/null 2>&1; then
  echo "Release pipeline accepted an ad-hoc signing identity" >&2
  exit 1
fi

if KUBECODE_APP_PATH="${app_root}" \
  KUBECODE_SKIP_APP_BUILD=1 \
  KUBECODE_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  KUBECODE_NOTARY_PROFILE="test-profile" \
  KUBECODE_RELEASE_OUTPUT="${test_root}/Kubecode-rejected.dmg" \
  KUBECODE_CODESIGN_TOOL="${mock_codesign}" \
  KUBECODE_DITTO_TOOL="${mock_ditto}" \
  KUBECODE_HDIUTIL_TOOL="${mock_hdiutil}" \
  KUBECODE_XCRUN_TOOL="${mock_xcrun}" \
  KUBECODE_SPCTL_TOOL="${mock_spctl}" \
  KUBECODE_DMG_SMOKE_TOOL="${mock_smoke}" \
  KUBECODE_MOCK_NOTARY_STATUS="Invalid" \
  KUBECODE_TEST_COMMAND_LOG="${command_log}" \
  "${repo_root}/scripts/release-apple-dmg.sh" >/dev/null 2>&1; then
  echo "Release pipeline accepted a rejected Apple notarization result" >&2
  exit 1
fi
: >"${command_log}"

if KUBECODE_APP_PATH="${app_root}" \
  KUBECODE_SKIP_APP_BUILD=1 \
  KUBECODE_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  KUBECODE_NOTARY_PROFILE="test-profile" \
  KUBECODE_RELEASE_OUTPUT="${test_root}/Kubecode-rejected-dmg.dmg" \
  KUBECODE_CODESIGN_TOOL="${mock_codesign}" \
  KUBECODE_DITTO_TOOL="${mock_ditto}" \
  KUBECODE_HDIUTIL_TOOL="${mock_hdiutil}" \
  KUBECODE_XCRUN_TOOL="${mock_xcrun}" \
  KUBECODE_SPCTL_TOOL="${mock_spctl}" \
  KUBECODE_DMG_SMOKE_TOOL="${mock_smoke}" \
  KUBECODE_MOCK_REJECT_ARTIFACT="dmg" \
  KUBECODE_TEST_COMMAND_LOG="${command_log}" \
  "${repo_root}/scripts/release-apple-dmg.sh" >/dev/null 2>&1; then
  echo "Release pipeline accepted a rejected DMG notarization result" >&2
  exit 1
fi
: >"${command_log}"

KUBECODE_APP_PATH="${app_root}" \
KUBECODE_SKIP_APP_BUILD=1 \
KUBECODE_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
KUBECODE_NOTARY_PROFILE="test-profile" \
KUBECODE_RELEASE_OUTPUT="${test_root}/Kubecode-test.dmg" \
KUBECODE_CODESIGN_TOOL="${mock_codesign}" \
KUBECODE_DITTO_TOOL="${mock_ditto}" \
KUBECODE_HDIUTIL_TOOL="${mock_hdiutil}" \
KUBECODE_XCRUN_TOOL="${mock_xcrun}" \
KUBECODE_SPCTL_TOOL="${mock_spctl}" \
KUBECODE_DMG_SMOKE_TOOL="${mock_smoke}" \
KUBECODE_TEST_COMMAND_LOG="${command_log}" \
  "${repo_root}/scripts/release-apple-dmg.sh"

app_submit_line="$(grep -n 'xcrun notarytool submit .*Kubecode.zip' "${command_log}" | cut -d: -f1)"
app_staple_line="$(grep -n 'xcrun stapler staple .*Kubecode.app' "${command_log}" | cut -d: -f1)"
app_validate_line="$(grep -n 'xcrun stapler validate .*Kubecode.app' "${command_log}" | cut -d: -f1)"
app_gatekeeper_line="$(grep -n 'spctl --assess --type execute --verbose=4 .*Kubecode.app' "${command_log}" | cut -d: -f1)"
dmg_create_line="$(grep -n '^hdiutil create ' "${command_log}" | cut -d: -f1)"
dmg_sign_line="$(grep -n '^codesign .*Kubecode-test.dmg' "${command_log}" | head -1 | cut -d: -f1)"
dmg_submit_line="$(grep -n 'xcrun notarytool submit .*Kubecode-test.dmg' "${command_log}" | cut -d: -f1)"
dmg_staple_line="$(grep -n 'xcrun stapler staple .*Kubecode-test.dmg' "${command_log}" | cut -d: -f1)"
dmg_validate_line="$(grep -n 'xcrun stapler validate .*Kubecode-test.dmg' "${command_log}" | cut -d: -f1)"
dmg_gatekeeper_line="$(grep -n 'spctl --assess --type open .*Kubecode-test.dmg' "${command_log}" | cut -d: -f1)"
smoke_line="$(grep -n '^smoke .*Kubecode-test.dmg' "${command_log}" | cut -d: -f1)"

if ! (( app_submit_line < app_staple_line \
  && app_staple_line < app_validate_line \
  && app_validate_line < app_gatekeeper_line \
  && app_gatekeeper_line < dmg_create_line \
  && dmg_create_line < dmg_sign_line \
  && dmg_sign_line < dmg_submit_line \
  && dmg_submit_line < dmg_staple_line \
  && dmg_staple_line < dmg_validate_line \
  && dmg_validate_line < dmg_gatekeeper_line \
  && dmg_gatekeeper_line < smoke_line )); then
  echo "Release signing, notarization, stapling, and smoke order is invalid" >&2
  cat "${command_log}" >&2
  exit 1
fi
if ! grep -q 'notarytool submit .*--keychain-profile test-profile --wait --output-format json' "${command_log}"; then
  echo "Notarization does not use the Keychain profile and wait for a JSON result" >&2
  exit 1
fi
if grep -q -- '--deep --sign' "${command_log}"; then
  echo "Release pipeline used unsafe deep signing" >&2
  exit 1
fi

"${repo_root}/scripts/test-apple-dmg-smoke.sh"

echo "Apple release pipeline contract passed."
