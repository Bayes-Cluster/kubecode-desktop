# ADR 0018: Batched native transcript streaming

## Status

Accepted

## Context

ADR 0017 made AppKit the transcript height authority, but the first collection
implementation still treated a complete run Activity as one hosted row. Every
provider delta replaced that row, synchronously measured a separate hosting
tree, invalidated the full flow layout, forced AppKit layout, and scheduled a
second scroll-to-bottom operation. Streaming faster than layout settlement left
the outer Activity frame stale and could saturate the main thread.

## Decision

An actor-isolated `AgentEventDispatchBridge` merges adjacent text and thinking
deltas and publishes to `AppModel` at most every 33 milliseconds, adapting to
50 milliseconds under burst pressure. Semantic events flush pending text first.
The direct run stream is authoritative for its active run; duplicate high-rate
workspace events do not enter the main-actor presentation path.

The macOS transcript projects Activity header, thinking, tool, process output,
and final response as independent stable collection rows. Thinking and tool
details remain collapsed by default and do not construct Markdown views until
expanded. A changed row is reloaded through one collection update; no streaming
path calls document-wide `layoutSubtreeIfNeeded` or runs a parallel bottom-scroll
task. Anchor restoration or follow-tail occurs once after that update completes.

Active Markdown uses hybrid rendering. TextKit appends visible text immediately,
rich Markdown refreshes no more than every 100 milliseconds, and final output is
rendered exactly when the run completes. The composer clearance is an
`NSScrollView` content inset rather than collection content that changes every
time the composer is measured.

This ADR supersedes ADR 0017's per-delta main-actor publication, whole-Activity
row, synchronous hosted measurement, and global layout invalidation details.
ADR 0017 remains authoritative for AppKit ownership, stable identity, selection,
bounded caches, and user-controlled follow-tail semantics.

## Consequences

Provider event rate, observable-state publication, rich-text parsing, row
measurement, and scrolling have independent bounded cadences. Tests interleave
streaming, Activity disclosure, sidebar width changes, and live scrolling, and
verify that user selection and tail-follow state survive every update.
