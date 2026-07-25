# ADR 0014: Native Navigator titlebar placement

## Status

Accepted

Supersedes the titlebar-placement details in ADR 0012.

## Context

ADR 0012 placed the Navigator control strip in the sidebar content and moved it
up by the titlebar height. `NavigationSplitView` still clips its leading column
at the content safe-area boundary, so the strip could pass container geometry
tests while every visible control was clipped out of the real application.

## Decision

- `WorkspaceNavigationSidebar` installs one left-aligned
  `NSTitlebarAccessoryViewController` containing Sort/Filter, Quick Open, and
  Navigator collapse in that order. It does not emit an `NSToolbarItem`;
  Refresh Workspace remains available outside this compact titlebar group.
- The actual `workspaceSidebar` owns the sidebar material and trailing divider.
  Only that background ignores the top safe area, so it extends behind the
  traffic lights and accessory while the sidebar content remains below the
  titlebar. No guessed or synchronized column width is used.
- AppKit positions the left accessory after the standard window controls. The
  accessory adds only 16 points of normal leading spacing; it does not repeat a
  hard-coded traffic-light clearance. Native titlebar placement, rather than a
  negative content offset, keeps the controls inside the Navigator and on the
  traffic lights' vertical centerline.
- All three controls use the same 30-point transparent hit target and 22-point
  symbol layout frame. They have no bezel, material, capsule, or persistent gray
  background; pressed state is communicated only by a temporary opacity change.
- The persistent native search field remains the first row of Navigator content,
  directly below the titlebar controls.
- Startup and Project workspaces share the same 210-point minimum, 250-point
  ideal, and 310-point maximum Navigator width. Entering a Project must not
  replace the column with a wider layout contract.
- Window-level tests inspect the titlebar hierarchy, the three visible symbol
  frames, and separate chrome/column anchors. They require the titlebar chrome
  and actual Navigator column to share a trailing edge, in addition to bounding
  the horizontal gap after the zoom button. A content-only toolbar anchor is not
  sufficient acceptance evidence.

## Consequences

The controls remain owned by the Navigator but are no longer vulnerable to
sidebar safe-area clipping. The detail area receives no duplicate controls, and
the system remains responsible for traffic-light avoidance and titlebar
alignment.
