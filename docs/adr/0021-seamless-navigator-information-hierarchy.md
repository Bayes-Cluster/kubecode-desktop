# ADR 0021: Seamless Navigator information hierarchy

## Status

Accepted

Supersedes ADR 0011 and ADR 0012 where they require an Explorer `VSplitView`
or place Agent Plan between Changes and Files. ADR 0015 remains authoritative
for the permanent window shell.

## Context

The internal vertical split made Sessions and Project tools look like unrelated
sidebars. Its draggable divider was visually noisy, and expanded Plan, Git, and
file content could overflow a compressed Explorer frame and overlap Sessions.

## Decision

- The onboarding `NavigationSplitView` remains the only split view owned by the
  window.
- The leading column is one continuous hierarchy: Project and Sessions, current
  Session Agent Plan, Changes, Files, then the fixed Local Runtime footer.
- The lower region has an explicit height derived from visible 30-point headers
  and bounded expanded content. It is clamped so Sessions retain at least 260
  points and Runtime retains its fixed height.
- Plan and Changes shrink and scroll before Files loses its 120-point minimum.
  Section content is clipped to its assigned region and cannot overflow into
  Sessions or Runtime.
- Section headers have no persistent bar background or visible divider. Local
  disclosure animation must not animate the window shell or detail column.

## Consequences

There is no hidden draggable boundary or duplicate Inspector. Collapsing a
section gives space back to Sessions, deep file trees remain locally scrollable,
and Project hydration continues to preserve the root split view and toolbar.

