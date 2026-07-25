# ADR 0013: Live transcript and Terminal workbench

## Status

Accepted

## Context

The Runtime already emits incremental text, thinking, and tool events, but a
client that parses or drains those events on the main actor can present them in
large batches. Programmatic document growth can also be mistaken for user
scrolling. Terminal creation has a separate context problem: a regular shell
belongs to the selected Project root, while an Agent TUI may intentionally use
the selected Session execution path.

## Decision

- SSE bytes are parsed off the main actor. Each accepted event is projected on
  the main actor and yields before another buffered event is applied.
- Provider message IDs continue to coalesce deltas into stable text, thinking,
  and tool rows; streaming must not create a row per chunk.
- Transcript follow-tail reacts to live document growth only while the viewport
  is near the bottom. Only live scroll, pointer drag, or keyboard navigation may
  disable following; a delayed second scroll accounts for native TextKit layout.
- Agent and thinking output use one native selectable TextKit document with the
  existing Markdown, code-block, and LaTeX pipeline, preserving cross-line Copy.
- Terminal and Agent TUI views live only in the resizable bottom workbench.
- A regular Terminal omits the Session ID and therefore starts at the
  server-validated Project root. Agent TUI kinds retain the selected Session ID
  and start at its server-validated execution path. Split and restart normalize
  the context with the same rule.
- Terminal attachment requests preserve the configured base path, bearer token,
  encoded Project and Terminal IDs, and replay cursor when switching to WebSocket.
- The macOS-owned Runtime receives
  `KUBECODE_DISABLE_LOGIN_SHELL_DISCOVERY=1`. Agent catalog discovery therefore
  uses the deterministic native PATH and known install locations without
  executing user login files. This does not alter Agent TUI login-shell launch.

## Consequences

Long turns visibly advance without taking scroll control from a reader. Output
remains selectable and structurally stable. Shells no longer unexpectedly open
inside a Session worktree, while Agent TUIs retain the context required for the
active coding Session and the user's interactive login-shell environment.

Focused coverage includes `long_streams_keep_stable_thinking_answer_and_tool_rows`,
`transcript_follows_streaming_output_without_overriding_user_scroll`, native
Markdown selection tests, `TerminalRecoveryIntegrationTests`,
`regular_terminals_use_the_project_root_while_agent_tuis_follow_the_session`, and
`terminal_attachment_preserves_authentication_base_path_and_cursor`.
