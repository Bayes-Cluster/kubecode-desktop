# ADR 0028: Unified complete active Markdown output

## Status

Accepted

This decision supersedes only ADR 0019's 220-character, three-line active
preview and terminal renderer-upgrade clauses; ADR 0020's streaming plain-text,
no-parse-until-terminal clauses; and ADR 0022's bounded-plain Active Update
clause. Their stable run projection, ordering, parser and resource policy,
native selection, composer obstruction, collection transaction, and scroll
decisions remain in force.

## Context

The prepared streaming Markdown pipeline now accepts complete snapshots,
coalesces pending work, rejects stale generations, and applies stable document
suffixes through one native selectable TextKit renderer. The transcript still
discarded leading and trailing whitespace from active Agent output, limited the
visible source to 220 characters and three lines, and used a separate plain
SwiftUI `Text` branch until the run became terminal.

Complete source parsing and `StreamingMarkdownDocument` reconciliation and
building run off the main actor. `AgentMarkdownRenderCommit` preparation,
including attributed AppKit artifacts, mutable session publication,
`NSTextStorage` application, and measurement consumption are MainActor-bound;
AppKit artifacts do not cross actor boundaries.

That presentation lost provider source while a response was active, withheld
Markdown semantics and Copy Response, and replaced the native rendering host at
an identical-source update-to-final handoff. Phase and provider source metadata
were included in collection content revision even when neither changed visible
or copy content.

## Decision

`TranscriptPresentation` projects the latest Agent item's exact `String` for
update, final, and partial output. It performs no whitespace trimming,
normalization, character limit, or line limit. Stable output and source IDs,
run ordering, terminal phase mapping, and status/error rows are unchanged.

One `TranscriptRunOutputRow` presents every output phase through exactly one
`AgentMarkdownView`, with a common leading layout and the complete exact source
as both render input and Copy Response input. The row has no phase-specific
label, plain-text branch, or `isStreaming` presentation switch.

Run-output presentation identity contains only the stable output ID and exact
visible source. Its collection content revision therefore ignores phase,
source-item ID, and source-message ID. All non-output entries retain their
existing complete-entry hashing. Exact source changes still change revision.

When update and final snapshots have the same source, the collection update
plan is empty. The existing native view, text storage, row-scoped render
session, content version, and immutable prepared commit remain in place without
additional preparation. This phase neutrality applies only to identical source;
a changed streaming snapshot still follows the current collection reload path.

## Consequences

Active output is complete, selectable rich Markdown with the same heading,
emphasis, list, code, link, table, math, and raw-copy behavior as terminal
output. A terminal phase change with identical source is no longer a visual,
renderer, or collection-content change.

This decision is not the final streaming geometry or persistence design.
Source-changing snapshots may still recreate collection hosts instead of
reconfiguring one persistent host; that remains Issue #7. Visible prepared
content, attachment settlement, and cached row height are not yet one
authoritative versioned commit; that remains Issue #6. Follow-tail, anchor
preservation, and atomic geometry are not changed or claimed here.
