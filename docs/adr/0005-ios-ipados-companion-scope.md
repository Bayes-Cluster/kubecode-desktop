# ADR 0005: iPhone and iPad companion scope

## Status

Proposed

## Context

iPhone and iPad are useful while Agents and Teams run elsewhere, but they
cannot launch local provider processes or provide the same unrestricted
filesystem and PTY environment as macOS. Treating them as small desktop apps
would create fragile and misleading workflows.

## Decision

Ship one universal mobile application with adaptive iPhone and iPad
presentation. It connects only to an existing HTTPS-attached Runtime.

iPhone v1 supports:

- Server health and reconnect status;
- Project, Session, run, Team, member, task, and attention summaries;
- complete transcript viewing and lightweight prompts;
- permission choices, elicitation forms, Team user-input replies, run cancel,
  and Team pause/resume;
- copyable diagnostics and foreground event notifications.

iPad v1 supports all iPhone controls plus:

- multi-column Session and Team navigation;
- the Team task board, activity, dependencies, and verification views;
- read-only Project file inspection and Git diffs;
- hardware-keyboard navigation and commands.

Mobile v1 does not provide file mutation, Git mutation, terminal input, Runtime
or provider process launch, SSH tunnel management, workspace migration, or
Slurm control. Those controls are hidden rather than shown disabled.

Every command displays its Server and resource scope. Destructive commands
require confirmation. Mobile never receives or displays an unregistered
absolute server path.

## Consequences

The companion remains dependable and reviewable under the iOS sandbox. iPad
gets richer inspection without becoming a compromised IDE. Future file editing
or terminal control requires a separate ADR covering security, background, and
interaction expectations.
