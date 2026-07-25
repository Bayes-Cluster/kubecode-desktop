# Apple Platform Development Roadmap

## Goal

Build one native Apple client family around the Kubecode Runtime API:

- macOS is the complete coding workstation and can own local or SSH-managed
  Runtime processes.
- iPhone and iPad are authenticated companions for monitoring, approvals,
  control, and lightweight prompts.
- All clients use the same Project, Session, Team, file, Git, terminal, and
  workspace-event contracts. Platform code changes presentation and process
  ownership, not resource semantics.

The current macOS app implements the browser workstation capability baseline
with native Apple controls. Project, Session, Agent interaction, editor, Git,
Terminal, Team, local/SSH/HTTPS Server, settings, diagnostics, and localization
rows are complete in `MACOS_BROWSER_PARITY.md`. The standalone ad-hoc bundle and
Runtime smoke pass; Developer ID signing/notarization, clean-machine release
evidence, and manual macOS 26 accessibility QA remain before distribution.

The platform-neutral `KubecodeKit`, `KubecodeCore`, and `KubecodeUI` targets
currently compile against the installed iPhoneOS SDK. Run
`scripts/test-apple-shared-ios.sh` when changing shared models, transport, or
projection code; the macOS-only executable and `KubecodeMacRuntime` remain
outside this gate.

Current phase status:

- Phases 1-3: macOS functional scope complete; release and manual QA gates
  remain.
- Phase 0: shared package boundaries and standalone ad-hoc bundle complete;
  the Xcode workspace/mobile target and clean-machine signed matrix remain.
- Phase 4: not started. No `KubecodeMobile` application target exists yet.
- Phase 5: release automation exists, but real Developer ID/notary evidence and
  mobile distribution remain.

## Delivery sequence

### Phase 0: Shared foundation and standalone development build

1. Accept ADRs 0003, 0006, 0007, and 0008.
2. Replace the global `AppModel` boundary with a shared `ServerSession` and
   resource projections. Keep platform view models on the main actor and
   transport/process work in actors.
3. Move local process launch into the macOS-only module so `KubecodeKit` and
   shared state compile for iOS and iPadOS.
4. Add an Xcode workspace with macOS and universal iOS application targets;
   continue using local Swift packages for shared code.
5. Produce a clean-machine macOS bundle containing both Runtime architectures,
   Node, ACP adapters, manifests, and notices. Provider CLIs and credentials
   remain user-installed and provider-owned.
6. Add API contract fixtures, SSE replay tests, terminal WebSocket integration
   tests, and a clean-machine packaging smoke test.

Exit criteria:

- The app runs on a Mac without either source repository present.
- The shared packages compile for macOS, iOS, and iPadOS.
- A second app window or accidental second launch does not start a competing
  local Runtime against the same state database.
- Disconnect and reconnect preserve the workspace-event cursor without
  duplicating transcript deltas.

### Phase 1: macOS Agent and Session alpha

Implement the blocking interactive loop before broad workspace features:

1. Render text, thinking, tool lifecycle, Plan, Usage, provider messages, and
   system notices as stable structured transcript items.
2. Add permission choice, elicitation forms, waiting states, run cancellation,
   failure recovery, and Claude Code side questions.
3. Render all provider-native modes and configuration options without creating
   a cross-provider settings model. Keep mode mutations locked between turns
   according to Runtime `mode_access`.
4. Complete Session create, import/resume, rename, archive, delete, fork,
   worktree selection, history pagination, revisions, edit, regenerate, undo,
   and read-only/recreated-context states.
5. Add bounded event coalescing so token streaming remains responsive without
   refreshing Agents, files, Git, Teams, and terminals for every delta.

Exit criteria:

- No supported Agent can wait on a user-owned permission or elicitation that
  the macOS app cannot display and resolve.
- Long streaming turns remain one message per provider message ID and can be
  cancelled.
- Session state survives relaunch and history pagination preserves scroll and
  stable identities.

### Phase 2: macOS workspace beta

1. Replace the single-document editor with a multi-document native workbench:
   lazy tree, quick open, syntax-aware editor, dirty-close confirmation,
   revision conflicts, optional auto-save, and create/rename/delete entry
   operations.
2. Complete Git init, staged/unstaged/untracked groups, diff, stage, unstage,
   discard confirmation, and commit.
