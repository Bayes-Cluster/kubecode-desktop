# ADR 0012: Full-size native Navigator chrome

## Status

Accepted

Supersedes the presentation details in ADR 0011.

## Context

SwiftUI can promote `.searchable` and sidebar commands into the window toolbar.
That behavior put Navigator controls in the detail area, separated the controls
from the traffic lights, and allowed titlebar recomposition to look like a
whole-window reload. The Local Runtime row also participated in the Explorer
split, so expanding folders could push it out of view.

## Decision

- The workspace window uses a hidden, transparent, full-size native titlebar.
- The leading Navigator owns an explicit native `NSSearchField`. It appears
  below the top control strip and is focused by `Command-K`.
- Sort/filter, Navigator collapse, Refresh Workspace, and Quick Open remain
  inside the Navigator. Their native hit targets are all 30 by 30 points, use
  one symbol size and layout frame, and share the traffic-light horizontal band.
- The control strip is 32 points high, matching the hidden native titlebar's
  traffic-light center. It has no material band, bezel, capsule, or persistent
  gray button background; all icon controls use the plain native button style.
- The detail toolbar contains no mirrored Navigator controls or floating pill.
- Changes, Agent Plan, and Files remain bottom-anchored expandable sections.
  Their content grows upward, and the Files list scrolls within the available
  dynamic height instead of enlarging the Navigator.
- Local Runtime is a fixed 30-point footer outside the Explorer `VSplitView`.
- Window geometry and accessibility identifiers are acceptance contracts, so
  the layout can be verified in a real `NSWindow` without capturing unrelated
  screen content.

## Consequences

The traffic lights, Navigator tools, and search field form one stable native
hierarchy. Expanding or collapsing the Navigator changes only split-view
geometry; it does not rebuild the detail surface. Explorer growth cannot remove
the Local Runtime footer or create a second collapse control.

`navigator_toolbar_controls_share_one_native_hit_frame`,
`files_list_owns_the_remaining_inspector_height`, and
`workspace_window_uses_a_full_size_transparent_native_titlebar` cover the
contract.
