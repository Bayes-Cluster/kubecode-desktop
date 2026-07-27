# ADR 0022: Composer-aware transcript layout

## Status

Accepted

Refines ADR 0017 through ADR 0019 for floating-composer clearance, terminal row
promotion, and native collection updates.

## Context

The composer floats over the transcript. Clearance was estimated from the text
field rather than measured from the complete overlay, while scroll-to-bottom,
near-tail detection, and anchor clamping ignored that clearance. A terminal run
could also delete an Activity row and reload a shifted output row at the same
index path, which AppKit rejects. Final Markdown was initially measured as plain
text and could outgrow its collection frame after rich rendering.

## Decision

- The complete composer overlay is measured as one obstruction, including
  prompts, Undo, controls, and padding. The transcript content inset and jump
  control use that one measurement.
- `TranscriptScrollGeometry` is the sole calculation for maximum origin,
  distance from tail, and anchor clamping, and always includes the obstruction.
- Active Update remains bounded plain text. Non-streaming Markdown is measured
  with its final attributed representation before the collection caches the row
  height and exposes rich content.
- Pure content changes, insertions, and deletions remain targeted. A transaction
  containing both structural and content changes uses one nonanimated full
  reload so old and new index spaces cannot delete and reload the same path.
- Follow-tail or anchor restoration runs after the collection layout completion,
  never from a parallel SwiftUI scroll task.

## Consequences

Working updates and final output remain above the floating composer without a
manual scroll refresh. Completion cannot trigger an AppKit batch exception, and
users who scroll away retain their stable visible row and offset.

