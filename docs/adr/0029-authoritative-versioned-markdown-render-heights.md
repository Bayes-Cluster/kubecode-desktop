# ADR 0029: Authoritative versioned Markdown render heights

## Status

Accepted

## Context

The streaming Markdown pipeline publishes immutable prepared attributed
content, but visible and hidden transcript hosts previously owned independent
render sessions and coordinator-local height caches. Hidden `NSHostingView`
measurement could therefore run before its own prepared commit existed, while
the visible `NSTextView` and collection height advanced on different versions.
The height cache omitted typography, appearance, Project resources, and image
settlement, and used `NSAttributedString.boundingRect` instead of the TextKit
layout configuration used by the selectable view.

## Decision

Each transcript row resolves a session-scoped, MainActor
`AgentMarkdownRenderStore`. The store owns one mutable render session, its
accepted `AgentMarkdownRenderCommit`, exact per-width height commits, and one
coalesced attachment batch. Visible and hidden hosts use the same stable row ID
and the same prepared commit. Standalone Markdown views use a local store.

`AgentMarkdownRenderKey` contains content version, monotonic render publication
version, normalized typography, explicit appearance style revision, tone,
Project resource identity and resource generation, attachment resolution
generation, and an effective width rounded to the collection cache's rule.
Identity is typed equality over these fields, never a process-random hash.

Every accepted render request, including a same-snapshot style or resource
refresh, receives an independent monotonic request token. Preparation and
publication both require the exact latest token, so an older job cannot publish
merely because it shares snapshot generation and content version. Immutable
render commits retain their style revision and resource identity/generation.
Stable attributed prefixes may be reused only when those values, typography,
and tone all match exactly; appearance or resource invalidation fully prepares
the affected artifact.

The concrete style lifecycle input is SwiftUI's color scheme. The row store
advances its style revision when that appearance identity changes. Project
resource generations are store-owned: activating a different Project/server
resource identity selects its generation, and the explicit
`invalidateMarkdownResources(identity:)` lifecycle API advances a known
same-identity refresh. Disconnect clears the store. Attachment resolution has
its own generation and is never used as a resource-generation substitute.

An immutable `AgentMarkdownRenderHeightCommit` retains the identical render
commit applied to visible `NSTextStorage`, the exact key, detached TextKit
`usedRect`, and the resolved height. Detached measurement uses
`NSTextStorage`, `NSLayoutManager` with font leading, and an
`NSTextContainer` with zero line-fragment padding, the exact rounded width,
the native vertical inset, and the existing minimum height. `sizeThatFits` may
perform this layout synchronously only for an accepted attributed commit; it
never parses or renders Markdown.

Image loads are coalesced by the row store. A completion must still match the
row's commit publication and resource identity/generation. One batch that
changes attributed content publishes one newer attachment and render
publication. Duplicate host requests, duplicate completions, failures, no-op
results, and stale completions publish nothing.

KubecodeMacUI receives only scalar render-height keys and values. The row
callback captures item ID and content revision. The collection accepts only a
current item and current rounded width. At the same width the publication tuple
must be strictly newer; at a newly current width the same tuple may be accepted,
but an older tuple is always rejected. Acceptance evicts only that row's cached
height and invalidates layout without replacing the host.

## Consequences

Visible Markdown and measured height now share content and publication
identity. Identical-source update-to-final transitions remain phase-neutral and
reuse their content and height versions. Width, typography, appearance, tone,
resource, and attachment changes cannot hit a stale height entry.

This decision does not serialize collection transactions or change persistent
host reconfiguration, pending insets, follow-tail, viewport anchoring, resize
policy, scrolling, or layout completion. Those remain Issue #7.
