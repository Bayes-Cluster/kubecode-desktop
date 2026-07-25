import Foundation
import Testing
@testable import KubecodeUI
import KubecodeKit

@Suite
struct TranscriptReducerTests {
    @Test func workspace_chunks_update_one_provider_message() throws {
        let events = try JSONDecoder().decode([WorkspaceEvent].self, from: Data("""
        [
          {"id":1,"kind":"text_delta","project_id":"p","conversation_id":"c","run_id":"r","payload":{"message_id":"m","text":"Hello "},"created_at":"now"},
          {"id":2,"kind":"text_delta","project_id":"p","conversation_id":"c","run_id":"r","payload":{"message_id":"m","text":"world"},"created_at":"now"}
        ]
        """.utf8))
        var items: [TranscriptItem] = []

        for event in events { TranscriptReducer.applyStreamingDelta(event, to: &items) }

        #expect(items.count == 1)
        #expect(items[0].text == "Hello world")
        #expect(items[0].role == .agent)
    }

    @Test func direct_run_stream_chunks_update_before_completion() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {"run_id":"r","seq":1,"kind":"text_delta","payload":{"message_id":"m","text":"Live "},"created_at":"now"},
          {"run_id":"r","seq":2,"kind":"text_delta","payload":{"message_id":"m","text":"output"},"created_at":"now"}
        ]
        """.utf8))
        var items: [TranscriptItem] = []

        TranscriptReducer.applyStreamingEvent(events[0], to: &items)
        #expect(items.first?.text == "Live ")
        TranscriptReducer.applyStreamingEvent(events[1], to: &items)
        #expect(items.first?.text == "Live output")
    }

    @Test func adjacent_provider_messages_form_one_selectable_agent_output() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {"run_id":"r","seq":1,"kind":"text_delta","payload":{"message_id":"m1","text":"First paragraph."},"created_at":"now"},
          {"run_id":"r","seq":2,"kind":"text_delta","payload":{"message_id":"m2","text":"Second paragraph."},"created_at":"now"},
          {"run_id":"r","seq":3,"kind":"text_delta","payload":{"message_id":"m2","text":" More."},"created_at":"now"}
        ]
        """.utf8))
        var items: [TranscriptItem] = []

        for event in events { TranscriptReducer.applyStreamingEvent(event, to: &items) }

        #expect(items.count == 1)
        #expect(items[0].role == .agent)
        #expect(items[0].text == "First paragraph.\n\nSecond paragraph. More.")
    }

    @Test func direct_thinking_chunks_are_visible_before_text_completion() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {"run_id":"r","seq":1,"kind":"thinking_delta","payload":{"message_id":"thought","text":"Inspect "},"created_at":"now"},
          {"run_id":"r","seq":2,"kind":"thinking_delta","payload":{"message_id":"thought","text":"state"},"created_at":"now"}
        ]
        """.utf8))
        var items: [TranscriptItem] = []

        TranscriptReducer.applyStreamingEvent(events[0], to: &items)
        #expect(items.first?.text == "Inspect ")
        TranscriptReducer.applyStreamingEvent(events[1], to: &items)
        #expect(items.first?.text == "Inspect state")
        #expect(items.first?.role == .thinking)
    }

    @Test func tool_updates_stay_in_their_timeline_position() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {"run_id":"r","seq":1,"kind":"text_delta","payload":{"message_id":"m1","text":"Checking."},"created_at":"now"},
          {"run_id":"r","seq":2,"kind":"tool_started","payload":{"tool_id":"t1","tool":"Read file","input":{"path":"README.md"},"status":"pending"},"created_at":"now"},
          {"run_id":"r","seq":3,"kind":"tool_completed","payload":{"tool_id":"t1","tool":"Read file","output":"done","status":"completed"},"created_at":"now"},
          {"run_id":"r","seq":4,"kind":"text_delta","payload":{"message_id":"m2","text":"Finished."},"created_at":"now"}
        ]
        """.utf8))
        var items: [TranscriptItem] = []

        for event in events { TranscriptReducer.applyStreamingEvent(event, to: &items) }

        #expect(items.map(\.role) == [.agent, .tool, .agent])
        #expect(items[1].status == "completed")
        #expect(items[1].detail?.contains("done") == true)
    }

    @Test func run_completion_is_one_stable_timeline_status_in_stream_and_history() throws {
        let events = try JSONDecoder().decode([AgentEvent].self, from: Data("""
        [
          {"run_id":"r","seq":1,"kind":"text_delta","payload":{"message_id":"m","text":"Done."},"created_at":"now"},
          {"run_id":"r","seq":2,"kind":"run_completed","payload":{"status":"completed","error":null},"created_at":"now"},
          {"run_id":"r","seq":3,"kind":"run_completed","payload":{"status":"completed","error":null},"created_at":"now"}
        ]
        """.utf8))
        var streamingItems: [TranscriptItem] = []
        for event in events { TranscriptReducer.applyStreamingEvent(event, to: &streamingItems) }

        #expect(streamingItems.map(\.role) == [.agent, .status])
        #expect(streamingItems.last?.id == "run-r-status")
        #expect(streamingItems.last?.status == "completed")

        let run = try JSONDecoder().decode(AgentRun.self, from: Data("""
        {
          "id":"r","conversation_id":"c","project_id":"p","message":"Finish it",
          "status":"completed","error":null,"permission_mode":null,"internal":false
        }
        """.utf8))
        let historyItems = TranscriptReducer.items(run: run, events: Array(events.prefix(2)))
        #expect(historyItems.filter { $0.role == .status }.count == 1)
        #expect(historyItems.last?.id == "run-r-status")
    }
}
