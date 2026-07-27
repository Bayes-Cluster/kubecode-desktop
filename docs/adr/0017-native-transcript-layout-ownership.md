# ADR 0017: Native transcript layout ownership

## Status

Accepted

## Context

The first macOS transcript used a SwiftUI `ScrollView` and `LazyVStack` whose
rows embedded AppKit TextKit views. A sidebar collapse continuously changed the
detail width while live scrolling created and recycled rows. Each newly applied
TextKit document invalidated its intrinsic content size during the same SwiftUI
graph update. SwiftUI and AppKit therefore both owned row height and could keep
invalidating each other without a new Agent event. The main thread remained in
AttributeGraph and lazy-layout measurement, making the window unresponsive.

This failure crossed otherwise valid feature boundaries: sidebar animation,
streaming projection, Markdown rendering, selection, and scroll following. A
local debounce cannot make two layout authorities safe.

## Decision

Create the macOS-only `KubecodeMacUI` target. It owns transcript viewport
virtualization, row frames, scrolling, follow-tail behavior, width reflow, and
bounded layout caches. It imports shared transcript presentation from
`KubecodeUI` but has no Runtime, transport, Project, or credential access.

The Session transcript uses one persistent `NSScrollView` and
`NSCollectionView`. Stable item descriptors contain an ID and semantic content
revision. Existing SwiftUI row presentation may be hosted inside a collection
item, but a hosted row cannot change its collection item frame. The collection
layout is the only row-height authority. TextKit views return a pure
`sizeThatFits` measurement and expose no intrinsic width or height; applying an
attributed document must never call `invalidateIntrinsicContentSize`.

Width changes are coalesced to at most one layout commit per display frame and
receive one exact settlement pass after 80 milliseconds without another width
change. A one-second layout budget stops feedback after 120 commits and retries
from the last stable layout after 100 milliseconds. Height cache keys include
stable item ID, semantic content revision, and rounded width, and the cache is
bounded to 4,096 scalar entries.

The collection preserves the first visible stable item and its viewport offset
when history is prepended or width changes. Programmatic document growth follows
the tail only while the viewport is near the bottom. Only native live scroll,
pointer drag, or keyboard navigation changes that semantic state; pixel offsets
are never published into `AppModel` or the Runtime.

Each window owns one `WindowWorkspaceModel`. Its stable
`SessionWorkspaceModel` owns composer presentation, transcript follow state,
and autosave scheduling. Windows share `MacConnectionManager` and its
`ServerSession` instances, but never share selection or Session presentation.

This ADR supersedes ADR 0010's intrinsic-size ownership and ADR 0013's delayed
SwiftUI scroll-to-bottom implementation. Their Markdown, TextKit selection,
streaming, and terminal decisions remain in force.

It refines ADR 0016's nested disclosure behavior. Individual thinking and tool
details are always collapsed until the user expands them, including inside an
active or failed Activity. The Activity container retains ADR 0016's state
default so current Agent updates and failure context remain visible. Thinking
and tool summary labels, progress, and status continue to update while their
detail is collapsed. This prevents a restored or streaming Session from
constructing detailed reasoning Markdown and tool output the user has not asked
to inspect.

## Consequences

Sidebar animation, streaming updates, and user scrolling can occur together
without rebuilding the root window graph or recursively invalidating row size.
The layout boundary is independently testable and reusable without moving
macOS-only AppKit code into the mobile client.

Tests must interleave width changes, live scroll notifications, and streamed
content growth. They also cover bounded content-aware heights, one commit per
frame, tail following, manual-scroll preservation, and independent per-window
Session state.
