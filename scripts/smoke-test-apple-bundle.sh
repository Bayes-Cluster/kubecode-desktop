#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${KUBECODE_APP_PATH:-${repo_root}/dist/apple/Kubecode.app}"
resources_root="${app_root}/Contents/Resources"
runtime_root="${resources_root}/Runtime"
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/kubecode-bundle-smoke.XXXXXX")"
runtime_pid=""

cleanup() {
  if [[ -n "${runtime_pid}" ]] && kill -0 "${runtime_pid}" 2>/dev/null; then
    kill "${runtime_pid}"
    wait "${runtime_pid}" 2>/dev/null || true
  fi
  rm -rf "${smoke_root}"
}
trap cleanup EXIT

if [[ ! -d "${app_root}" ]]; then
  echo "Kubecode app bundle does not exist: ${app_root}" >&2
  exit 1
fi
codesign --verify --deep --strict "${app_root}"

if [[ "$(plutil -extract CFBundleIconFile raw -o - "${app_root}/Contents/Info.plist")" != "AppIcon" ]]; then
  echo "Apple bundle does not declare the canonical AppIcon" >&2
  exit 1
fi
if [[ ! -s "${resources_root}/AppIcon.icns" ]]; then
  echo "Apple bundle is missing the multi-resolution AppIcon.icns" >&2
  exit 1
fi
if [[ ! -s "${resources_root}/KubecodeMark.svg" ]]; then
  echo "Apple bundle is missing the canonical Workspace Loop mark" >&2
  exit 1
fi

for architecture in arm64 x86_64; do
  runtime_path="${runtime_root}/${architecture}/kubecode-server"
  node_path="${runtime_root}/${architecture}/node"
  if [[ ! -x "${runtime_path}" || ! -x "${node_path}" ]]; then
    echo "Apple bundle is missing executable ${architecture} Runtime payloads" >&2
    exit 1
  fi
  if [[ "$(lipo -archs "${runtime_path}")" != "${architecture}" ]]; then
    echo "Bundled Runtime has the wrong architecture: ${runtime_path}" >&2
    exit 1
  fi
  if [[ "$(lipo -archs "${node_path}")" != "${architecture}" ]]; then
    echo "Bundled Node has the wrong architecture: ${node_path}" >&2
    exit 1
  fi
done

for launcher in claude-agent-acp codex-acp; do
  if [[ ! -x "${runtime_root}/shared/${launcher}" ]]; then
    echo "Apple bundle is missing executable ${launcher}" >&2
    exit 1
  fi
done
if [[ ! -f "${resources_root}/THIRD_PARTY_NOTICES.md" ]]; then
  echo "Apple bundle is missing third-party notices" >&2
  exit 1
fi
for notice in \
  SwiftMath.txt \
  SwiftMarkdown-LICENSE.txt \
  SwiftMarkdown-NOTICE.txt \
  swift-cmark-COPYING.txt; do
  if [[ ! -s "${resources_root}/Licenses/${notice}" ]]; then
    echo "Apple bundle is missing license notice: ${notice}" >&2
    exit 1
  fi
done
if find "${runtime_root}/shared/adapter-runtime/node_modules" \
  \( -name '*claude-agent-sdk-darwin-*' -o -name '*codex-darwin-*' \) \
  -print -quit | grep -q .; then
  echo "Apple bundle unexpectedly contains a provider-native Agent binary" >&2
  exit 1
fi
(
  cd "${resources_root}"
  shasum -a 256 -c Runtime/PAYLOAD_SHA256SUMS >/dev/null
)

case "$(uname -m)" in
  arm64) runtime_architecture="arm64" ;;
  x86_64) runtime_architecture="x86_64" ;;
  *)
    echo "Unsupported smoke-test architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
runtime_path="${runtime_root}/${runtime_architecture}/kubecode-server"
node_path="${runtime_root}/${runtime_architecture}/node"
"${node_path}" --version >/dev/null

mkdir -p "${smoke_root}/home" "${smoke_root}/workspace" "${smoke_root}/state"
access_token="bundle-smoke-$(uuidgen)"
token_path="${smoke_root}/access-token"
ready_path="${smoke_root}/ready.json"
stderr_path="${smoke_root}/runtime.log"
printf '%s\n' "${access_token}" >"${token_path}"
chmod 600 "${token_path}"

(
  cd "${smoke_root}/workspace"
  exec env \
    HOME="${smoke_root}/home" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    KUBECODE_NODE_PATH="${node_path}" \
    KUBECODE_CLAUDE_ACP_PATH="${runtime_root}/shared/claude-agent-acp" \
    KUBECODE_CODEX_ACP_PATH="${runtime_root}/shared/codex-acp" \
    "${runtime_path}" \
      --host 127.0.0.1 \
      --port 0 \
      --workspace-root "${smoke_root}/workspace" \
      --state-dir "${smoke_root}/state" \
      --api-only \
      --access-token-stdin \
      --ready-json \
      <"${token_path}" \
      >"${ready_path}" \
      2>"${stderr_path}"
) &
runtime_pid=$!

for _ in {1..150}; do
  if [[ -s "${ready_path}" ]]; then break; fi
  if ! kill -0 "${runtime_pid}" 2>/dev/null; then
    cat "${stderr_path}" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! -s "${ready_path}" ]]; then
  cat "${stderr_path}" >&2
  echo "Bundled Runtime did not become ready" >&2
  exit 1
fi

origin="$(plutil -extract origin raw -o - "${ready_path}")"
base_path="$(plutil -extract base_path raw -o - "${ready_path}")"
normalized_base_path="${base_path%/}"
curl --fail --silent --show-error \
  "${origin}${normalized_base_path}/.well-known/kubecode" \
  -o "${smoke_root}/discovery.json"
unauthorized_status="$(curl \
  --silent \
  --output /dev/null \
  --write-out '%{http_code}' \
  "${origin}${normalized_base_path}/api/v1/projects")"
if [[ "${unauthorized_status}" != "401" ]]; then
  echo "Bundled Runtime accepted an unauthenticated API request (${unauthorized_status})" >&2
  exit 1
fi
team_mcp_status="$(curl \
  --silent \
  --output /dev/null \
  --write-out '%{http_code}' \
  "${origin}${normalized_base_path}/api/v1/team-mcp/invalid-team-token/unknown-conversation")"
if [[ "${team_mcp_status}" != "404" ]]; then
  echo "Bundled Runtime routed Team MCP through desktop API authentication (${team_mcp_status})" >&2
  exit 1
fi
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${access_token}" \
  "${origin}${normalized_base_path}/api/v1/projects" \
  -o "${smoke_root}/projects.json"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${access_token}" \
  "${origin}${normalized_base_path}/api/v1/agents" \
  -o "${smoke_root}/agents.json"

validator="${smoke_root}/apple-bundle-smoke-validator"
swiftc \
  "${repo_root}/scripts/apple-bundle-smoke-validator.swift" \
  -o "${validator}"
"${validator}" \
  "${ready_path}" \
  "${smoke_root}/discovery.json" \
  "${smoke_root}/projects.json" \
  "${smoke_root}/agents.json"
