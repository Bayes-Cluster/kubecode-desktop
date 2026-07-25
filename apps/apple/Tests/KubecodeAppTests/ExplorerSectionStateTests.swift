import Foundation
import Testing
import KubecodeKit
import KubecodeMacRuntime
import KubecodeUI
@testable import KubecodeApp

@Suite
struct ExplorerSectionStateTests {
    @Test func hidden_file_visibility_uses_a_direct_closed_or_open_eye_symbol() {
        #expect(ExplorerFilterPresentation.hiddenFilesSymbol(showHidden: false) == "eye.slash")
        #expect(ExplorerFilterPresentation.hiddenFilesSymbol(showHidden: true) == "eye")
    }

    @Test func a_new_plan_revision_reveals_plan_without_resetting_other_sections() {
        var state = ExplorerSectionState()
        state.planExpanded = false
        state.changesExpanded = false
        state.filesExpanded = true
        let first = [AgentPlanEntry(content: "Inspect", priority: "medium", status: .pending)]

        state.synchronize(plan: first)

        #expect(state.planExpanded)
        #expect(!state.changesExpanded)
        #expect(state.filesExpanded)

        state.planExpanded = false
        state.synchronize(plan: first)
        #expect(!state.planExpanded)

        state.synchronize(plan: [AgentPlanEntry(
            content: "Inspect",
            priority: "medium",
            status: .completed
        )])
        #expect(state.planExpanded)
    }

    @Test func clearing_a_session_plan_does_not_change_manual_section_choices() {
        var state = ExplorerSectionState()
        state.planExpanded = false
        state.synchronize(plan: [])

        #expect(!state.planExpanded)
        #expect(state.changesExpanded)
        #expect(state.filesExpanded)
    }

    @Test @MainActor func runtime_session_plan_updates_reveal_the_window_explorer_section() throws {
        let state = try JSONDecoder().decode(AgentSessionState.self, from: Data("""
        {
          "capabilities": null,
          "available_commands": null,
          "current_mode": null,
          "config_options": null,
          "plan": {"entries":[{"content":"Implement","priority":"high","status":"in_progress"}]},
          "usage": null,
          "mode_access": {"can_change":true,"reason":null}
        }
        """.utf8))
        let model = AppModel(connections: MacConnectionManager())
        model.explorerSections.planExpanded = false

        model.applySessionState(state)

        #expect(model.agentPlanEntries.map(\.content) == ["Implement"])
        #expect(model.explorerSections.planExpanded)
    }
}
