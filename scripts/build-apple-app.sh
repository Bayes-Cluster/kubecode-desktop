#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="${repo_root}/apps/apple"
runtime_repo="${KUBECODE_RUNTIME_REPO:-${repo_root}/../kubecode}"
products_root="${repo_root}/dist/apple"
app_root="${products_root}/Kubecode.app"
codesign_identity="${KUBECODE_CODESIGN_IDENTITY:--}"
node_version="$(tr -d '[:space:]' < "${runtime_repo}/packaging/NODE_VERSION")"
payload_cache="${products_root}/cache"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-apple-build.XXXXXX")"
cleanup() {
  rm -rf "${temporary_root}"
}
trap cleanup EXIT

swift build \
  --package-path "${apple_root}" \
  --configuration release \
  --arch arm64 \
  --arch x86_64
swift_bin_path="$(swift build \
  --package-path "${apple_root}" \
  --configuration release \
  --arch arm64 \
  --arch x86_64 \
  --show-bin-path)"

rm -rf "${app_root}"
mkdir -p \
  "${app_root}/Contents/MacOS" \
  "${app_root}/Contents/Resources/Runtime/arm64" \
  "${app_root}/Contents/Resources/Runtime/x86_64" \
  "${app_root}/Contents/Resources/Runtime/shared" \
  "${app_root}/Contents/Resources/Licenses" \
  "${payload_cache}"
cp "${apple_root}/Packaging/Info.plist" "${app_root}/Contents/Info.plist"
cp "${swift_bin_path}/Kubecode" "${app_root}/Contents/MacOS/Kubecode"
cp "${apple_root}/Packaging/AppIcon.icns" "${app_root}/Contents/Resources/AppIcon.icns"
cp "${apple_root}/Packaging/KubecodeMark.svg" "${app_root}/Contents/Resources/KubecodeMark.svg"

while IFS= read -r resource_bundle; do
  cp -R "${resource_bundle}" "${app_root}/Contents/Resources/"
done < <(find "${swift_bin_path}" -maxdepth 1 -name '*.bundle' -print)

app_resource_bundle="$(find \
  "${app_root}/Contents/Resources" \
  -maxdepth 1 \
  -type d \
  -name '*_KubecodeApp.bundle' \
  -print \
  -quit)"
if [[ -z "${app_resource_bundle}" ]]; then
  echo "Apple bundle is missing the KubecodeApp resource bundle" >&2
  exit 1
fi
app_resource_root="${app_resource_bundle}/Contents/Resources"
if [[ ! -d "${app_resource_root}" ]]; then
  app_resource_root="${app_resource_bundle}"
fi
for localization in en zh-Hans; do
  localization_source="${app_resource_root}/${localization}.lproj"
  if [[ ! -f "${localization_source}/Localizable.strings" ]]; then
    echo "Apple bundle is missing ${localization} localization resources" >&2
    exit 1
  fi
  cp -R \
    "${localization_source}" \
    "${app_root}/Contents/Resources/${localization}.lproj"
done

if [[ ! -f "${app_root}/Contents/Resources/SwiftMath_SwiftMath.bundle/Contents/Resources/mathFonts.bundle/Asana-Math.otf" ]]; then
  echo "Apple bundle is missing the native math font resource" >&2
  exit 1
fi

build_runtime() {
  local rust_target="$1"
  cargo build \
    --manifest-path "${runtime_repo}/server/Cargo.toml" \
    --release \
    --target "${rust_target}"
  printf '%s/server/target/%s/release/kubecode-server' "${runtime_repo}" "${rust_target}"
}

arm64_runtime="${KUBECODE_SERVER_ARM64:-}"
x86_64_runtime="${KUBECODE_SERVER_X86_64:-}"
if [[ -z "${arm64_runtime}" ]]; then
  arm64_runtime="$(build_runtime aarch64-apple-darwin)"
fi
if [[ -z "${x86_64_runtime}" ]]; then
  x86_64_runtime="$(build_runtime x86_64-apple-darwin)"
fi

cp "${arm64_runtime}" "${app_root}/Contents/Resources/Runtime/arm64/kubecode-server"
cp "${x86_64_runtime}" "${app_root}/Contents/Resources/Runtime/x86_64/kubecode-server"

