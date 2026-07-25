# AGENTS.md - Kubecode Clients

## Product boundary

This repository owns Kubecode client applications. Runtime, workspace, Agent,
Terminal, Git, and Team authority remain in the `kubecode` Rust server.

- Apple clients use SwiftUI with focused AppKit/UIKit bridges.
- Windows and Linux may use Tauri in `apps/tauri` when that target is started.
- Keep platform implementations on `main`; do not create permanent OS branches.
- Never implement provider-specific Agent behavior in a client.
- Never expose or persist server absolute paths after Project registration.

## Development

- Use Swift concurrency and the Observation framework for Apple state.
- Store credentials in Keychain and non-secret preferences in Application Support.
- Keep HTTP, SSE, and WebSocket access behind `KubecodeKit`.
- Add behavior tests before fixes and avoid network-dependent unit tests.
- User-facing strings belong in localized resources.

## Checks

For Apple changes run:

```bash
swift test --package-path apps/apple
swift build --package-path apps/apple
scripts/build-apple-app.sh
```

Use conventional commits and never bypass hooks.
