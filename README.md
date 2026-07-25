# Kubecode Clients

Native and desktop clients for the Kubecode Runtime.

- `apps/apple`: native macOS client. iOS and iPadOS companion targets will share its client kit later.
- `apps/tauri`: reserved for the future Windows and Linux client; no placeholder application is shipped yet.

The Runtime, browser client, and protocol source of truth remain in the separate
`kubecode` repository. Platform implementations live together on `main`; long-lived
operating-system branches are not used.

## macOS development

Run the native client directly against a source-built Runtime:

```bash
cargo build --manifest-path ../kubecode/server/Cargo.toml
KUBECODE_SERVER_PATH=../kubecode/server/target/debug/kubecode-server \
  swift run --package-path apps/apple Kubecode
```

Build the internal ad-hoc signed Universal application with both Runtime
architectures embedded:

```bash
scripts/build-apple-app.sh
```

The build ends by launching only the bundled current-architecture Runtime,
Node, and ACP payload in isolated temporary directories. Run the same
standalone gate against an existing app explicitly with:

```bash
scripts/smoke-test-apple-bundle.sh
```

Validate that every compiler-emitted SwiftUI string has matching English and
Simplified Chinese catalog entries, with no stale keys or placeholder drift:

```bash
scripts/validate-apple-localizations.sh
```

Run the named keyboard shortcut and accessibility-contract acceptance on a
macOS 14 or macOS 26 host, then complete the matching VoiceOver and Full
Keyboard Access checklist:

```bash
scripts/test-apple-accessibility-keyboard.sh
```

The manual checklist and per-OS evidence table are in
`docs/qa/MACOS_ACCESSIBILITY_KEYBOARD.md`.

The build requires the Rust `aarch64-apple-darwin` and `x86_64-apple-darwin`
targets. `KUBECODE_SERVER_ARM64` and `KUBECODE_SERVER_X86_64` can point at
prebuilt Runtime binaries.

For iterative UI development, use a stable Apple Development signing identity
so macOS Files & Folders and Screen Recording grants survive rebuilds:

```bash
KUBECODE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  scripts/build-apple-app.sh
```

Without that variable the script uses an ad-hoc signature. Each changed build
then has a new code hash, so macOS can require those privacy permissions again.

Create a Developer ID signed, Hardened Runtime enabled, notarized release DMG
with credentials referenced only through a native Keychain profile:

```bash
KUBECODE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KUBECODE_NOTARY_PROFILE="kubecode-notary" \
  scripts/release-apple-dmg.sh
```

`scripts/test-apple-release-pipeline.sh` verifies signing and notarization
ordering without credentials. The real release and clean-machine evidence
workflow is documented in `docs/qa/MACOS_RELEASE.md`.

Local Project selection uses `NSOpenPanel` and persists an opaque
security-scoped bookmark by Project ID. Remote Server profiles keep using the
Runtime directory browser because those paths belong to the remote host.

The leading macOS Navigator owns a native lazy Project tree for files and a
grouped Changes view for staged and worktree Git state. File operations and Git
mutations remain Project-scoped Runtime requests; the client never invokes Git
or mutates registered folders directly. Changes, provider-native Agent Plan,
and Files are independently collapsible sections in one bottom-anchored native
Explorer stack: expanded content grows upward and Files retains the remaining
height while Changes and Plan use bounded scrolling regions.

Session turn actions use native menus and sheets. Edit, Regenerate, and Undo
create hidden immutable revisions while preserving the logical Session; a
native navigator opens prior snapshots read-only. Explicit Branch creates a
visible Session and makes Project checkpoint restoration an explicit choice.

The workspace Navigator uses native macOS search with `Command-K`, bounded
cross-Project Project/Session/Team results, and a global attention menu.
Durable Runtime events keep Project and Session badges current without
reindexing on text or tool streaming deltas.
Active Agent runs use sequence-aware SSE resume with bounded backoff; long
thinking, response, and tool streams coalesce into stable provider-owned rows.
Within the selected Project, native sections prioritize attention and active
work, relationship disclosures preserve branch/fork/subagent hierarchy, and
window-scoped filters control Agent, ordering, and archived visibility.
Project switching, Session hierarchy, Teams, and Server selection now share one
native Navigator rather than consuming separate sidebar columns.

Composer drafts are isolated per window and Session, remain editable while an
Agent runs, and recover after failed starts. Relaunch persistence is a native,
off-by-default privacy setting.

Session titlebar and sidebar menus expose rename, Agent-title restore, archive,
fork, Team promotion, and guarded deletion with Team-aware confirmation.

Sort/filter, Navigator collapse, Refresh Workspace, and Quick Open are a
sidebar-owned native tool strip above the persistent search field; they are not
emitted into the middle detail toolbar. Search is focused by `Command-K`, with
no duplicate search button. Terminal and Agent TUI controls live exclusively
in the persistent collapsible lower workbench.
