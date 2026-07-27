# ADR 0016: Run-level Agent activity presentation

## Status

Accepted

Supersedes the top-level transcript grouping presentation in ADR 0004 and ADR
0013. Their Runtime ownership, streaming, stable provider identity, selection,
and follow-tail decisions remain in force.

## Context

Provider runs may alternate thinking, tool calls, and intermediate text many
times before producing a final answer. Rendering each kind as a peer transcript
row preserves chronology but lets process detail dominate the conversation and
produces a long sequence of repeated disclosures.

## Decision

- `TranscriptReducer` continues to project provider events into stable
  `TranscriptItem` values. A separate pure presentation projection groups those
  items by run without changing or persisting provider data.
- Each run presents its user message, at most one Activity disclosure, a final
  answer when one exists, and explicit error or non-success status rows.
- During an active run, thinking, tools, and Agent text are chronological
  Activity steps. After successful completion, only the last Agent text becomes
  the final answer. Failed, cancelled, timed-out, and interrupted output remains
  partial Activity content rather than being promoted to a conclusion.
- Activity identity and child identities remain stable across streaming and
  completion. Active Activity is expanded by default, successful Activity is
  collapsed, and failed Activity is expanded. A user expansion choice overrides
  automatic defaults.
- An expanded Activity initially shows the latest eight steps and offers access
  to all earlier steps. Thinking, intermediate Markdown, tool input/output, and
  their original order remain available and selectable.
- The Activity summary reports stable step and tool counts. It does not infer a
  duration from event timestamps because the Runtime does not expose an
  authoritative run start/end interval.

## Consequences

Long runs remain observable while active and compact after completion. Final
answers regain visual priority without discarding provider history. The same
projection applies to live streams, restored history, pagination, and immutable
revision snapshots, and requires no Runtime or persistence migration.
