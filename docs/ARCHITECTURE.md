# Client Architecture

## Runtime API boundary

`KubecodeKit.RuntimeClient` is the typed boundary between Apple clients and
the browser-compatible Runtime API. `KubecodeCore.ServerSession` is the
actor-facing facade used by view models; application views do not construct
HTTP requests directly.

The resource contract includes the session and Team workflows needed by the
macOS workstation:

- create a Team member at `POST /sessions/{conversation_id}/team-members`;
- list conversation runs at `GET /sessions/{conversation_id}/runs`;
- read a run at `GET /runs/{run_id}`;
- read incremental run events at `GET /runs/{run_id}/events?after=`;
- read incremental session events at
  `GET /sessions/{conversation_id}/events?after=`.

These methods preserve the Runtime's server authority and decode the existing
`Conversation`, `AgentRun`, `AgentEvent`, and `SessionEvent` models. Event
cursor ownership and reconciliation remain in `ServerSession`; adding a
client method must not introduce provider-specific behavior or a second local
history store.

Team mutations return a complete Team snapshot. The macOS window model applies
that snapshot to both the Team projection and its member Conversation
projections immediately, replacing removed member Sessions while preserving the
Navigator order of unrelated Sessions. Workspace events remain the eventual
consistency fallback for changes made outside the current window.

## macOS window shell

Each workspace window creates one onboarding `NavigationSplitView` and retains
that native shell for the window lifetime. Project hydration replaces only the
existing sidebar/detail content and sidebar toolbar state. The shell's
`NSSplitView`, `NSToolbar`, system sidebar toggle, and width contract remain
stable. Window-scoped Navigator filter state lives in
`ContentView` and is passed into the sidebar projection.

Workspace sidebar children must not install titlebar accessory controllers,
draw titlebar-safe-area chrome, or create a second split shell. AppKit owns
traffic-light avoidance, native toolbar placement, and sidebar collapse.
The leading column is one seamless stack: Sessions, the current Session Plan,
Changes, Files, and the fixed Runtime footer. Its lower content receives an
explicit bounded height and cannot overflow into the Session list.

## Live presentation boundary

`RuntimeClient` parses SSE framing away from the main actor. An actor-isolated
dispatch bridge combines adjacent text and thinking deltas, flushes semantic
events immediately, and publishes one transcript batch every 33 to 50
milliseconds. `KubecodeMacUI` owns one persistent AppKit collection
viewport, virtualization, explicit row frames, width reflow, and scrolling.
Native TextKit views own selection, Markdown, code, and math drawing, but expose
no intrinsic row size and never invalidate a collection item during document
application. Scroll following is window presentation state: only real user
navigation disables it, and neither pixel offsets nor cursor state are written
to `AppModel` or the Runtime.

The complete floating composer is measured as the transcript's bottom
obstruction. Maximum scroll origin, near-tail distance, and anchor clamping use
one obstruction-aware geometry model, so the final visible row always clears
the composer while user-controlled scroll positions remain stable.

`TranscriptReducer` preserves stable provider message and tool identities.
`TranscriptPresentation` groups each run into one run presentation: user
message, collapsed Working activity, one fixed output, and explicit failure
rows. Working contains only thinking and tools. The latest active Agent text
refreshes the stable `run-{runID}-output` row with the complete provider source,
without trimming, normalization, a character cap, or a line preview. Update,
final, and partial phases all use one `AgentMarkdownView` and expose the exact
source to Copy Response. Older updates remain in reducer and provider history
but do not accumulate as presentation rows. The macOS projection gives every
visible row an independent stable collection identity and keeps output directly
below Working even when details expand. This layer is shared by streaming,
restored history, pagination, and revision snapshots; it does not rewrite or
persist provider events.

`KubecodeMarkdown` owns the UI-independent CommonMark/GFM AST and the code-aware
LaTeX scanner. A row-scoped prepared-render session accepts complete source
snapshots for every phase, coalesces pending work, rejects stale generations,
and parses plus reconciles `StreamingMarkdownDocument` snapshots off the main
actor. `AgentMarkdownRenderCommit` preparation, including attributed AppKit
artifacts, mutable session publication, `NSTextStorage` application, and
measurement consumption remain MainActor-bound. Stable Markdown block identity
lets the native selectable TextKit view retain a proven prefix and replace only
its changed suffix. CommonMark blocks, GFM tables/task lists,
syntax-highlighted fenced code, and SwiftMath attachments share that document.
Raw HTML remains visible literal source and is never executed.

Run-output content revision is based only on the stable output ID and exact
visible source. Phase and provider source metadata do not change visible or copy
content, so an identical-source update-to-final handoff produces no collection
reload and retains the native view, text storage, render session, content
version, and prepared commit. Every non-output entry retains its existing
complete-entry revision. A changed source still changes output revision and may
recreate the collection host; persistent host reconfiguration across different
streaming snapshots remains the explicit scope of Issue #7.

Each native message coordinator applies prepared render commits keyed by source,
typography, tone, and Project resource identity. `sizeThatFits` consumes only a
matching prepared commit and never synchronously parses Markdown.
Credential-free HTTPS images use the bounded ephemeral image loader; validated
relative image paths use `RuntimeClient.readAsset` with the current Project ID.
The current collection still caches scalar row heights independently from
asynchronously prepared and attachment-settled render commits. Making visible
content and height one authoritative versioned commit remains the explicit
scope of Issue #6; this layer does not claim authoritative height, attachment
settlement height, follow-tail stability, anchor stability, or atomic geometry.
Read-only Agent output disables spelling correction, text replacement, and
smart punctuation.
Stable insertions, deletions, and row reloads use one nonanimated collection
batch. Transactions that combine structural and content changes, plus true
reordering, use a full reload to avoid mixing old and new index paths. Collection completion
is the only point for anchor restoration or tail following, and streaming never
forces document-wide synchronous layout.
Rendering acceptance interleaves sidebar resize, live scroll, and streaming
growth rather than testing those operations sequentially.

Each scene creates one `WindowWorkspaceModel`. It owns an independent
`AppModel` plus stable Navigation, Session, Project, Team, Terminal, and window
presentation boundaries. The Session boundary owns high-frequency composer,
transcript-follow, and autosave state, so these updates do not recreate the
window shell. Windows share only application-scoped connection management and
the corresponding `ServerSession` transport/projections.

## Terminal ownership

The Runtime owns PTY processes, output replay cursors, and execution-path
validation. The Apple client owns only bottom-workbench layout and connection
recovery. New regular terminals omit a Session ID and therefore use the current
Project root. Agent TUI terminals carry the selected Session ID and use that
Session's validated execution path. Split and restart preserve this distinction.
WebSocket attachment keeps the profile's generic base path and bearer token;
clients never send an arbitrary cwd.

Closing a Terminal intentionally tears down its WebSocket while SwiftTerm may
still have an in-flight input or resize operation. POSIX `ENOTCONN` and the
equivalent URL-session cancellation/network-loss wrappers are shutdown signals,
not workspace errors: the recovery controller suppresses them after stop or
from a stale connection instead of promoting them to the global error banner.
Unexpected active-connection write errors remain reportable.

The local managed Runtime receives a deterministic PATH plus
`KUBECODE_DISABLE_LOGIN_SHELL_DISCOVERY=1`. Catalog lookup therefore cannot
spawn user login shells during App startup or refresh. Agent TUI launch remains
separate and continues to use the user's interactive login shell after the
executable has been discovered.
