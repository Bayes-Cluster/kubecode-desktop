# ADR 0003: Shared Apple client architecture

## Status

Proposed

## Current implementation

The platform-neutral `KubecodeKit`, `KubecodeCore`, and `KubecodeUI` targets,
the macOS-only `KubecodeMacRuntime` target, application-scoped
`MacConnectionManager`, and one-`ServerSession`-per-profile ownership model are
implemented. `scripts/test-apple-shared-ios.sh` compiles all three shared
targets against the installed iPhoneOS SDK.

This ADR remains Proposed because the repository does not yet contain the
decision's Xcode workspace or universal `KubecodeMobile` application target.
Those are Phase 4 deliverables; shared-target compilation is not evidence that
the iPhone/iPad application architecture is complete.

## Context

The initial macOS vertical slice places protocol access, local Runtime process
ownership, all observable state, and most UI behavior in a small Swift package.
`Process` and local filesystem behavior cannot compile or run on iOS, and one
global `AppModel` cannot safely own multiple Server profiles, windows, and
reconnectable event streams.

The clients must share semantics without forcing iPhone and iPad into the
macOS workstation layout.

## Decision

Use an Xcode workspace for application targets and local Swift packages for
shared implementation. Evolve the current sources into these boundaries:

- `KubecodeKit`: platform-neutral API models, HTTP/SSE/WebSocket transports,
  discovery, request validation, and resource repositories. It imports no
  AppKit and owns no local processes.
- `KubecodeCore`: a `ServerSession` actor, event cursor, resource projections,
  commands, and platform-neutral reducers. The server remains the source of
  truth; projections are client presentation state.
- `KubecodeMacRuntime`: macOS-only local and SSH Runtime process ownership,
  bundle resolution, login-shell Agent discovery support, and process logs.
- `KubecodeUI`: shared transcript, tool, attention, Team, and status
  presentation primitives. Root navigation, editor, terminal layout, and
  platform commands remain in each application target.
- `KubecodeMac` and `KubecodeMobile`: application lifecycle, scenes,
  navigation, settings, entitlements, and platform-specific views. The mobile
  target is universal for iPhone and iPad.

Each connected Server has one `ServerSession`. It owns one authenticated
transport, one reconnecting workspace-event stream, and resource projections
for that Server. Main-actor view models observe projections and issue typed
commands. They do not execute requests directly and never refresh the complete
workspace for a token delta.

Application-scoped connection management replaces `AppModel.shared`.
Independent windows may select different resources while sharing the same
ServerSession. Only the connection manager may create or stop a managed
Runtime. The native application termination callback always asks that manager
to stop every app-owned local Runtime, SSH Runtime, and SSH tunnel, including
connections that are still starting. Quit confirmation is based on managed
process ownership, not on the presence of a `ServerSession`: an HTTPS-attached
Server remains externally owned and does not receive a misleading local
Runtime shutdown warning.

Minimum deployment targets remain macOS 14 and iOS/iPadOS 17 unless an API
requirement receives a superseding ADR.

## Consequences

Protocol behavior, event reduction, security policy, and most monitoring UI can
be tested once across Apple platforms. macOS retains a full native workstation,
while mobile navigation and capabilities remain intentionally smaller.

The migration is incremental: move local process ownership first, then shared
state, and only then add mobile application targets. Existing Runtime API
shapes do not change because of this module split.
