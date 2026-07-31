# ADR 0033: Stable bounded transcript disclosures

## Status

Accepted

This decision refines ADR 0017's nested-disclosure behavior and ADR 0019's
Working presentation. Their native collection ownership, fixed run output,
collapsed defaults, selection, and user-controlled follow-tail decisions remain
in force.

## Context

Expanded Working activity previously projected every Thinking and Tool step as
a separate collection item. Nested state was retained by the window Session,
but the collection projection did not have one stable details identity. Long
Tool output could grow without a bound and place its own collapse control
outside the visible transcript viewport. A nested scroll view also needs an
explicit rule for handing an unconsumed wheel gesture back to the transcript.

## Decision

- Working keeps an independent header row. When expanded, all of its visible
  details occupy exactly one collection row named `<activity-id>-details`, where
  the activity ID is derived from the server run ID.
- Each Thinking and Tool child is identified by its server `TranscriptItem.id`
  plus a kind guard. Array offsets and parent-only identities are prohibited.
  Prefix insertion and reordering therefore cannot retarget disclosure state.
- `SessionWorkspaceModel` retains nested expansion choices independently of the
  Working header choice. Collapsing Working removes its details presentation,
  but does not discard nested intent.
- Working details use a native internally scrolling viewport capped at 320
  points. Tool output uses a selectable, noneditable TextKit view measured at
  its exact proposed width and capped at 220 points.
- Tool header and collapse chrome remain outside the Tool output viewport.
  Collapsing a Tool releases its TextKit content and the corresponding outer
  space while preserving the header.
- A nested bounded scroll consumes a wheel event while it can move in the
  requested direction. At a boundary it forwards that event exactly once to
  the nearest parent scroll view.
- Collapsed Thinking and every non-Markdown disclosure row remain synchronously
  measurable. This decision adds no collection transaction serialization or
  sidebar-width coalescing.

## Consequences

Working and Tool content remain inspectable without allowing long activity to
hide disclosure controls or monopolize transcript geometry. Selection and copy
operate on the exact Tool output string. The stable outer and nested identities
form the presentation boundary that later atomic geometry work can version,
without introducing that transaction machinery here.
