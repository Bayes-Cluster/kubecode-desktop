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

## Live presentation boundary

`RuntimeClient` parses SSE framing away from the main actor. `AppModel` applies
each accepted delta to the observable transcript on the main actor and yields
between buffered events. Native TextKit views own selection, Markdown, code,
math layout, and intrinsic-size invalidation. Scroll following is presentation
state: only real user navigation disables it, and no cursor state is written to
the Runtime.

Each native message view caches its parsed Markdown and rendered attributed
document in its `NSViewRepresentable` coordinator. Viewport changes and SwiftUI
layout passes must reuse that document; only a changed source, typography, or
tone may rebuild or reapply it. Apply decisions use that Kubecode-owned input
version, never a deep comparison with `NSTextView`'s attributed content because
TextKit may add internal attributes after assignment. Read-only Agent output
also disables spelling correction, text replacement, and smart punctuation.
TextKit measurement synchronizes the proposed width only
when the width actually changes and caches the resulting height. It must not
mutate the native frame on every measurement, because that creates a
scroll-layout feedback loop for long restored Sessions. Rendering acceptance
therefore covers cache reuse, no-op viewport updates, and non-overlapping native
message frames.

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
