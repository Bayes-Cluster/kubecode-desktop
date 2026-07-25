#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${KUBECODE_APP_PATH:-${repo_root}/dist/apple/Kubecode.app}"
codesign_identity="${KUBECODE_CODESIGN_IDENTITY:--}"
entitlements="${KUBECODE_APP_ENTITLEMENTS:-${repo_root}/apps/apple/Packaging/Kubecode.entitlements}"
codesign_tool="${KUBECODE_CODESIGN_TOOL:-/usr/bin/codesign}"
file_tool="${KUBECODE_FILE_TOOL:-/usr/bin/file}"
sign_phase="${KUBECODE_SIGN_PHASE:-all}"

if [[ ! -d "${app_root}" ]]; then
  echo "Kubecode app bundle does not exist: ${app_root}" >&2
  exit 1
fi
if [[ ! -f "${entitlements}" ]]; then
  echo "Kubecode app entitlements do not exist: ${entitlements}" >&2
  exit 1
fi
case "${sign_phase}" in
  nested|app|all) ;;
  *)
    echo "KUBECODE_SIGN_PHASE must be nested, app, or all" >&2
    exit 1
    ;;
esac

developer_id=0
if [[ "${codesign_identity}" == "Developer ID Application:"* ]]; then
  developer_id=1
fi

sign_code() {
  local target="$1"
  if [[ "${developer_id}" == "1" ]]; then
    "${codesign_tool}" \
      --force \
      --sign "${codesign_identity}" \
      --options runtime \
      --timestamp \
      "${target}"
  else
    "${codesign_tool}" --force --sign "${codesign_identity}" "${target}"
  fi
}

if [[ "${sign_phase}" == "nested" || "${sign_phase}" == "all" ]]; then
  # Sign every bundled Mach-O explicitly before sealing the containing app. This
  # includes the client, both Runtime/Node architectures, and future native adapter
  # dependencies without attempting to sign shell launchers as standalone code.
  while IFS= read -r candidate; do
    if [[ "$("${file_tool}" -b "${candidate}")" == *Mach-O* ]]; then
      sign_code "${candidate}"
    fi
  done < <(find "${app_root}/Contents" -type f -print | LC_ALL=C sort)
fi

if [[ "${sign_phase}" == "app" || "${sign_phase}" == "all" ]]; then
  if [[ "${developer_id}" == "1" ]]; then
    "${codesign_tool}" \
      --force \
      --sign "${codesign_identity}" \
      --options runtime \
      --timestamp \
      --entitlements "${entitlements}" \
      "${app_root}"
  else
    "${codesign_tool}" \
      --force \
      --sign "${codesign_identity}" \
      --entitlements "${entitlements}" \
      "${app_root}"
  fi
  "${codesign_tool}" --verify --deep --strict --verbose=2 "${app_root}"
fi
