# macOS Accessibility and Keyboard Acceptance

Run this named release acceptance on the current macOS 26 release. A run is
complete only when the automated gate and the macOS 26 assistive-technology
checklist both pass. macOS 14 remains a deployment target but is outside the
release acceptance matrix.

## Automated gate

```bash
scripts/test-apple-accessibility-keyboard.sh
```

The gate accepts only macOS 26. It verifies the exact native
shortcut mappings, rejects shortcut conflicts, and checks that every critical
icon-only workspace action has a stable AX identifier and a localized label.
The contract currently covers 36 actions across the Navigator tool strip,
Navigator, composer, revisions, transcript follow/copy, Session actions and
usage, Team recovery, editor, Terminal, Explorer/Git, and global error actions. Adding or
removing an action requires an explicit acceptance-test update rather than
silently changing the traversal surface.
The normal Apple test suite separately renders the Navigator, composer,
transcript, Team setup, Explorer, editor, and Terminal workbench.
Navigator toolbar actions use standard icon-only native controls in the
permanent onboarding `NSToolbar`. Project state replaces only the toolbar
content with a uniform Sort/Filter and Quick Open group; the system
`NavigationSplitView` toggle remains the final control. Compact row commands use
localized icon-only Labels with native borderless Buttons; plain Buttons are
reserved for selection rows whose full width is the intended hit target.

## VoiceOver

1. Enable VoiceOver and open a Project, Session, editor document, and Terminal.
2. Navigate the Navigator project switcher, filters, search, Session rows, Team
   rows, and Server switcher without using the pointer.
   Use the system Navigator collapse control and confirm the Navigator
   column collapses and restores without changing the selected Project or
   Session. There must be exactly one sidebar toggle and no titlebar accessory.
3. Navigate transcript messages, thinking, tools, Usage, permission choices,
   elicitation fields, composer context, provider-native controls, and Send or
   Stop Run. Open Add Context and confirm Reference File and every provider slash
   command expose their full names and descriptions. Confirm streamed updates do
   not steal the VoiceOver cursor.
4. Navigate editor tabs, Find and Replace, Save, Explorer sections and file
   actions, Git actions, Terminal creation/splits/groups, and the collapse bar.
   Use the system Navigator collapse control in the window toolbar to hide
   and restore the Navigator, and confirm its localized action name is
   announced. Explorer sections remain independently collapsible inside the
   Navigator; there is no separate middle-toolbar or right-side Inspector
   control.
   Confirm editor Close Document, Git stage/unstage/discard/commit, Explorer
   refresh/visibility, and global error copy/dismiss announce command names
   rather than SF Symbol identifiers.
   In a split Terminal group, confirm each pane title is announced as a Button,
   the active pane announces selected, and Close Terminal is a separate Button.
5. Open a draft Team and confirm Leader mode/configuration controls, budgets,
   and Start Team have useful names, values, and enabled states. Open a Team in
   needs-attention state and confirm the slider command announces Reconfigure
   Team and the recovery sheet announces Restart Team.
6. Confirm selectable errors, notices, logs, transcript text, and diagnostics
   remain readable and copyable.

## Full Keyboard Access

1. Enable Full Keyboard Access and traverse every control above with Tab and
   Shift-Tab. Focus order must follow visual order and never enter a trap.
2. Activate buttons, menus, segmented controls, pickers, toggles, disclosure
   groups, lists, sheets, alerts, and destructive confirmations with standard
   system keys.
   In Add Context, confirm Up/Down moves the native selection, Return activates
   the selected file reference or slash command, and Escape closes the popover.
   For split Terminal pane headers, Return must select without closing; the
   adjacent Close Terminal Button must close without first changing selection.
3. Verify these shortcuts in the running app:

| Action | Shortcut |
| --- | --- |
| Add Project | Shift-Command-O |
| New Session | Command-N |
| Quick Open | Command-P |
| Save | Command-S |
| Refresh Workspace | Shift-Command-R |
| Search Sessions | Command-K |
| Find | Command-F |
| Find and Replace | Option-Command-F |
| Show/Hide Terminal Panel | Command-J |
| Show/Hide Inspector | Option-Command-0 |

4. Open Quick Open with Command-P. Type a query and confirm the first result is
   selected, Up/Down moves the native List selection, and Return opens the
   selected file. Reopen it with an empty search field and confirm Escape closes
   the sheet immediately.

   Verify that `Search Sessions` is also present in the native View menu and
   focuses the same persistent sidebar search field; no separate search button
   should be present beside the field.

5. In a Session, send short, medium, and long prompts. Confirm the right-aligned
   user bubbles grow with their content, stop at the readable maximum, and wrap
   long lines without forcing the transcript wider.

## Evidence

Record one row per run. Do not mark the parity matrix Complete until the macOS
26 row includes automated and assistive-technology results.

| macOS | Architecture | App build | Automated | VoiceOver | Full Keyboard Access | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 26.6 | arm64 (Universal app) | ad-hoc `dist/apple/Kubecode.app`, 2026-07-25 09:56 +0800 | Pass, 2026-07-25 | Pending | Pending | Automated contract passed on the same OS release; assistive-technology traversal remains required. |
