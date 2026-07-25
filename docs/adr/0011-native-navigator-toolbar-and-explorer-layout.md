# ADR 0011: Native Navigator toolbar and Explorer layout

## Status

Accepted

## Context

The macOS workstation uses the leading `NavigationSplitView` column for the
Project and Session Navigator. The Navigator also owns the Project Explorer
and the Local Runtime footer. A content-level row containing sort, search, and
collapse buttons duplicated the persistent search field and placed the primary
navigation controls away from the macOS window controls.

The Explorer must remain useful at narrow sidebar widths. Collapsing a section
should reclaim space at the bottom of the Navigator, while expanding it should
grow its native content upward without pushing the Local Runtime footer out of
the column.

## Decision

The Navigator follows these native macOS rules:

- `WorkspaceNavigationSidebar` owns one persistent SwiftUI `.searchable` field
  with the localized `Search Sessions` prompt.
- Search has no adjacent magnifying-glass button. `Command-K` and the View-menu
  `Search Sessions` command focus the same field.
- Sort/filter, Navigator collapse, Refresh Workspace, and Quick Open are one
  native safe-area tool strip owned by `WorkspaceNavigationSidebar`. The strip
  is inside the leading Navigator, below the titlebar and above the search
  field; none of these controls is emitted into the middle detail toolbar.
- The Explorer is a native `VSplitView` child inside the leading Navigator,
  above the Local Runtime footer. It is not a duplicate right-side Inspector.
- Changes, Agent Plan, and Files use independently collapsible native section
  headers. Each section's expanded list is placed above its header so its
  content grows upward; Files receives the remaining dynamic height.
- The root workspace toolbar emits no duplicate Navigator controls. No second
  search button or system sidebar toggle is introduced by the window toolbar.

## Consequences

The sidebar has one stable visual hierarchy: the native Navigator tool strip is
at the top, the persistent search field is directly below, and Project/Session
content follows. The same layout works with mouse, VoiceOver, and Full Keyboard
Access because controls use native menu, searchable, safe-area, and split-view
semantics.

The layout contract is covered by
`navigator_toolbar_controls_share_one_native_hit_frame` and
`files_list_owns_the_remaining_inspector_height`. Any future change to toolbar
placement, search presentation, or Explorer ownership must update this ADR,
the parity matrix, and the macOS accessibility checklist together.
