#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-dmg-smoke-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

dmg_path="${test_root}/Kubecode-test.dmg"
command_log="${test_root}/commands.log"
: >"${dmg_path}"
: >"${command_log}"

mock_hdiutil="${test_root}/hdiutil"
cat >"${mock_hdiutil}" <<'MOCK'
#!/bin/sh
printf 'hdiutil %s\n' "$*" >>"${KUBECODE_TEST_COMMAND_LOG}"
case "$1" in
  attach)
    mountpoint=""
    previous=""
    for argument in "$@"; do
      if [ "${previous}" = "-mountpoint" ]; then mountpoint="${argument}"; fi
      previous="${argument}"
    done
    mkdir -p "${mountpoint}/Kubecode.app/Contents/MacOS"
    if [ "${KUBECODE_TEST_BAD_MOUNT:-0}" = "1" ]; then
      ln -s /Wrong "${mountpoint}/Applications"
    else
      ln -s /Applications "${mountpoint}/Applications"
    fi
    ;;
esac
MOCK

make_log_mock() {
  local name="$1"
  local path="${test_root}/${name}"
  cat >"${path}" <<MOCK
#!/bin/sh
printf '${name} %s\\n' "\$*" >>"\${KUBECODE_TEST_COMMAND_LOG}"
MOCK
  chmod +x "${path}"
  printf '%s' "${path}"
}

chmod +x "${mock_hdiutil}"
mock_xcrun="$(make_log_mock xcrun)"
mock_spctl="$(make_log_mock spctl)"
mock_codesign="$(make_log_mock codesign)"
mock_bundle_smoke="$(make_log_mock bundle-smoke)"

KUBECODE_HDIUTIL_TOOL="${mock_hdiutil}" \
KUBECODE_XCRUN_TOOL="${mock_xcrun}" \
KUBECODE_SPCTL_TOOL="${mock_spctl}" \
KUBECODE_CODESIGN_TOOL="${mock_codesign}" \
KUBECODE_BUNDLE_SMOKE_TOOL="${mock_bundle_smoke}" \
KUBECODE_TEST_COMMAND_LOG="${command_log}" \
  "${repo_root}/scripts/smoke-test-apple-dmg.sh" "${dmg_path}"

dmg_staple_line="$(grep -n "^xcrun stapler validate ${dmg_path}$" "${command_log}" | cut -d: -f1)"
dmg_gatekeeper_line="$(grep -n "^spctl --assess --type open .* ${dmg_path}$" "${command_log}" | cut -d: -f1)"
mount_line="$(grep -n "^hdiutil attach -readonly -nobrowse -mountpoint .* ${dmg_path}$" "${command_log}" | cut -d: -f1)"
app_codesign_line="$(grep -n '^codesign --verify --deep --strict --verbose=2 .*Kubecode.app$' "${command_log}" | cut -d: -f1)"
app_staple_line="$(grep -n '^xcrun stapler validate .*Kubecode.app$' "${command_log}" | cut -d: -f1)"
app_gatekeeper_line="$(grep -n '^spctl --assess --type execute --verbose=4 .*Kubecode.app$' "${command_log}" | cut -d: -f1)"
bundle_smoke_line="$(grep -n '^bundle-smoke $' "${command_log}" | cut -d: -f1)"
detach_line="$(grep -n '^hdiutil detach .* -quiet$' "${command_log}" | cut -d: -f1)"

if ! (( dmg_staple_line < dmg_gatekeeper_line \
  && dmg_gatekeeper_line < mount_line \
  && mount_line < app_codesign_line \
  && app_codesign_line < app_staple_line \
  && app_staple_line < app_gatekeeper_line \
  && app_gatekeeper_line < bundle_smoke_line \
  && bundle_smoke_line < detach_line )); then
  echo "DMG smoke validation order is invalid" >&2
  cat "${command_log}" >&2
  exit 1
fi

: >"${command_log}"
if KUBECODE_HDIUTIL_TOOL="${mock_hdiutil}" \
  KUBECODE_XCRUN_TOOL="${mock_xcrun}" \
  KUBECODE_SPCTL_TOOL="${mock_spctl}" \
  KUBECODE_CODESIGN_TOOL="${mock_codesign}" \
  KUBECODE_BUNDLE_SMOKE_TOOL="${mock_bundle_smoke}" \
  KUBECODE_TEST_BAD_MOUNT=1 \
  KUBECODE_TEST_COMMAND_LOG="${command_log}" \
  "${repo_root}/scripts/smoke-test-apple-dmg.sh" "${dmg_path}" >/dev/null 2>&1; then
  echo "DMG smoke accepted an invalid Applications link" >&2
  exit 1
fi
if ! grep -q '^hdiutil detach .* -quiet$' "${command_log}"; then
  echo "DMG smoke did not detach an invalid mounted image" >&2
  exit 1
fi

echo "Apple DMG smoke contract passed."
