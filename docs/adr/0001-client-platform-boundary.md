# ADR 0001: Client platform boundary

## Status

Accepted

## Context

Kubecode has a standalone Rust Runtime and browser client. Apple platforms need
a native experience, while Windows and Linux can reuse the browser workbench in
a Tauri shell. Permanent platform branches would allow protocol and security
behavior to drift.

## Decision

Keep all clients on one `main` branch. Native Apple code lives in `apps/apple`;
future Windows and Linux code will live in `apps/tauri`. Clients treat the
versioned Kubecode Runtime API as the only authority for Projects, Sessions,
Teams, files, Git, terminals, and provider processes.

The first release is a macOS 14+ Universal local client. It launches an API-only
Runtime on loopback with an ephemeral bearer token. SSH-managed and HTTPS-attached
servers share the connection model but are not exposed until implemented.

The macOS terminal uses the vendored SwiftTerm 1.15.0 emulator and attaches to
Runtime-owned PTYs over the authenticated terminal WebSocket. The source archive
is pinned by SHA-256
`fd7d6ed1313c623163f79046c9e868a2f98eb27148124381deaca5c50d5b8838`;
its reduced local package manifest omits unrelated sample executables and build
plugins. It also excludes the optional Metal shader resource because the app
uses SwiftTerm's default AppKit/CoreText renderer; this keeps release builds
independent of Xcode's separately installed Metal toolchain. The Swift library
source is otherwise unchanged.

## Consequences

Apple UI can be genuinely native without duplicating backend behavior. Runtime
and client releases require explicit protocol compatibility, and all platforms
receive contract and security changes from the same branch.
