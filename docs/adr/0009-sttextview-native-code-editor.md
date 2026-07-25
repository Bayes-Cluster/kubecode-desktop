# ADR 0009: STTextView native code editor

## Status

Proposed

## Context

The macOS workstation requires a multi-document editor with line numbers,
selection stability, scrolling stability, undo, search and replace,
multi-cursor editing, and TextKit-native input behavior. SwiftUI's `TextEditor`
does not provide this code-editor surface, while maintaining a custom
`NSTextView` editor would duplicate substantial TextKit 2 behavior.

The editor remains a client presentation component. File access, revision
checks, and writes stay behind the Runtime API.

## Decision

Use STTextView 2.3.10 from
`https://github.com/krzyzanowskim/STTextView` as the native editor foundation.
Vendor the exact release source and its STTextKitPlus 0.2.0 and CoreTextSwift
0.2 dependencies under `apps/apple/Vendor` so standalone and offline builds do
not require SwiftPM Git mirrors. Use path packages from the root manifest and
keep the AppKit/TextKit 2 integration behind a Kubecode-owned `CodeEditorView`
boundary.

Kubecode owns document identity, dirty state, autosave timing, conflict
handling, syntax selection, quick open, tabs, and Project-relative paths.
STTextView owns text layout, editing, selection, undo integration, line-number
presentation, search/replace, and multi-cursor mechanics.

The dependency must never receive an absolute server path. The app passes a
Project-relative display name and document content only. Replacing STTextView
must not change Runtime models or `ServerSession` commands.

## Consequences

The editor gets mature native behavior without embedding a web editor. The app
gains two transitive Swift dependencies and must validate them in release
supply-chain checks and third-party notices.

The current minimum macOS target of 14 is compatible with the selected release.
Upgrading STTextView requires normal dependency review and editor regression
tests for scrolling, selection, IME input, undo, large files, and autosave.

The source archive SHA-256 values used for this decision are:

- STTextView 2.3.10: `f24074a11c5b1c9171500bd664a590ace7924ea6f973fb4a6af6bd4532745263`;
- STTextKitPlus 0.2.0: `9d47a254041e2f1cf41768a27e520119b74b62bdce522f1abc135274036b6428`;
- CoreTextSwift 0.2: `41f6870c02e87743ad594521d8d14048ddcc6057655cb7f39a9b7fdf3d6c9ef9`.
