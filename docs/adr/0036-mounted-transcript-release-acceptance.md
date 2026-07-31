# ADR 0036: Mounted transcript release acceptance

## Status

Accepted

This decision is the release acceptance for the Composer and transcript work in
ADRs 0032 through 0035. It does not replace their ownership, identity, bounds,
transaction, or width-settlement decisions.

## Context

Focused component tests can pass while a mounted AppKit workflow still combines
streaming, selection, nested scrolling, disclosure, width, attachment, and
window lifecycle in an unsafe order. Release acceptance therefore needs one
deterministic contract for interaction intent, failure fallback, bounded work,
memory, accessibility, and teardown across those existing components.

## Decision

- A mounted native mouse drag or nonempty Markdown selection is user navigation.
  Its stable row/session provenance and per-host interaction identity enter the
  existing collection coordinator. The first active interaction synchronously
  advances the existing user-intent revision and suspends follow-tail. The last
  interaction to end re-evaluates the real viewport; only the existing near-tail
  policy may resume following. There is no second scroll or geometry authority.
- Compatible suffix commits preserve selection wholly inside the immutable
  stable prefix. A selection intersecting the replaced mutable tail clamps to
  the new tail boundary. Host recreation preserves the row render session and
  prepared commit; stale host callbacks are inert.
- A Markdown builder result that does not match its requested source is a failed
  build. Inside the same off-main scheduled operation, the session constructs a
  source-preserving streaming document from the last valid document and exact
  requested source. Valid stable blocks are reused and an unsafe mutable tail is
  rendered literally. Missing attachments retain alt or source text. A newer
  generation recovers through the normal publication path.
- Reduce Motion removes the remaining nonessential Explorer disclosure and
  Composer provider animations. It does not change state, chevron rotation,
  measured width, disclosure bounds, row height, or geometry provenance.
- Release automation composes the existing deterministic seams for Composer
  width/focus/selection/marked text; Markdown semantic sessions, exact no-op,
  selection, failure, bounded row/width caches, and teardown; Working and Tool
  bounds, selectable TextKit, and one-hop wheel forwarding; atomic disclosure
  geometry; and latest-only width settlement. Every asynchronous stage retains
  at most one active job and one replaceable latest job. Stale callbacks have no
  visible, scheduling, counter, height, viewport, or intent effects.
- Project, Session, row, and host teardown synchronously cancel or release their
  scoped work. No provider behavior, server path, WebView, global mutable cache,
  synchronous MainActor parse, or unversioned delayed callback is introduced.
- VoiceOver, Full Keyboard Access, and Reduce Motion traversal that automation
  cannot establish remains a named macOS 26 manual release checklist. Automated
  success does not mark pending manual evidence complete.

## Consequences

The final release gate tests the components under the concurrency and lifecycle
conditions users create rather than treating each feature as an isolated pass.
Selection and drag cannot be mistaken for follow-tail consent, malformed output
remains readable, and motion preferences do not perturb geometry. The runtime
and provider boundaries remain unchanged.
