# ADR 0027: Stable streaming Markdown documents

## Status

Accepted

This decision supersedes only ADR 0020's parser-model assumption that active
streaming output has no render-ready Markdown document. ADR 0020 remains
authoritative for the CommonMark/GFM feature set, math and resource policy,
native selection, and current transcript presentation until the dependent
renderer and transcript changes land.

## Context

The transcript receives complete, growing provider source snapshots. The
existing parser already produces deterministic structural paths, but path
identity alone does not prove that a block is unchanged: the same path can
change from literal text to emphasis, a table, math, or fenced code when a
delimiter closes. Parser implementation details can also change descendant
paths without changing rendered meaning, as happens when math placeholders
split inline content.

Later native rendering work needs an immutable document that distinguishes a
semantically unchanged prefix from a mutable suffix. It must retain readable
source while the last construct is unsafe to render, without introducing a
token-level parser or moving layout ownership into SwiftUI.

## Decision

`KubecodeMarkdown` owns a `StreamingMarkdownDocument` above the existing parser.
Each update parses the complete source snapshot, then projects deterministic,
unique render blocks with source ranges and either parsed content or exact
literal source.

Reconciliation is allowed only when the new source is a strict append of the
previous source. It reuses the longest leading sequence whose deterministic
block paths match and whose render semantics are deeply equal. Semantic
comparison ignores AST identity and source-range bookkeeping while retaining
block kind, text traits, code, links, images, lists, tables, math, and raw HTML.
Any non-append edit has no stable prefix.

The remaining blocks form the mutable tail. Closing emphasis, table, math, or
fence syntax may change that tail's semantic type without disturbing the
prefix. An unmatched top-level fenced-code suffix is retained as an exact
literal substring, including its original Unicode and line endings, until a
valid closing fence arrives. Other malformed input continues to use the
existing parser's visible literal fallback.

The model is immutable, `Sendable`, provider-independent, and UI-independent.
It uses no randomized hashing for identity and does not add a dependency on
Microsoft SwiftStreamingMarkdown.

## Consequences

Downstream scheduling and TextKit rendering can operate on complete snapshots
while preserving completed prefix blocks and replacing only a changing suffix.
They must still add generation guards, backpressure, persistent native view
state, versioned measurement, and atomic collection geometry before active
transcript output can switch from its current bounded plain presentation.

This decision does not change `Transcript.swift`, SwiftUI/AppKit rendering,
height measurement, scrolling, provider event projection, or the current
streaming/final user interface.
