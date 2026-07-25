# ADR 0004: macOS workstation parity

## Status

Accepted

## Context

macOS is the only Apple platform that can reasonably own local provider
processes, development directories, full PTYs, and an editing workflow. A
reduced companion interface would force users back to the browser and defeat
the purpose of a native desktop application.

The browser application remains the product baseline, but its React component
tree and visual composition are not a platform contract. The native client
needs the same user-visible capabilities, resource semantics, and safety
properties while using standard macOS navigation, commands, controls, windows,
menus, sheets, inspectors, text input, accessibility, and keyboard behavior.

## Decision

The macOS app is the complete Kubecode workstation. Release parity means every
supported browser workflow has either a native implementation or an explicit
exception in `docs/MACOS_BROWSER_PARITY.md`. It supports:

- local-managed, SSH-managed, and HTTPS-attached Server profiles;
- complete Project registration and workspace migration;
- Session creation, provider-native import/resume, lifecycle, revisions,
  interactive Agent events, and native mode/configuration controls;
- multi-document file editing and full Project-scoped Git operations;
- Runtime-owned terminal profiles with groups and split layouts;
- complete Team setup, monitoring, attention, task, member, permission,
  verification, and lifecycle controls;
- settings, Agent diagnostics, native notifications, logs, and copyable errors.

The workstation shell uses a native two-column `NavigationSplitView`:

- one leading Navigator combines Server, Project, Session, and Team hierarchy;
- the detail column contains the active transcript, editor, diff, or Team board
  beside a compact, user-toggleable Explorer Inspector;
- a resizable terminal area below the content using native split views.

High-frequency workspace actions are exposed through native macOS commands as
well as their in-window controls. New Team shares the AppModel presentation
state with the toolbar and empty-state action, while `Command-J` and the View
menu toggle the bottom Terminal panel. The onboarding `NavigationSplitView` is
the permanent window shell. Its sidebar-owned native toolbar shows Add Project
during startup, then replaces only that toolbar content with Sort/Filter and
Quick Open after Project hydration. The system sidebar toggle remains the final
control. The custom View commands own search, Terminal, and Inspector state.
Commands and controls use the same capability predicates, so unavailable
Project or Agent state disables both surfaces consistently.

Opening one workbench resource must not close or recreate unrelated Runtime
resources. A terminal is server-owned until explicitly closed. Editor tabs,
terminal groups, split ratios, expansion state, and per-Session drafts are
window presentation state and restore independently for each window. Session
drafts survive selection changes for the lifetime of the window. Relaunch
restoration is an explicit, off-by-default privacy preference because drafts
contain prompt text.

Each application window owns a `WindowWorkspaceModel` containing selection,
navigation path, open documents, terminal layout, inspector visibility, and drafts.
Windows connected to the same profile share one `ServerSession`; they do not
share selection. `ServerSession` owns the authenticated transport,
reconnecting event stream, event cursor, and server-scoped projections. Its
workspace-event stream is a native Swift concurrency multicast: concurrent
first subscribers coalesce cursor initialization, every window receives the
same ordered events from one upstream SSE connection, and removing a window
removes only its local subscription.

### Project and Session parity

Local Project registration uses `NSOpenPanel`; the client stores only an opaque
security-scoped bookmark keyed by Project ID and restores access before
launching a managed Runtime. Existing local Projects can be reauthorized by
selecting their root again, which the Runtime verifies without returning the
registered absolute path. SSH-managed and HTTPS-attached Servers continue to
use the Runtime directory browser because their filesystem is remote.
Unregistering releases the bookmark and never deletes the directory.
Workspace-mode changes use migration preview and explicit merge,
`export_patch`, or discard resolution. Session support includes new shared and
worktree Sessions, provider-native import/resume, bounded history pagination,
archive, fork, branch, revisions, edit/regenerate/undo, and checkpoint restore.

Global navigation uses the native sidebar search field; `Command-K` presents
it without a custom command palette. Its bounded index spans registered
Projects, Solo Sessions, and Teams, and every result opens the owning Project
before selecting the resource. A native attention menu and Project, Session,
and Team badges aggregate durable input-required state. Summary-changing
workspace events refresh the catalog across Projects; streaming text,
thinking, tool, usage, and Plan events do not trigger global reloads.

