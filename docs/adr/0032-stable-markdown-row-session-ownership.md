# ADR 0032: Stable Markdown row session ownership

## Status

Accepted

## Context

ADR 0029 established one prepared-render store above visible and hidden native
hosts, but the store keyed sessions only by collection row ID. Row IDs are
stable within a transcript, not across Projects or Sessions, and one row may
contain more than one semantic Markdown segment. The store was also unbounded,
and coordinator-local height publication could repeat for identical input or
alias a reconfigured host with the same version tuple.

`NSViewRepresentable`, collection items, and hidden measurement hosts are
ephemeral presentation objects. None may become parse, render, or session
authority. Their recreation must recover the latest immutable commit without
repeating semantic work.

## Decision

`AgentMarkdownRenderStore` is MainActor-isolated and owned by the window's
Session workspace above the native transcript collection. Each stored session
uses a typed identity containing exact Project resource identity, Session ID,
stable parent transcript row ID, stable server-derived semantic item ID when a
row contains child content, and semantic segment kind. Message, Agent response,
Thinking, activity update, and run-output segments are distinct. Array offsets,
enumeration indexes, AST paths, and parent row IDs alone are not identities.
Repeated same-kind children in one composite row remain distinct by server item
ID while parent-row reconciliation still tears all of them down together.

The store retains at most 512 row sessions in deterministic least-recently-used
order. Each row retains at most eight exact-width height commits. Reusing an
existing identity returns the same render session and latest immutable commit;
offscreen collection reuse and hidden measurement therefore perform no parse
or render. A width-only request lays out that commit and never rebuilds the
Markdown document or attributed content.

An identical semantic submission remains a `StreamingMarkdownSession` no-op.
It does not parse, prepare, apply, or remeasure. A native coordinator publishes
a height callback only when the full row identity or exact height tuple changes,
so an identical update-to-final handoff cannot schedule collection layout.
Newly created hosts may apply the retained commit once because their text
storage is empty; the host still owns no semantic state.

The viewport reconciles the store against stable row IDs. Removing a row
cancels its document, render, and attachment work and releases its session.
Changing Project or Session scope synchronously tears down the previous scope
before accepting the new one. Viewport disappearance and window disconnect
remove the remaining scope or store. Late document, render, attachment, height,
and callback completions require the exact still-present identity and current
generation; work completing after teardown publishes nothing and cannot retain
the removed session.

Prepared block reuse continues to require stable block identity, exact source
range, block kind, and render-semantic equality. Prefix insertion and repeated
siblings therefore cannot reuse attributed blocks merely because their array
positions or parser-local IDs coincide.

## Consequences

Semantic Markdown state survives ephemeral AppKit and SwiftUI host recreation
while remaining isolated by Project, Session, row, and segment. Store and width
memory are bounded, and row, scope, and window teardown have deterministic
cancellation behavior.

This decision does not change Composer sizing, Working or Tool disclosure
presentation, collection width transaction policy, provider behavior, or the
selection, accessibility, attachment, style, and suffix contracts established
by ADRs 0029 through 0031.
