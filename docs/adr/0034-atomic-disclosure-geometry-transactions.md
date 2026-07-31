# ADR 0034: Atomic disclosure geometry transactions

## Status

Accepted

This decision extends ADR 0017's native transcript layout ownership and ADR
0033's stable bounded disclosure identities. Their selection, bounded scrolling,
and semantic identity rules remain in force.

## Context

Disclosure intent originates in SwiftUI while collection items, measured row
heights, and viewport restoration are committed by AppKit. Applying a new
chevron or child presentation immediately, then inserting or resizing its row
in a later collection update, exposes an inconsistent intermediate frame.
Streaming can also supersede a disclosure change while an older measurement or
animation is still in flight.

## Decision

- `SessionWorkspaceModel` owns the latest user intent. Visible disclosure
  chrome and children read the last presentation committed by the transcript
  collection transaction.
- Every disclosure presentation carries a stable semantic disclosure ID, its
  exact owning collection item ID, a layout revision, and expanded state.
- A geometry target snapshots session identity, ordered collection items,
  effective width, disclosure presentations, and measured row heights.
  Completion provenance must exactly match that snapshot before it can commit.
- The transaction serializes disclosure chrome, child insertion or removal,
  bounded content height, collection projection, and viewport restoration.
  At most one transaction is active and only the latest pending target is kept.
- A disclosure change invalidates its exact owner row. Nested Thinking and Tool
  changes inside Working therefore invalidate only `<activity-id>-details`.
- Disclosure transactions preserve the changed header's viewport position
  within one point, including while follow-tail would otherwise move the
  viewport. Streaming-only transactions retain the existing follow-tail policy.
- Stale session, item, width, height, or disclosure-generation completions are
  rejected without releasing the active transaction. A new session discards
  an old-session active transaction before applying any of its presentation.

## Consequences

Users never observe disclosure chrome and transcript geometry from different
generations. Rapid toggles and concurrent streaming converge on the latest
intent without overlapping collection mutations. The additional snapshot and
measurement work is bounded by the existing active-plus-latest transaction
queue and exact owner invalidation.