Project Quick Open uses the native searchable sheet and always exposes a
separate bottom action bar with Cancel plus a default Open action, so the
search toolbar cannot hide the only exit. Results render in a native
single-selection List; the first result is selected automatically, Up/Down
changes selection while the search field remains active, and Return opens the
selection. Escape or Cancel closes an untouched sheet, cancels any in-flight
search, and clears stale results. A sheet-window-scoped AppKit key monitor routes
these standard commands without intercepting modified shortcuts or events from
another window; choosing a file remains the only path that opens a document.

Within a Project, the native Session list groups roots by attention, running,
today, previous seven days, older, and archived state. Branch, fork, and
subagent relationships use system disclosure rows; restoring or selecting a
child reveals its ancestor path. Agent, ordering, archived visibility, and
disclosure preferences are window-scoped presentation state. Archive and
other lifecycle commands remain Runtime mutations exposed by native sidebar
context menus and the active Session titlebar menu. Clearing a manual title
restores the Agent title. Teammate and discriminator Sessions cannot be deleted
directly; deleting a Team leader removes the Team's Session projections
together while preserving Project files and provider-native history.

Turn mutation uses the Runtime's immutable revision contract. Edit,
Regenerate, and Undo keep the logical Session ID stable, snapshot the previous
timeline, and rehydrate the current provider continuation. A native revision
navigator exposes older snapshots as read-only timelines. Explicit Branch uses
a native sheet because it creates a visible Session and lets the user choose
whether to restore the pre-turn Project checkpoint; unsafe or unavailable
restores remain Runtime decisions and are surfaced as selectable warnings.

Transcript projection coalesces streaming text and thinking by stable provider
message ID. Tool lifecycle, Plan, Usage, provider notices, permission requests,
elicitations, and errors remain structured items. Provider-native modes,
configuration, and slash commands are capability-driven. The client does not
invent common provider modes or commands. The searchable capability palette is
a native single-selection List: file reference and provider command rows retain
direct mouse activation, while Up/Down moves the selection, Return invokes it,
and Escape dismisses the popover. A shared window-scoped AppKit command bridge
provides the same unmodified-key behavior to Quick Open without intercepting
other windows or modified shortcuts.

User messages, Agent text, and thinking use one native structured renderer for
Foundation Markdown presentation intents and CoreText LaTeX math. Each
uninterrupted sequence of adjacent provider messages is coalesced into one
TextKit selection domain, preserving message boundaries with paragraph spacing,
so a normal drag and the system Copy command
can cross rendered paragraphs, lists, code, and math attachments. Code spans
and fences remain literal, incomplete streaming delimiters remain visible, and
no transcript content is rendered through HTML or a WebView. Agent responses
add Copy Response to the native text context menu so the complete provider
Markdown remains available without a detached transcript button; ordinary
selection Copy retains the rendered selection. ADR 0010 owns the parser,
TextKit projection, and math typesetter boundary.

Primary window actions use standard icon-only SwiftUI `Button` values inside
the native toolbar. Their SF Symbols share one bounded point size and layout
frame so glyphs with different optical bounds remain aligned; the native
toolbar still owns the control chrome, spacing, hover behavior, and Liquid
Glass composition.

The active run uses its ordered SSE channel for token-level text, thinking,
and tool updates. An interrupted channel reconnects from the last accepted
sequence with bounded exponential backoff, ignores replayed sequence numbers,
and resets the retry budget whenever forward progress is observed. After the
retry budget is exhausted, the client releases direct-stream ownership so the
durable workspace event stream remains the fallback rather than suppressing
updates indefinitely. Long provider turns merge adjacent text or thinking
message IDs into one selectable native row, keep tool boundaries in timeline
order, and grow vertically without creating a row per chunk.

### Explorer, editor, Git, and terminal parity

The Explorer provides Changes, Plan, and Files sections, lazy directory
loading, hidden/ignored/generated filtering, and bounded quick open. The editor
is multi-document, revision-aware, supports create/rename/delete, dirty-close
confirmation, search/replace, line numbers, syntax presentation, and optional
one-second autosave. ADR 0009 owns the editor dependency.

Closing a workstation window reviews every dirty editor tab in tab order with
native document-style Save, Don't Save, and Cancel sheets. Save waits for the
Runtime revision-aware write before advancing; a conflict, failed save, or
Cancel keeps the window and remaining drafts open. The close bridge forwards
the existing SwiftUI window delegate instead of replacing its unrelated
lifecycle behavior.

