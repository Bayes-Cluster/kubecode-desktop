import SwiftUI
import Testing
@testable import KubecodeApp

@Suite("macOS Accessibility and Keyboard Acceptance", .serialized)
@MainActor
struct MacOSAccessibilityKeyboardAcceptanceTests {
    @Test func critical_workspace_shortcuts_are_stable_and_non_conflicting() {
        #expect(WorkspaceKeyboardShortcuts.addProject == shortcut("o", [.command, .shift]))
        #expect(WorkspaceKeyboardShortcuts.newSession == shortcut("n", [.command]))
        #expect(WorkspaceKeyboardShortcuts.quickOpen == shortcut("p", [.command]))
        #expect(WorkspaceKeyboardShortcuts.save == shortcut("s", [.command]))
        #expect(WorkspaceKeyboardShortcuts.refresh == shortcut("r", [.command, .shift]))
        #expect(WorkspaceKeyboardShortcuts.searchSessions == shortcut("k", [.command]))
        #expect(WorkspaceKeyboardShortcuts.find == shortcut("f", [.command]))
        #expect(WorkspaceKeyboardShortcuts.findAndReplace == shortcut("f", [.command, .option]))
        #expect(WorkspaceKeyboardShortcuts.terminalPanel == shortcut("j", [.command]))
        #expect(WorkspaceKeyboardShortcuts.inspector == shortcut("0", [.command, .option]))
        #expect(Set(WorkspaceKeyboardShortcuts.all).count == WorkspaceKeyboardShortcuts.all.count)
    }

    @Test func critical_workspace_controls_publish_stable_accessibility_contracts() {
        let expected: Set<WorkspaceAccessibilityAction> = [
            .refreshWorkspace,
            .quickOpen,
            .newTeam,
            .showNavigator,
            .hideNavigator,
            .searchSessions,
            .newSession,
            .filterSessions,
            .projectActions,
            .addContext,
            .send,
            .stopRun,
            .findAndReplace,
            .save,
            .newTerminal,
            .splitRight,
            .splitDown,
            .moveGroupLeft,
            .moveGroupRight,
            .showTerminal,
            .hideTerminal,
            .showInspector,
            .hideInspector,
            .refreshFiles,
            .fileVisibility,
            .newFileOrFolder,
            .previousRevision,
            .nextRevision,
            .scrollLatestOutput,
            .sessionActions,
            .copyResponse,
            .contextUsage,
            .refreshChanges,
            .commitChanges,
            .toggleHiddenFiles,
            .copyError,
            .dismissError,
            .teamReconfigure,
        ]
        let actions = WorkspaceAccessibilityAction.allCases

        #expect(Set(actions) == expected)
        #expect(Set(actions.map(\.rawValue)).count == actions.count)
        for action in actions {
            let label = String(localized: action.label)
            #expect(!label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(label != action.rawValue)
        }
    }

    private func shortcut(
        _ key: Character,
        _ modifiers: EventModifiers
    ) -> WorkspaceKeyboardShortcut {
        WorkspaceKeyboardShortcut(key: key, modifiers: modifiers)
    }

}
