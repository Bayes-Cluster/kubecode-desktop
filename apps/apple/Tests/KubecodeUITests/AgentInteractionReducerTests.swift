import Foundation
import Testing
@testable import KubecodeUI
import KubecodeKit

@Suite
struct AgentInteractionReducerTests {
    @Test func permission_and_elicitation_lifecycles_restore_from_events() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {"run_id":"run-1","seq":1,"kind":"permission_requested","payload":{"request_id":"p-1","tool":"Shell","options":[{"id":"allow","label":"Allow","kind":"allow_once"}]},"created_at":"now"},
          {"run_id":"run-1","seq":2,"kind":"permission_resolved","payload":{"request_id":"p-1"},"created_at":"now"},
          {"run_id":"run-1","seq":3,"kind":"elicitation_requested","payload":{"request_id":"e-1","message":"Choose a branch","requestedSchema":{"required":["branch"],"properties":{"branch":{"type":"string","title":"Branch","enum":["main","next"]}}}},"created_at":"now"}
        ]
        """.utf8))

        let state = AgentInteractionReducer.reduce(events)

        #expect(state.pendingPermission == nil)
        #expect(state.pendingElicitation?.requestID == "e-1")
        #expect(state.pendingElicitation?.properties.first?.options.map(\.id) == ["main", "next"])
    }

    @Test func tool_updates_replace_one_stable_card() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {"run_id":"run-1","seq":1,"kind":"tool_started","payload":{"tool_id":"t-1","tool":"Read","input":{"path":"README.md"},"status":"pending"},"created_at":"now"},
          {"run_id":"run-1","seq":2,"kind":"tool_completed","payload":{"tool_id":"t-1","tool":"Read","output":"done","status":"completed"},"created_at":"now"}
        ]
        """.utf8))

        let state = AgentInteractionReducer.reduce(events)

        #expect(state.tools.count == 1)
        #expect(state.tools[0].id == "t-1")
        #expect(state.tools[0].status == "completed")
        #expect(state.tools[0].output == "done")
    }

    @Test func elicitation_responses_validate_required_fields_and_preserve_json_types() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {
            "run_id":"run-1",
            "seq":1,
            "kind":"elicitation_requested",
            "payload":{
              "request_id":"e-typed",
              "message":"Configure the run",
              "requestedSchema":{
                "required":["name","workers","ratio"],
                "properties":{
                  "enabled":{"type":"boolean","title":"Enabled","default":true},
                  "name":{"type":"string","title":"Name"},
                  "note":{"type":"string","title":"Note"},
                  "ratio":{"type":"number","title":"Ratio"},
                  "workers":{"type":"integer","title":"Workers"}
                }
              }
            },
            "created_at":"now"
          }
        ]
        """.utf8))
        let elicitation = try #require(AgentInteractionReducer.reduce(events).pendingElicitation)
        var answers = Dictionary(uniqueKeysWithValues: elicitation.properties.map {
            ($0.id, $0.defaultValue)
        })

        #expect(!ElicitationResponseBuilder.isComplete(elicitation, answers: answers))
        #expect(ElicitationResponseBuilder.content(elicitation, answers: answers) == nil)

        answers["name"] = .string("Native run")
        answers["workers"] = .string("4")
        answers["ratio"] = .string("0.75")
        answers["note"] = .string("   ")

        #expect(ElicitationResponseBuilder.isComplete(elicitation, answers: answers))
        #expect(ElicitationResponseBuilder.content(elicitation, answers: answers) == [
            "enabled": .bool(true),
            "name": .string("Native run"),
            "ratio": .number(0.75),
            "workers": .number(4),
        ])

        answers["workers"] = .string("4.5")
        #expect(!ElicitationResponseBuilder.isComplete(elicitation, answers: answers))
        #expect(ElicitationResponseBuilder.content(elicitation, answers: answers) == nil)
    }
}
