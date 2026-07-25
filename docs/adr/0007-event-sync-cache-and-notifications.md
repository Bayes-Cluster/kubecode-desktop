# ADR 0007: Event synchronization, cache, and notifications

## Status

Proposed

## Context

The Runtime is the durable source of truth. Clients still need responsive token
streaming, reconnectable workspace updates, multiple windows, mobile
foreground monitoring, and bounded local state. Refreshing every resource for
each workspace event is slow and can make streaming appear non-incremental.

iOS also cannot keep an arbitrary SSE connection alive indefinitely while
suspended or terminated.

## Decision

Each `ServerSession` performs an initial paged hydration, records the returned
resource revisions and workspace-event cursor, and then consumes one global SSE
stream. Events are reduced into targeted projections:

- text and thinking deltas append to a stable provider message ID;
- tool, permission, elicitation, Plan, Usage, and Session-state events update
  only their Session projection;
- file and Git events invalidate only affected Project projections;
- terminal and Team events update only their resource projections;
- an event gap, incompatible payload, or expired cursor triggers bounded full
  hydration instead of guessing state.

The global SSE stream is owned by the `ServerSession` actor and multicast to
window subscribers using Swift concurrency. Concurrent initial subscribers
share one cursor request and one upstream connection. The actor advances the
cursor before publishing an event, ignores replayed IDs, and reconnects after
clean or failed disconnects from the last accepted ID. Retry delay grows
exponentially from 250 milliseconds and is capped at five seconds; forward
progress resets the delay. Window models consume this shared stream and never
write the cursor themselves.

The event reducer deduplicates by Server identity and event ID. UI publication
coalesces high-frequency deltas into frames while preserving exact text order.
History reconciliation at run completion is authoritative and must not duplicate
already-rendered deltas.

Use SwiftData only for non-secret client metadata: Server profiles, UI layout,
event cursors, and bounded Server, Project, Session, and Team status summaries
that contain none of the prohibited fields below. Do not persist bearer tokens,
prompt bodies, transcript bodies, filenames, file contents, terminal output, or
tool input by default. Those values may exist in memory while a view is active.
Keychain is the only persistent credential store.

macOS maps completion, failure, waiting permission, waiting input, and Team
attention to user-configurable local notifications. Notification bodies omit
prompt content, filenames, file contents, credentials, and tool input.

Mobile uses foreground SSE and best-effort `BGAppRefreshTask` hydration that
may schedule a local notification. It does not promise real-time delivery while
suspended or terminated. Guaranteed background delivery requires an APNs
service boundary and a separate ADR.

## Consequences

Streaming and workspace refresh become efficient and deterministic across
multiple views. Client caches improve navigation without becoming a second
history database or a privacy liability.

Mobile users receive honest best-effort monitoring in v1; guaranteed push is
explicitly deferred instead of relying on unsupported background behavior.
