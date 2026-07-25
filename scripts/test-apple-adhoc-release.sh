#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-adhoc-release-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

app_root="${test_root}/Kubecode.app"
output_path="${test_root}/Kubecode-0.1.0-universal-adhoc.dmg"
command_log="${test_root}/commands.log"
mock_hdiutil="${test_root}/hdiutil"

mkdir -p "${app_root}/Contents"
cp "${repo_root}/apps/apple/Packaging/Info.plist" "${app_root}/Contents/Info.plist"

cat >"${mock_hdiutil}" <<'MOCK'
#!/bin/sh
printf 'hdiutil %s\n' "$*" >>"${KUBECODE_TEST_COMMAND_LOG}"
output=""
previous=""
for argument in "$@"; do
  if [ "${previous}" = "-o" ]; then output="${argument}"; fi
  previous="${argument}"
done
: >"${output}"
MOCK
chmod +x "${mock_hdiutil}"

KUBECODE_APP_PATH="${app_root}" \
KUBECODE_HDIUTIL_TOOL="${mock_hdiutil}" \
KUBECODE_RELEASE_OUTPUT="${output_path}" \
KUBECODE_TEST_COMMAND_LOG="${command_log}" \
  "${repo_root}/scripts/package-apple-adhoc-dmg.sh"

grep -q '^hdiutil create -volname Kubecode .* -format UDZO -o .*Kubecode-0.1.0-universal-adhoc.dmg$' "${command_log}"
test -s "${output_path}.sha256"
grep -q 'Kubecode-0.1.0-universal-adhoc.dmg$' "${output_path}.sha256"
(
  cd "$(dirname "${output_path}")"
  shasum -a 256 -c "$(basename "${output_path}.sha256")"
)

echo "Apple ad-hoc release packaging contract passed."