The Files section uses a window-scoped native tree. Expanding a directory is
the only action that loads its children; refresh preserves valid expansion and
removes stale subtrees after rename or deletion. The Changes section separates
index and worktree state, including showing the same path in both sections when
both states exist. Destructive discard always requires native confirmation.
Changes, Agent Plan, and Files share one native Explorer stack with
independently collapsible sections. Changes and Plan have bounded native lists;
Files owns the remaining height so every section header stays reachable. A
lost local security-scoped bookmark is one Inspector-level authorization
state with one native Restore Folder Access action; Changes and Files do not
duplicate the warning or misreport unavailable data as repository state. The
native recovery surface uses `ViewThatFits`: it remains one row in a wide
Inspector and stacks its Label and Button when the split view is narrow, so
the action is never truncated out of the interface. One AppModel file-access
capability drives Quick Open, Save, autosave, Explorer refresh/create, file
and Git mutations, and dirty-close saves. Losing authorization disables native
commands before invocation; dirty drafts and pending close state remain intact
until access is restored. Plan
entries are projected from the provider-native session state, including the
protocol's supported wrapper shapes; a new Plan revision reveals its section
without resetting the user's other section choices.

Git support is limited to the Runtime's current Project-scoped contract: init,
status, diff, stage, unstage, discard with confirmation, and commit. The client
does not execute Git directly.

Terminal support includes regular and Agent TUI profiles, Session working
directories, groups, reorder, recursive horizontal/vertical splits, persisted
ratios, rename, restart, close, exited status, cursor replay, and reconnect.
Terminal and Agent TUI panes live in the resizable lower workbench and never
replace the active transcript or editor. Terminal output is not persisted by
the client. The persistent lower disclosure bar is the only visible Terminal
entry point; creation, Agent TUI, split, group, and collapse controls live in
the expanded lower workbench rather than the window toolbar or Inspector.
Each split pane header uses separate native Buttons for selection and close;
the selection surface owns the remaining header width, publishes the current
selected accessibility trait, and never turns a close command into an implicit
selection. Workbench icon commands use the system borderless control style
instead of gesture-only rows or custom hover simulation.
Reconnect uses bounded automatic retries, then exposes a copyable
pane-local failure with an explicit native retry action instead of leaving the
workbench in an indefinite loading state.
The reconnect loop resumes from the last server cursor, resets SwiftTerm before
feeding a truncated ring-buffer snapshot, and resets its retry budget only when
an output cursor advances or a terminal status arrives. Connections that open
and close without progress therefore reach the retryable failure state instead
of looping forever.

Files and Git are optional Project projections, not prerequisites for opening
Sessions, Teams, or the terminal workbench. They load in cancellable background
tasks because macOS protected-folder authorization and remote filesystems may
delay directory access. Development builds use a stable signing identity when
available; ad-hoc rebuilds can invalidate Files & Folders and Screen Recording
grants because their code hash changes.

### Team and settings parity

Team support includes draft creation and Session promotion, Standard and YOLO
setup, leader-native options, member allowlists and limits, task dependencies,
attempts, results, verification, activity, proposals, user input, permissions,
attention, member Session navigation, assignment, retry, cancellation, member
removal, pause, resume, completion, disband, and deletion confirmations.
Runtime-reported provider mode fallback remains a visible selectable warning.
Discriminator verification rounds retain their status, verdict, and evidence in
the native Team list, and member-owned attention rows navigate directly to the
owning read-only member Session. A lineup proposal preserves the bounded
Runtime-supplied member list and displays candidate names before the Leader can
approve or reject it; malformed proposal metadata cannot hide the decision
controls or invalidate the Team snapshot.
When a Team enters `needs_attention`, the header exposes a compact native
Reconfigure command. It reopens the same provider-native setup form with the
current goal, criteria, mode, allowlist, and budgets, then uses the Runtime's
existing start transition to restart the Team; other live states do not expose
this recovery path.

Team creation is deliberately two-phase. The first native form creates a draft
Team or promotes an existing Session; only the returned Leader Session identity
may then be used to fetch provider-native mode and configuration capabilities.
The second form projects those capabilities into system pickers and toggles and
applies each change through the generic Session option routes before starting
the Team. The client neither guesses provider models nor copies option IDs from
another Session. Closing the second form preserves an actionable draft that can
be reopened from the Team workspace.

