import Foundation
import Testing
@testable import KubecodeApp
import KubecodeKit
import KubecodeMacRuntime

@Suite
@MainActor
struct SessionSetupPresentationTests {
    @Test func provider_entry_preserves_the_requested_agent() throws {
        let model = try configuredModel(agentIDs: [.claudeCode, .codex, .opencode])

        model.presentSessionSetup(preferredAgent: .codex)

        #expect(model.sessionSetupRequest?.agentID == .codex)
    }

    @Test func generic_entry_prefers_the_selected_sessions_available_agent() throws {
        let model = try configuredModel(agentIDs: [.claudeCode, .codex])
        model.conversations = [try decode(Conversation.self, from: """
        {
          "id":"session-1","project_id":"project-1","agent_id":"codex",
          "title":"Existing Codex Session","execution_mode":"default"
        }
        """)]
        model.selectedConversationID = "session-1"

        model.presentSessionSetup()

        #expect(model.sessionSetupRequest?.agentID == .codex)
    }

    @Test func unavailable_preference_falls_back_and_empty_availability_does_not_present() throws {
        let model = try configuredModel(agentIDs: [.claudeCode])

        model.presentSessionSetup(preferredAgent: .opencode)
        #expect(model.sessionSetupRequest?.agentID == .claudeCode)

        model.sessionSetupRequest = nil
        model.agents = []
        model.presentSessionSetup(preferredAgent: .codex)
        #expect(model.sessionSetupRequest == nil)
    }

    @Test func every_supported_agent_has_a_packaged_template_icon() throws {
        for agentID in AgentID.allCases {
            let image = try #require(AgentIcon.image(for: agentID))
            #expect(image.isTemplate)
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }

    private func configuredModel(agentIDs: [AgentID]) throws -> AppModel {
        let model = AppModel(connections: MacConnectionManager())
        model.projects = [try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)]
        model.selectedProjectID = "project-1"
        model.agents = try agentIDs.map { agentID in
            try decode(AgentDescriptor.self, from: """
            {
              "id":"\(agentID.rawValue)","available":true,
              "executable":"\(agentID.rawValue)","detail":null,"adapter":null
            }
            """)
        }
        return model
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
