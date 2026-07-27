# ADR 0019: Fixed run output and collapsed Working

## Status

Accepted

Supersedes ADR 0016's decisions that active Activity is expanded by default and
that intermediate Agent text is an Activity step. It refines ADR 0018's stable
row projection. Their provider-history, batching, native layout ownership,
selection, and user-controlled follow-tail decisions remain in force.

## Context

A run can alternate thinking, tools, and Agent updates many times. Presenting
every Agent update as an expanded Activity child hides current progress when the
Activity is collapsed and changes the collection structure whenever a provider
starts another text message. Long active Markdown also causes avoidable parsing
and row-height work.

## Decision

- Each run projects one collapsed Working disclosure for thinking and tools and
  one optional output row with the stable ID `run-{runID}-output`.
- The latest Agent message replaces the active Update in that fixed row. Older
  updates remain in provider events and reducer state but are not separate
  presentation rows.
- Active Update is selectable plain text limited to 220 characters and three
  visual lines. Successful completion upgrades the same row to the complete
  Markdown and LaTeX response. Failed, cancelled, timed-out, and interrupted
  runs upgrade it to complete Partial output and retain their status rows.
- The order is Working header, output, expanded thinking/tool details, then
  error or status. Working, Worked, and Stopped all default collapsed; an
  explicit user disclosure choice still wins.
- Stable collection IDs are structurally diffed. Inserted and deleted detail
  rows use one nonanimated batch update; a full reload is reserved for true
  reordering or duplicate IDs.

## Consequences

Current progress remains visible without exposing reasoning or tool details by
default. Streaming updates reload at most one bounded output row, terminal
rendering remains exact and selectable, and expanding Working does not move or
hide the output. No Runtime API, persistence, or provider-history migration is
required.
