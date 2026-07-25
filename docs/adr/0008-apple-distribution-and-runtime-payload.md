# ADR 0008: Apple distribution and Runtime payload

## Status

Proposed

## Context

The current ad-hoc macOS bundle contains the Swift executable and two Rust
Runtime architectures, but adapter discovery can still fall back to paths in
the source checkout. That bundle is a development artifact, not a standalone
release. macOS also needs to launch user-installed provider CLIs and operate
user-selected development directories, which conflicts with a Mac App Store
sandbox-first distribution.

Mobile has the opposite boundary: it launches no local processes and should use
normal App Store sandboxing.

## Decision

The macOS release is a Universal Developer ID application distributed in a
signed and notarized DMG. It uses Hardened Runtime but is not App Sandbox
constrained. The bundle contains:

- Universal native client code;
- arm64 and x86_64 `kubecode-server` executables;
- architecture-appropriate Node executables;
- the pinned Claude Code and Codex ACP adapter runtime and production
  dependencies;
- adapter launchers, a version/checksum manifest, licenses, and third-party
  notices.

OpenCode continues to use its native ACP support. Claude Code, Codex, and
OpenCode CLIs, credentials, configuration, and provider-native history are not
bundled. Runtime discovery searches explicit bundled adapter paths and the
user's provider CLI locations; it never relies on a build machine source path
in release mode.

Sign nested executables before signing the containing application. The release
pipeline verifies signatures, notarization, manifest checksums, protocol
compatibility, and launch on clean arm64 and x86_64 macOS installations with no
source checkout.

Only one app-owned local Runtime may use a profile's state directory. A second
application process activates the first instance or attaches through an
authenticated handoff; it must not race SQLite ownership.

The first releases use manual signed updates. Adding an automatic updater
requires a separate ADR covering the dependency, feed signing, rollback, and
Runtime/client compatibility.

The universal iPhone/iPad application is App Store sandboxed and distributed
through TestFlight and the App Store. It contains no Runtime, Node, ACP adapter,
provider CLI, or executable download path.

## Consequences

The macOS app can be moved to a clean machine and behave like the development
build without depending on either repository. Direct distribution preserves
the workstation capabilities Kubecode requires while still using Apple signing
and notarization.

The macOS artifact is larger and its nested payload needs explicit supply-chain
and architecture testing. Mobile remains small and compatible with App Store
review expectations.

## Implementation status

The development bundle now contains the Universal Swift client, both Rust
Runtime architectures, architecture-matched pinned Node executables, production
ACP adapter dependencies, launchers, notices, and a payload checksum manifest.
The build verifies Node archives against the official release checksum list,
rejects provider-native binaries, signs each nested Mach-O before generating
the checksum manifest, and seals the outer app last. Local
architecture, payload checksum, and signature verification pass. Its mandatory
post-build smoke runs from isolated HOME, working, state, and workspace
directories with system PATH only. It starts the current-architecture bundled
Runtime with bundled Node and ACP launchers, verifies loopback readiness,
protocol-v1 discovery, bearer enforcement, an empty Project catalog, and all
three Agent descriptors. It also structurally checks both architecture payloads
and all manifest entries before launch.

The release pipeline requires an explicit Developer ID Application identity
and a `notarytool` Keychain profile. It enables Hardened Runtime with a minimal
explicit entitlement set, separately submits and staples the app and signed
DMG, requires Apple's JSON result to be `Accepted`, performs Gatekeeper
assessment, and mounts the final DMG read-only for the same isolated Runtime
smoke. A credential-free contract test verifies inside-out signing, submission,
stapling, rejection, and smoke ordering.

Real Developer ID and notarization receipts plus clean-machine macOS 26 on
arm64/x86_64 launch evidence remain release gates. macOS 14 remains a
deployment target but is outside the release acceptance matrix.