Settings include Server profiles, appearance, editor, terminal, notification
focus/category/sound policy, Agent refresh and diagnostics, logs, and copyable
diagnostic reports. Secrets remain in Keychain. Client persistence excludes
prompt/transcript content, file names/content, provider credentials, and
terminal output by default. The user may explicitly enable local per-window
Session draft restoration; disabling it purges persisted drafts immediately.

Managed Runtime diagnostics are stored under the user's standard Library Logs
directory, with one bounded file for the local Runtime and one file per Server
profile. Local Runtime stderr, SSH Runtime and tunnel stderr, and client-owned
connection/protocol lifecycle events share this profile boundary. The native
Diagnostics settings view reads only a bounded tail and provides explicit copy
and Finder reveal actions. Attached HTTPS profiles expose client connection
diagnostics only; the app does not claim access to remote service logs. Client
manager messages redact URLs and credential-shaped values before persistence.

System notifications originate only from durable workspace events. One shared
application coordinator deduplicates each Server event across windows, applies
Always, When Unfocused, or Off plus per-category enablement and sound, and
replaces stable Session/category notifications. Permission and elicitation
resolution removes delivered attention notifications. Streaming text,
thinking, tool deltas, prompt text, and file content never enter a notification.

Appearance preferences use native installed-font pickers rather than accepting
CSS font stacks. UI size uses the browser contract's 12–20 point range and one
window environment projects the selected family and relative native text
styles into SwiftUI content, the AppKit composer, Markdown, and math. Editor
code and terminal fonts remain independent monospaced preferences because
those surfaces have different readability and glyph-coverage requirements.

Static SwiftUI copy is localized in English and Simplified Chinese. Dynamic
provider values, Project data, status payloads, counts, and slash-command names
use verbatim native text rather than becoming accidental localization keys.
The localization gate builds the app with compiler string emission enabled and
requires the emitted key set to exactly match both catalogs, including format
placeholder signatures; source scanning alone is not an adequate parity gate.
The standalone assembler also installs each catalog in the main app bundle's
standard localization directory. Leaving catalogs only inside SwiftPM's
nested resource bundle does not satisfy runtime localization for default
SwiftUI controls.

Use SwiftUI and native system controls for application structure. AppKit bridges
are reserved for mature desktop behaviors such as the code editor, terminal,
and composer. Native parity takes precedence over copying browser layout or
CSS. macOS 26 uses Liquid Glass through system materials and controls; macOS 14
uses native material fallbacks without custom imitation effects.

Adjacent Navigator actions use standard icon-only SwiftUI controls inside one
native sidebar toolbar group. Sort/Filter and Quick Open share a 30-point hit
frame and precede the system `NavigationSplitView` sidebar toggle. The native
window toolbar keeps its background transparent so the system owns Liquid
Glass composition, traffic-light avoidance, baseline, hover chrome, and
placement. No AppKit titlebar accessory or manually extended titlebar material
is installed.
Compact transcript, editor-tab, Explorer, Git, revision-warning, and error
commands follow the same rule with native borderless Buttons. Selection rows may
remain plain to preserve a full-row hit target, but command icons must carry a
localized `Label` rather than exposing an SF Symbol name as their accessible
name.

Icon-only workspace controls expose stable AX identifiers and localized human
labels rather than relying on SF Symbol names. Native menu, Navigator, editor,
and workspace shortcuts share one conflict-checked catalog. Release acceptance
runs that contract on macOS 26, followed by macOS 26 VoiceOver and Full
Keyboard Access traversal of the primary workstation flows. macOS 14 remains a
deployment target but is outside this release QA scope.

The app may launch only the bundled Runtime and adapters. Claude Code, Codex,
and OpenCode CLIs remain user-installed. Authentication and provider history
remain provider-owned.

macOS owns Slurm only indirectly: an Agent may use the user's SSH configuration
and Slurm commands. No Slurm queue, job, credential, or scheduler model is added
to the native app.

## Consequences

macOS has a larger implementation and test surface than mobile, but it can
replace the browser for normal local and remote coding. App Store sandboxing is
not an objective for the macOS target; distribution policy is defined in ADR
0008.

Accepting this ADR records the workstation-scope decision; it does not assert
that a particular release artifact is ready for distribution. Release
readiness remains governed by the parity matrix, the clean-machine bundle gate
in ADR 0008, and the macOS 26 acceptance workflow.
