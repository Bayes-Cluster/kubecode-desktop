# ADR 0035: Latest-only transcript width settlement

## Status

Accepted

This decision extends ADR 0030's serialized transcript geometry and ADR 0034's
atomic disclosure transactions. ADR 0032's stable Markdown row sessions, ADR
0033's bounded disclosures, and the existing Composer measurement boundary
remain in force.

## Context

Sidebar and window animation can report several intermediate transcript widths
before AppKit reaches its final viewport. Preparing and committing every width
causes repeated collection mutations, invalid FlowLayout frames during shrink,
and obsolete Markdown height work. A delayed unversioned second layout pass can
also commit after a newer width or session has become authoritative.

## Decision

- Normalize each observed effective collection width to an integral point.
  An exact consecutive duplicate is inert; every other observation, including
  an A-to-B-to-A sequence, receives a monotonically increasing generation.
- Retain at most one active width generation and one replaceable latest target.
  The settlement delay authorizes only the exact latest target; canceled or
  stale callbacks have no collection, row, height, viewport, or intent effects.
- Width does not create a second collection serializer. Its generation is part
  of the existing geometry target, item sizes, render-height provenance, and
  completion snapshot, alongside session, rows, disclosure state, and intent.
- Stage the collection frame and bounds at a width that safely contains both
  old and target FlowLayout item widths. Materialize the target layout before
  settling the document width and restoring follow-tail or the captured anchor.
- A width-only transaction reconfigures existing row hosts and measures the
  stable prepared Markdown commit at the new width. It does not parse or render
  Markdown again, replace the semantic row session, or replace TextKit storage.
- Session, content, layout, disclosure, render-publication, width, or
  width-generation mismatches are strict no-ops. User intent remains owned by
  the existing synchronous transcript scroll and disclosure models.

## Consequences

Resize bursts converge on one final collection mutation without exposing an
invalid FlowLayout width. Markdown and disclosure identities remain stable,
follow-tail and non-tail anchors use the same atomic completion path, and stale
width work cannot release or mutate the active geometry transaction.
