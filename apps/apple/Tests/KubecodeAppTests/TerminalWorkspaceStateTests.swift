import Foundation
import Testing
@testable import KubecodeApp

@Suite
struct TerminalWorkspaceStateTests {
    @Test func regular_terminals_use_the_project_root_while_agent_tuis_follow_the_session() {
        let conversationID = "session-1"

        #expect(TerminalCreationContext.conversationID(
            for: .regular,
            selectedConversationID: conversationID
        ) == nil)
        #expect(TerminalCreationContext.conversationID(
            for: .claudeCode,
            selectedConversationID: conversationID
        ) == conversationID)
        #expect(TerminalCreationContext.conversationID(
            for: .codex,
            selectedConversationID: conversationID
        ) == conversationID)
        #expect(TerminalCreationContext.conversationID(
            for: .openCode,
            selectedConversationID: conversationID
        ) == conversationID)
    }

    @Test func recursive_splits_collapse_when_a_leaf_closes() {
        var workspace = TerminalWorkspaceState.empty
        workspace.addGroup(terminalID: "terminal-1", id: "group-1")

        let firstSplit = workspace.split(
            terminalID: "terminal-1",
            with: "terminal-2",
            axis: .horizontal,
            splitID: "split-1"
        )
        let secondSplit = workspace.split(
            terminalID: "terminal-2",
            with: "terminal-3",
            axis: .vertical,
            splitID: "split-2"
        )
        #expect(firstSplit)
        #expect(secondSplit)
        #expect(workspace.activeTerminalID == "terminal-3")
        #expect(workspace.activeGroup?.layout.terminalIDs == [
            "terminal-1", "terminal-2", "terminal-3",
        ])

        workspace.removeTerminal("terminal-2")

        #expect(workspace.activeGroup?.layout.terminalIDs == ["terminal-1", "terminal-3"])
        #expect(workspace.activeTerminalID == "terminal-3")
    }

    @Test func reconciliation_removes_dead_leaves_and_appends_unassigned_terminals() {
        let stored = TerminalWorkspaceState(
            activeGroupID: "group-1",
            groups: [
                TerminalGroupState(
                    id: "group-1",
                    activeTerminalID: "terminal-dead",
                    layout: .split(TerminalSplitState(
                        id: "split-1",
                        axis: .horizontal,
                        ratio: 0.82,
                        first: .leaf(terminalID: "terminal-live"),
                        second: .leaf(terminalID: "terminal-dead")
                    ))
                ),
            ]
        )

        let restored = stored.reconciled(with: ["terminal-live", "terminal-orphan"])

        #expect(restored.groups.count == 2)
        #expect(restored.groups[0].layout == .leaf(terminalID: "terminal-live"))
        #expect(restored.groups[0].activeTerminalID == "terminal-live")
        #expect(restored.groups[1].layout == .leaf(terminalID: "terminal-orphan"))
        #expect(restored.activeGroupID == "group-1")
    }

    @Test func restart_ratio_and_group_reorder_preserve_layout_identity() {
        var workspace = TerminalWorkspaceState.empty
        workspace.addGroup(terminalID: "terminal-1", id: "group-1")
        let didSplit = workspace.split(
            terminalID: "terminal-1",
            with: "terminal-2",
            axis: .horizontal,
            splitID: "split-1"
        )
        #expect(didSplit)
        workspace.addGroup(terminalID: "terminal-3", id: "group-2")
        workspace.activateTerminal("terminal-1")
        workspace.updateRatio(splitID: "split-1", ratio: 0.73)
        workspace.replaceTerminal("terminal-1", with: "terminal-restarted")
        workspace.moveActiveGroup(by: 1)

        #expect(workspace.groups.map(\.id) == ["group-2", "group-1"])
        #expect(workspace.activeGroupID == "group-1")
        #expect(workspace.activeTerminalID == "terminal-restarted")
        guard case let .split(split) = workspace.activeGroup?.layout else {
            Issue.record("Expected the active group to keep its split layout")
            return
        }
        #expect(split.ratio == 0.73)
        #expect(split.first == .leaf(terminalID: "terminal-restarted"))
    }

    @Test func persisted_workspace_contains_layout_metadata_but_no_terminal_output() throws {
        let suite = "TerminalWorkspaceStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        var workspace = TerminalWorkspaceState.empty
        workspace.addGroup(terminalID: "terminal-1", id: "group-1")
        let didSplit = workspace.split(
            terminalID: "terminal-1",
            with: "terminal-2",
            axis: .vertical,
            splitID: "split-1"
        )
        #expect(didSplit)

        store.save(workspace, windowID: "window-1", projectID: "project-1")
        let restored = store.load(
            windowID: "window-1",
            projectID: "project-1",
            terminalIDs: ["terminal-1", "terminal-2"]
        )
        let data = try #require(store.encodedWorkspace(
            windowID: "window-1",
            projectID: "project-1"
        ))
        let encoded = String(decoding: data, as: UTF8.self)

        #expect(restored == workspace)
        #expect(encoded.contains("terminal-1"))
        #expect(!encoded.contains("terminal output must never persist"))
        #expect(!encoded.contains("output"))
    }

    @Test func native_split_geometry_converts_divider_positions_to_stable_ratios() {
        #expect(NativeSplitGeometry.ratio(dividerPosition: 730, availableLength: 1_000) == 0.73)
        #expect(NativeSplitGeometry.ratio(dividerPosition: -10, availableLength: 1_000) == 0.05)
        #expect(NativeSplitGeometry.ratio(dividerPosition: 990, availableLength: 1_000) == 0.95)
        #expect(NativeSplitGeometry.ratio(dividerPosition: 10, availableLength: 0) == nil)
    }
}
