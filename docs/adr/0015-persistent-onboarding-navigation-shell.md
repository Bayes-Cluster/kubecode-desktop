# ADR 0015: Persistent onboarding navigation shell

## Status

Accepted

Supersedes ADR 0014 and the Navigator shell-lifecycle details in ADR 0012.

## Context

The startup and Project workspaces previously constructed different
`NavigationSplitView` and toolbar hierarchies. Loading the first Project
therefore replaced the native split view, removed the onboarding `NSToolbar`,
and installed a custom `NSTitlebarAccessoryViewController`. Besides producing a
visible reload, the two titlebar ownership models placed the traffic lights,
Navigator controls, and sidebar material in different coordinate systems.

## Decision

- The original onboarding `NavigationSplitView` is the only window shell. It is
  created once and remains alive for the lifetime of the workspace window.
- Project hydration changes only the content inside the existing sidebar and
  detail columns. It must not conditionally replace `NavigationSplitView`, its
  `NSSplitView`, or its `NSToolbar`.
- The toolbar modifier belongs to the permanent sidebar column. Startup shows
  Add Project. A loaded Project changes that same toolbar's content to one
  native Sort/Filter and Quick Open group. The system-provided
  `NavigationSplitView` sidebar toggle remains the final control.
- Sort, Agent filter, and archived visibility are window-scoped state owned by
  `ContentView` and passed into `WorkspaceNavigationSidebar`. Sidebar content
  does not install or own window toolbar controllers.
- No `NSTitlebarAccessoryViewController`, manual titlebar-safe-area extension,
  duplicate collapse button, or replacement workspace split shell is allowed.
  AppKit owns traffic-light avoidance, toolbar placement, hover treatment, and
  native sidebar collapse behavior.
- Startup and Project content share the same Navigator width contract and the
  same bottom-anchored `WorkspaceRuntimeFooter`.
- Window-level regression tests require the SwiftUI shell anchor, native
  `NSSplitView`, and `NSToolbar` to retain object identity across Project
  hydration, and require the titlebar accessory controller list to remain
  empty.

## Consequences

Entering a Project no longer reconstructs the window layout or switches
titlebar ownership models. The native onboarding placement remains consistent
while the Navigator can still expose Project-specific controls and content.
Toolbar state must be lifted to the permanent shell rather than implemented by
future sidebar children.