3. Complete terminal profiles, close, restart, rename, groups, horizontal and
   vertical splits, persisted layout, cursor snapshots, reconnect, and exited
   states.
4. Add settings for Agent diagnostics, appearance, editor, terminal, and
   notifications. Localize every user-facing string in English and Simplified
   Chinese.
5. Route file, Git, terminal, Session, and Agent changes through targeted event
   projections instead of whole-workspace refreshes.

Exit criteria:

- A user can complete the normal edit-test-review-commit loop without opening
  the browser client.
- Terminal layout and open editor state restore after relaunch without
  restarting server-owned PTYs.
- Stale document revisions never overwrite server changes silently.

### Phase 3: macOS Team control and remote servers

1. Complete Team creation/promotion, Standard and YOLO setup, proposal review,
   task board, assignment, retry, cancel, member removal, user-input requests,
   permission review, activity, dependencies, verification, completion, and
   disbanding.
2. Add `ssh_managed` profiles using the system `ssh` executable and
   `~/.ssh/config`. The client owns the remote Runtime process and a separate
   loopback tunnel process, and tears both down on disconnect.
3. Add `https_attached` profiles with system TLS validation and Keychain-backed
   bearer credentials. Accept Kubeflow endpoints only when their ingress can
   expose the advertised bearer-compatible Runtime API.
4. Add Server management, discovery/version diagnostics, connection health,
   and explicit reconnect controls.

Exit criteria:

- Local, SSH-managed, and HTTPS-attached profiles present the same workspace
  model and pass the same contract suite.
- Team attention always has an actionable native control or a copyable
  diagnostic.
- SSH disconnect cannot leave a client-owned remote Runtime indefinitely.

### Phase 4: iPhone and iPad companion beta

1. Ship one universal iOS application target with adaptive navigation.
2. Start with manually configured HTTPS URL and bearer token profiles. Add
   short-lived QR pairing only after the pairing protocol in ADR 0006 is
   implemented by the Runtime.
3. Implement iPhone views for server health, attention inbox, Session and Team
   summaries, permission/elicitation resolution, pause/resume/cancel, Team
   user-input replies, and lightweight prompts.
4. Implement iPad views for the same controls plus full transcripts, Team task
   board, activity/dependencies, and read-only Project file and Git diff
   inspection.
5. Use foreground SSE and best-effort background refresh. Do not claim
   guaranteed real-time alerts while the app is suspended or terminated until
   an APNs relay architecture receives a separate ADR.

Exit criteria:

- Mobile clients never launch provider or Runtime processes and never accept
  arbitrary server filesystem paths.
- Every destructive control requires confirmation and displays the target
  Server, Project, Session, Team, or task.
- iPhone compact width and iPad split view/keyboard workflows pass UI tests.

### Phase 5: Distribution

1. Distribute macOS first as a Developer ID signed, hardened, notarized DMG.
   Keep it outside the Mac App Store because it launches provider CLIs and
   operates user-selected development directories.
2. Begin with manual signed updates. Introduce an updater only through a future
   dependency and update-security ADR.
3. Distribute iPhone and iPad through TestFlight, then the App Store after
   privacy disclosures, account/token deletion, notification behavior, and
   background limitations are verified.

## Required engineering gates

Every phase must include:

- Swift unit tests for reducers, projections, request encoding, decoding, and
  security policy.
- Rust-to-Swift contract fixtures for every API shape used by a client.
- Integration tests against a temporary authenticated Runtime for SSE and PTY
  WebSocket behavior.
- XCUITest coverage for the phase's primary workflow on macOS and, once
  introduced, one compact iPhone and one regular-width iPad configuration.
- Accessibility labels, keyboard navigation, Dynamic Type where applicable,
  copyable diagnostics, and complete localization validation.
- A dirty-worktree check confirming generated builds do not modify tracked
  source files.

## Explicit non-goals

- Do not embed the React application in Apple clients.
- Do not bundle or own provider credentials or provider-native history.
- Do not introduce client-only Agent behavior or normalize provider-native
  modes, configuration, commands, and permissions into fake common values.
- Do not add Slurm resources or credentials to the client. Agents continue to
  operate Slurm through SSH configuration, native commands, and skills.
- Do not add guaranteed terminated-app mobile push notifications without a
  separate decision for the required APNs service boundary.
