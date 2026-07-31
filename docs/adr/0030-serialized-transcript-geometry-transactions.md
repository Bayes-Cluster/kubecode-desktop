# ADR 0030: Serialized transcript geometry transactions

## Status

Accepted

## Context

Versioned Markdown render heights couple visible attributed content to exact
TextKit measurement, but a scalar height publication previously invalidated the
collection layout directly. Item reloads, hidden measurement, bottom-inset
changes, width settlement, and attachment settlement could therefore overlap.
Collection completions carried no generation and could restore an older anchor
or tail after newer geometry or user navigation had arrived.

Reloading a changed item also replaced its `NSHostingView`, even though the
row-scoped Markdown render session was already persistent. A width change always
captured an anchor, including for a user following the tail, and `reloadData`
used an arbitrary task yield as a layout completion.

## Decision

`KubecodeMacUI` owns one MainActor transcript geometry driver backed by a pure,
Sendable transaction reducer. The reducer retains one committed target, at most
one in-flight transaction, and one replaceable latest pending intent. Intent and
transaction generations are independent and monotonic. A completion must match
the exact in-flight transaction generation; a stale completion has no viewport
effect and cannot release newer work.

Each intent is a complete value containing unique stable item IDs, semantic and
layout revisions, exact per-item sizes, rounded effective width, composer bottom
inset, and one viewport intent revision. Plans compare stable IDs. A target with
duplicate IDs is rejected before it consumes a generation or replaces pending
valid work, because the size table is keyed by stable ID. Safe insertions and
deletions use one collection batch. Reorder and unsafe mixed structural/content
changes use a generation-guarded full reload. The latest valid full intent
replaces older pending work; stale index sets are never merged.

Rich Agent output requires an exact accepted Issue #6 render-height publication
for its item revision and width. Other rows use deterministic hidden hosting
measurement. The complete target size table is ready before any visible
mutation. Item data, row builder, sizes, inset, and width become committed
together, and layout delegates perform only committed size lookup. A newer
render or attachment height settles through the same serializer instead of
invalidating layout directly.

A width mutation first stages a collection frame that is valid for both the
previous and target item widths, including AppKit's vertical-scroller clearance.
It then exposes the target size table and materializes its FlowLayout attributes
before settling the final target frame. Expansion and shrink therefore never
validate either cached or current item attributes against a narrower frame.

Render-height callbacks keep the Markdown renderer's inner proposal width in
the Issue #6 publication identity, while separately carrying the collection's
outer row width and session identity. The collection validates row ID, content
revision, outer width, and session provenance before accepting a callback. A
valid capped or user-bubble Markdown width therefore cannot deadlock a wider
row, and a callback from an older width or session cannot satisfy the current
target. Every row that currently mounts `AgentMarkdownView` uses versioned
height authority; a collapsed thinking disclosure remains synchronously
measurable until its Markdown content is actually mounted.

Surviving visible items reconfigure their existing hosting view. Source changes
therefore retain the native text view, text storage, selection boundary, and
row-owned render session. Collection items clip drawing to their committed frame
while newer geometry is pending.

Viewport policy is part of the transaction. A tail follower captures no anchor
and moves to the exact obstruction-aware maximum origin only after the matching
layout completion. A scrolled-away user captures the first visible stable item
and offset. If that item is deleted, restoration chooses the next surviving item
in prior order, then the preceding survivor. Real user navigation increments a
separate intent revision, preventing an old completion from moving the viewport.
An identical-source update-to-final handoff changes no geometry and creates no
transaction.

Preparation, mutation, and completion phases are injectable for deterministic
tests. Production preparation coalesces through the MainActor. Collection batch
completion or a forced synchronous reload layout is the completion authority;
an arbitrary task yield is not.

## Consequences

Streaming source growth, width changes, composer inset changes, and one matching
attachment settlement cannot overlap collection geometry commits. Tail users
remain at the true maximum origin, while scrolled-away users retain a stable
anchor within one point. Source-only changes no longer replace persistent hosts.

Issue #6 remains the sole authority for render commits, attachment attribution,
and exact TextKit height versions. This decision does not change attachment
transport, selection/copy/link behavior, accessibility or focus, typography or
theme UX, or other interaction hardening; those remain Issue #8.