install_node() {
  local app_arch="$1"
  local node_arch="$2"
  local override="$3"
  local archive="${payload_cache}/node-v${node_version}-darwin-${node_arch}.tar.gz"
  local partial_archive="${archive}.partial"
  local checksum_manifest="${payload_cache}/node-v${node_version}-SHASUMS256.txt"
  local checksum_manifest_partial="${checksum_manifest}.partial"
  local archive_name="node-v${node_version}-darwin-${node_arch}.tar.gz"
  local expected_checksum
  local extracted="${temporary_root}/node-${app_arch}"
  local source_root
  if [[ -n "${override}" ]]; then
    cp "${override}" "${app_root}/Contents/Resources/Runtime/${app_arch}/node"
    return
  fi

  if [[ ! -s "${checksum_manifest}" ]]; then
    curl --fail --location \
      --retry 8 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
      "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" \
      --output "${checksum_manifest_partial}"
    mv "${checksum_manifest_partial}" "${checksum_manifest}"
  fi
  expected_checksum="$(awk -v archive_name="${archive_name}" '$2 == archive_name { print $1 }' "${checksum_manifest}")"
  if [[ -z "${expected_checksum}" ]]; then
    echo "Node checksum manifest does not contain ${archive_name}" >&2
    exit 1
  fi

  if [[ -f "${archive}" ]] && ! printf '%s  %s\n' "${expected_checksum}" "${archive}" | shasum -a 256 -c - >/dev/null 2>&1; then
    if [[ ! -f "${partial_archive}" ]]; then
      mv "${archive}" "${partial_archive}"
    fi
  fi
  if [[ ! -f "${archive}" ]] || ! printf '%s  %s\n' "${expected_checksum}" "${archive}" | shasum -a 256 -c - >/dev/null 2>&1; then
    if [[ -s "${partial_archive}" ]] && ! curl --fail --location \
      --connect-timeout 20 --continue-at - \
      "https://nodejs.org/dist/v${node_version}/${archive_name}" \
      --output "${partial_archive}"; then
      echo "Node mirror cannot resume ${archive_name}; restarting the partial download" >&2
      curl --fail --location \
        --retry 8 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
        "https://nodejs.org/dist/v${node_version}/${archive_name}" \
        --output "${partial_archive}"
    elif [[ ! -s "${partial_archive}" ]]; then
      curl --fail --location \
        --retry 8 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
        "https://nodejs.org/dist/v${node_version}/${archive_name}" \
        --output "${partial_archive}"
    fi
    printf '%s  %s\n' "${expected_checksum}" "${partial_archive}" | shasum -a 256 -c -
    mv "${partial_archive}" "${archive}"
  fi
  mkdir -p "${extracted}"
  tar -xzf "${archive}" -C "${extracted}"
  source_root="${extracted}/node-v${node_version}-darwin-${node_arch}"
  cp "${source_root}/bin/node" "${app_root}/Contents/Resources/Runtime/${app_arch}/node"
  cp "${source_root}/LICENSE" "${app_root}/Contents/Resources/Licenses/node-${app_arch}.txt"
}

install_node arm64 arm64 "${KUBECODE_NODE_ARM64:-}"
install_node x86_64 x64 "${KUBECODE_NODE_X86_64:-}"

adapter_stage="${temporary_root}/adapter-runtime"
(
  cd "${runtime_repo}"
  pnpm --filter @kubecode/adapter-runtime deploy --prod --no-optional "${adapter_stage}"
)
cp -R "${adapter_stage}" "${app_root}/Contents/Resources/Runtime/shared/adapter-runtime"
if find "${app_root}/Contents/Resources/Runtime/shared/adapter-runtime/node_modules" \
  \( -name '*claude-agent-sdk-darwin-*' -o -name '*codex-darwin-*' \) \
  -print -quit | grep -q .; then
  echo "Apple bundle unexpectedly contains a provider-native Agent binary" >&2
  exit 1
fi
cp "${apple_root}/Packaging/Runtime/claude-agent-acp" \
  "${app_root}/Contents/Resources/Runtime/shared/claude-agent-acp"
cp "${apple_root}/Packaging/Runtime/codex-acp" \
  "${app_root}/Contents/Resources/Runtime/shared/codex-acp"
cp "${runtime_repo}/packaging/THIRD_PARTY_NOTICES.md" \
  "${app_root}/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "${apple_root}/Vendor/SwiftMath/LICENSE" \
  "${app_root}/Contents/Resources/Licenses/SwiftMath.txt"
cp "${apple_root}/Vendor/SwiftMarkdown/LICENSE.txt" \
  "${app_root}/Contents/Resources/Licenses/SwiftMarkdown-LICENSE.txt"
cp "${apple_root}/Vendor/SwiftMarkdown/NOTICE.txt" \
  "${app_root}/Contents/Resources/Licenses/SwiftMarkdown-NOTICE.txt"
cp "${apple_root}/Vendor/swift-cmark/COPYING" \
  "${app_root}/Contents/Resources/Licenses/swift-cmark-COPYING.txt"
chmod +x \
  "${app_root}/Contents/MacOS/Kubecode" \
  "${app_root}/Contents/Resources/Runtime/arm64/kubecode-server" \
  "${app_root}/Contents/Resources/Runtime/x86_64/kubecode-server" \
  "${app_root}/Contents/Resources/Runtime/arm64/node" \
  "${app_root}/Contents/Resources/Runtime/x86_64/node" \
  "${app_root}/Contents/Resources/Runtime/shared/claude-agent-acp" \
  "${app_root}/Contents/Resources/Runtime/shared/codex-acp"

KUBECODE_APP_PATH="${app_root}" \
KUBECODE_CODESIGN_IDENTITY="${codesign_identity}" \
KUBECODE_SIGN_PHASE=nested \
  "${repo_root}/scripts/sign-apple-app.sh"

(
  cd "${app_root}/Contents/Resources"
  find Runtime -type f ! -name PAYLOAD_SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 \
    > Runtime/PAYLOAD_SHA256SUMS
)

KUBECODE_APP_PATH="${app_root}" \
KUBECODE_CODESIGN_IDENTITY="${codesign_identity}" \
KUBECODE_SIGN_PHASE=app \
  "${repo_root}/scripts/sign-apple-app.sh"
if [[ "${codesign_identity}" == "-" ]]; then
  echo "WARNING: ad-hoc signing changes the app identity after rebuilds; macOS may require Files & Folders and Screen Recording permissions again." >&2
fi
KUBECODE_APP_PATH="${app_root}" "${repo_root}/scripts/smoke-test-apple-bundle.sh"
echo "Built ${app_root}"
