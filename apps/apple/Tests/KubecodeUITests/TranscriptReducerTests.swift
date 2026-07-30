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

    @Test func repeated_thinking_tools_and_updates_form_one_run_presentation() {
        let items = [
            TranscriptItem(id: "user", role: .user, text: "Inspect", runID: "run-1"),
            TranscriptItem(id: "thought-1", role: .thinking, text: "Plan", runID: "run-1"),
            TranscriptItem(id: "tool-1", role: .tool, text: "Read", runID: "run-1"),
            TranscriptItem(id: "update", role: .agent, text: "Found the entry point", runID: "run-1"),
            TranscriptItem(id: "thought-2", role: .thinking, text: "Verify", runID: "run-1"),
            TranscriptItem(id: "tool-2", role: .tool, text: "Test", runID: "run-1"),
        ]

        let entries = TranscriptPresentation.entries(items: items, activeRunID: "run-1")

        #expect(entries.map(\.id) == ["run-run-1-presentation"])
        guard case let .run(presentation) = entries[0],
              let activity = presentation.activity,
              let output = presentation.output
        else {
            Issue.record("Expected one run-level presentation")
            return
        }
        #expect(presentation.userItems.map(\.id) == ["user"])
        #expect(activity.isActive)
        #expect(activity.items.map(\.id) == ["thought-1", "tool-1", "thought-2", "tool-2"])
        #expect(activity.stepCount == 4)
        #expect(activity.toolCount == 2)
        #expect(!activity.defaultExpanded)
        #expect(output.id == "run-run-1-output")
        #expect(output.phase == .update)
        #expect(output.text == "Found the entry point")
    }

    @Test func completed_run_promotes_only_the_last_agent_text_to_final_output() {
        let items = [
            TranscriptItem(id: "user", role: .user, text: "Inspect", runID: "run-1"),
            TranscriptItem(id: "update", role: .agent, text: "Reading files", runID: "run-1"),
            TranscriptItem(id: "tool", role: .tool, text: "Read", runID: "run-1"),
            TranscriptItem(id: "answer", role: .agent, text: "Final answer", runID: "run-1"),
            TranscriptItem(
                id: "status",
                role: .status,
                text: "completed",
                runID: "run-1",
                status: "completed"
            ),
        ]

        let entries = TranscriptPresentation.entries(items: items, activeRunID: nil)

        #expect(entries.map(\.id) == ["run-run-1-presentation"])
        guard case let .run(presentation) = entries[0],
              let activity = presentation.activity,
              let output = presentation.output
        else {
            Issue.record("Expected activity followed by final output")
            return
        }
        #expect(activity.items.map(\.id) == ["tool"])
        #expect(!activity.defaultExpanded)
        #expect(output.id == "run-run-1-output")
        #expect(output.phase == .final)
        #expect(output.text == "Final answer")
    }

    @Test func failed_run_surfaces_partial_output_outside_collapsed_activity() {
        let items = [
            TranscriptItem(id: "user", role: .user, text: "Inspect", runID: "run-1"),
            TranscriptItem(id: "partial", role: .agent, text: "Partial", runID: "run-1"),
            TranscriptItem(id: "tool", role: .tool, text: "Shell", runID: "run-1", status: "failed"),
            TranscriptItem(id: "error", role: .system, text: "Command failed", runID: "run-1"),
            TranscriptItem(
                id: "status",
                role: .status,
                text: "failed",
                runID: "run-1",
                status: "failed"
            ),
        ]

        let entries = TranscriptPresentation.entries(items: items, activeRunID: nil)

        #expect(entries.map(\.id) == ["run-run-1-presentation"])
        guard case let .run(presentation) = entries[0],
              let activity = presentation.activity,
              let output = presentation.output
        else {
            Issue.record("Expected failed run presentation")
            return
        }
        #expect(activity.items.map(\.id) == ["tool"])
        #expect(!activity.defaultExpanded)
        #expect(activity.status == "failed")
        #expect(output.id == "run-run-1-output")
        #expect(output.phase == .partial)
        #expect(output.text == "Partial")
        #expect(presentation.trailingItems.map(\.id) == ["error", "status"])
    }

    @Test func activity_recent_window_is_bounded_without_discarding_steps() {
        let activity = TranscriptRunActivity(
            runID: "run-1",
            items: (1...12).map {
                TranscriptItem(id: "step-\($0)", role: .thinking, text: "Step \($0)", runID: "run-1")
            },
            isActive: false,
            status: "completed"
        )

        #expect(activity.recentItems(limit: 8).map(\.id) == (5...12).map { "step-\($0)" })
        #expect(activity.hiddenItemCount(limit: 8) == 4)
        #expect(activity.items.count == 12)
    }

    @Test func activity_identity_survives_completion_and_run_boundaries_remain_independent() {
        let activeItems = [
            TranscriptItem(id: "run-1-user", role: .user, text: "First", runID: "run-1"),
            TranscriptItem(id: "run-1-thought", role: .thinking, text: "Think", runID: "run-1"),
        ]
        let completedItems = activeItems + [
            TranscriptItem(id: "run-1-answer", role: .agent, text: "Done", runID: "run-1"),
            TranscriptItem(
                id: "run-1-status",
                role: .status,
                text: "completed",
                runID: "run-1",
                status: "completed"
            ),
            TranscriptItem(id: "run-2-user", role: .user, text: "Second", runID: "run-2"),
            TranscriptItem(id: "run-2-tool", role: .tool, text: "Shell", runID: "run-2"),
            TranscriptItem(id: "notice", role: .system, text: "Unscoped notice"),
        ]

        let active = TranscriptPresentation.entries(items: activeItems, activeRunID: "run-1")
        let completed = TranscriptPresentation.entries(items: completedItems, activeRunID: "run-2")

        #expect(active.map(\.id) == ["run-run-1-presentation"])
        #expect(completed.map(\.id) == [
            "run-run-1-presentation", "run-run-2-presentation", "notice",
        ])

        guard case let .run(activeRun) = active[0],
              case let .run(completedRun) = completed[0],
              let completedOutput = completedRun.output
        else {
            Issue.record("Expected stable run presentations")
            return
        }
        #expect(activeRun.activity?.id == completedRun.activity?.id)
        #expect(completedOutput.id == "run-run-1-output")
        #expect(completedOutput.phase == .final)
    }

    @Test func active_output_preserves_complete_exact_source_and_stable_output_id() {
        let exactSource = "  # 进度\n" + String(repeating: "界🙂", count: 140) + "\n\n  tail  \n"
        let initial = TranscriptPresentation.entries(items: [
            TranscriptItem(id: "user", role: .user, text: "Inspect", runID: "run-1"),
            TranscriptItem(id: "update-1", role: .agent, text: "First update", runID: "run-1"),
        ], activeRunID: "run-1")
        let refreshed = TranscriptPresentation.entries(items: [
            TranscriptItem(id: "user", role: .user, text: "Inspect", runID: "run-1"),
            TranscriptItem(id: "update-1", role: .agent, text: "First update", runID: "run-1"),
            TranscriptItem(
                id: "update-2",
                role: .agent,
                text: exactSource,
                runID: "run-1",
                messageID: "message-2"
            ),
        ], activeRunID: "run-1")
        let completed = TranscriptPresentation.entries(items: [
            TranscriptItem(id: "user", role: .user, text: "Inspect", runID: "run-1"),
            TranscriptItem(
                id: "update-2",
                role: .agent,
                text: exactSource,
                runID: "run-1",
                messageID: "message-2"
            ),
            TranscriptItem(
                id: "status",
                role: .status,
                text: "completed",
                runID: "run-1",
                status: "completed"
            ),
        ], activeRunID: nil)

        guard case let .run(initialRun) = initial[0],
              case let .run(refreshedRun) = refreshed[0],
              case let .run(completedRun) = completed[0],
              let initialOutput = initialRun.output,
              let refreshedOutput = refreshedRun.output,
              let completedOutput = completedRun.output
        else {
            Issue.record("Expected active output slots")
            return
        }
        #expect(initialOutput.id == refreshedOutput.id)
        #expect(refreshedOutput.id == completedOutput.id)
        #expect(refreshedOutput.phase == .update)
        #expect(completedOutput.phase == .final)
        #expect(refreshedOutput.sourceItemID == "update-2")
        #expect(refreshedOutput.sourceMessageID == "message-2")
        #expect(refreshedOutput.text == exactSource)
        #expect(completedOutput.text == exactSource)
        #expect(refreshedOutput.text.utf8.elementsEqual(exactSource.utf8))
        #expect(completedOutput.text.utf8.elementsEqual(exactSource.utf8))
    }

    @Test func partial_terminal_status_preserves_complete_source_and_ordering() {
        let exactSource = "\n  Partial **Markdown** 界🙂\nline two  \n"

        for status in ["failed", "cancelled", "timed_out", "interrupted"] {
            let entries = TranscriptPresentation.entries(items: [
                TranscriptItem(id: "user", role: .user, text: "Inspect", runID: "run-1"),
                TranscriptItem(
                    id: "answer",
                    role: .agent,
                    text: exactSource,
                    runID: "run-1",
                    messageID: "message"
                ),
                TranscriptItem(
                    id: "status-\(status)",
                    role: .status,
                    text: status,
                    runID: "run-1",
                    status: status
                ),
                TranscriptItem(
                    id: "error-\(status)",
                    role: .system,
                    text: "Error: \(status)",
                    runID: "run-1"
                ),
            ], activeRunID: nil)

            guard case let .run(run) = entries.first,
                  let output = run.output
            else {
                Issue.record("Expected partial output for \(status)")
                continue
            }
            #expect(output.id == "run-run-1-output")
            #expect(output.phase == .partial)
            #expect(output.text == exactSource)
            #expect(output.text.utf8.elementsEqual(exactSource.utf8))
            #expect(output.sourceItemID == "answer")
            #expect(output.sourceMessageID == "message")
            #expect(run.trailingItems.map(\.id) == ["status-\(status)", "error-\(status)"])
            #expect(run.trailingItems.first?.status == status)
        }
    }
}
