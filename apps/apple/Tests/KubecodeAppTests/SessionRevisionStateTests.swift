import Foundation
import KubecodeCore
import KubecodeKit
import KubecodeMacRuntime
import Testing
@testable import KubecodeApp

@Suite
struct SessionRevisionStateTests {
    @Test func navigator_uses_server_order_and_current_timeline_as_the_last_position() throws {
        let revisions = try [revision("one", snapshot: "snapshot-1"), revision("two", snapshot: "snapshot-2")]
        var state = SessionRevisionState(revisions: revisions)

        #expect(state.totalPositions == 3)
        #expect(state.activeIndex == 2)
        #expect(!state.isViewingRevision)

        #expect(state.select(index: 0) == "snapshot-1")
        #expect(state.activeIndex == 0)
        #expect(state.isViewingRevision)

        #expect(state.select(index: 2) == nil)
        #expect(state.activeIndex == 2)
        #expect(!state.isViewingRevision)
    }

    @Test func refreshed_revisions_preserve_a_valid_selection_and_fall_back_when_removed() throws {
        let first = try revision("one", snapshot: "snapshot-1")
        let second = try revision("two", snapshot: "snapshot-2")
        var state = SessionRevisionState(revisions: [first, second])
        _ = state.select(index: 0)

        state.replaceRevisions([first, second, try revision("three", snapshot: "snapshot-3")])
        #expect(state.viewedSnapshotConversationID == "snapshot-1")
        #expect(state.activeIndex == 0)

        state.replaceRevisions([second])
        #expect(state.viewedSnapshotConversationID == nil)
        #expect(state.activeIndex == 1)
    }

    @Test func a_revision_that_keeps_files_surfaces_the_precise_checkpoint_reason() throws {
        var state = SessionRevisionState()

        state.recordCreated(try revision(
            "one",
            snapshot: "snapshot-1",
            workspaceRestore: "kept",
            workspaceRestoreReason: "workspace_changed"
        ))

        #expect(state.workspaceWarning == .workspaceChanged)
        #expect(state.viewedSnapshotConversationID == nil)
        #expect(state.revisions.map(\.id) == ["one"])
    }

    @Test func revision_actions_are_disabled_for_active_read_only_or_historical_timelines() {
        #expect(SessionRevisionPolicy.canRevise(isReadOnly: false, isViewingRevision: false, hasActiveRun: false))
        #expect(!SessionRevisionPolicy.canRevise(isReadOnly: true, isViewingRevision: false, hasActiveRun: false))
        #expect(!SessionRevisionPolicy.canRevise(isReadOnly: false, isViewingRevision: true, hasActiveRun: false))
        #expect(!SessionRevisionPolicy.canRevise(isReadOnly: false, isViewingRevision: false, hasActiveRun: true))
    }

    @Test func undo_is_only_offered_for_the_latest_unsuccessful_turn() {
        for status in ["cancelled", "failed", "interrupted"] {
            #expect(SessionRevisionPolicy.canUndo(runStatus: status, isLatest: true, canRevise: true))
        }
        #expect(!SessionRevisionPolicy.canUndo(runStatus: "completed", isLatest: true, canRevise: true))
        #expect(!SessionRevisionPolicy.canUndo(runStatus: "failed", isLatest: false, canRevise: true))
        #expect(!SessionRevisionPolicy.canUndo(runStatus: "failed", isLatest: true, canRevise: false))
    }

    @Test @MainActor func a_historical_revision_forces_the_selected_session_read_only() throws {
        let model = AppModel(connections: MacConnectionManager())
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data("""
        {
          "id":"session-1","project_id":"project-1","agent_id":"claude_code",
          "title":"Work","execution_mode":"shared","read_only":false
        }
        """.utf8))
        model.conversations = [conversation]
        model.selectedConversationID = conversation.id
        model.revisions = [try revision("one", snapshot: "snapshot-1")]

        #expect(!model.selectedConversationIsReadOnly)
        #expect(model.canReviseSelectedConversation)

        _ = model.revisionState.select(index: 0)
        #expect(model.selectedConversationIsReadOnly)
        #expect(!model.canReviseSelectedConversation)

        _ = model.revisionState.select(index: 1)
        #expect(!model.selectedConversationIsReadOnly)
    }

    private func revision(
        _ id: String,
        snapshot: String,
        workspaceRestore: String = "restored",
        workspaceRestoreReason: String? = nil
    ) throws -> ConversationRevision {
        let reason = workspaceRestoreReason.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(ConversationRevision.self, from: Data("""
        {
          "id":"\(id)","conversation_id":"session-1",
          "snapshot_conversation_id":"\(snapshot)","forked_at_run_id":"run-1",
          "created_at":"now","workspace_restore":"\(workspaceRestore)",
          "workspace_restore_reason":\(reason)
        }
        """.utf8))
    }
}

private final class RevisionWorkflowURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct SessionRevisionWorkflowTests {
    @Test func revise_rehydrates_current_timeline_and_snapshot_navigation_is_read_only() async throws {
        let revision = #"{"id":"revision-1","conversation_id":"session-1","snapshot_conversation_id":"snapshot-1","forked_at_run_id":"run-target","created_at":"now","workspace_restore":"kept","workspace_restore_reason":"workspace_changed"}"#
        let sessionState = #"{"capabilities":null,"available_commands":null,"current_mode":null,"config_options":null,"plan":null,"usage":null,"mode_access":{"can_change":true,"reason":null}}"#
        RevisionWorkflowURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            let status: Int
            switch (request.httpMethod, path) {
            case ("POST", "/api/v1/sessions/session-1/turns/run-target/revise"):
                body = revision
                status = 201
            case ("GET", "/api/v1/sessions/session-1/history"):
                body = Self.history(runID: "run-current", message: "Current revised timeline", conversationID: "session-1")
                status = 200
            case ("GET", "/api/v1/sessions/snapshot-1/history"):
                body = Self.history(runID: "run-snapshot", message: "Previous timeline", conversationID: "snapshot-1")
                status = 200
            case ("GET", "/api/v1/sessions/session-1/state"),
                 ("GET", "/api/v1/sessions/snapshot-1/state"):
                body = sessionState
                status = 200
            case ("GET", "/api/v1/sessions/session-1/revisions"):
                body = "[\(revision)]"
                status = 200
            default:
                throw URLError(.unsupportedURL)
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevisionWorkflowURLProtocol.self]
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:4123")!,
            token: "test-token",
            session: URLSession(configuration: configuration)
        )
        let model = AppModel(
            connections: MacConnectionManager(),
            serverSession: ServerSession(client: client)
        )
        model.selectedProjectID = "project-1"
        model.selectedConversationID = "session-1"
        model.conversations = [try decode(Conversation.self, from: """
        {"id":"session-1","project_id":"project-1","agent_id":"claude_code","title":"Work","execution_mode":"shared","read_only":false}
        """)]
        model.runs = [try decode(AgentRun.self, from: """
        {"id":"run-target","conversation_id":"session-1","project_id":"project-1","message":"Original","status":"completed","error":null,"permission_mode":null,"internal":false}
        """)]

        model.reviseTurn(runID: "run-target", replacement: nil)
        try await waitForRevisionWork(model)

        #expect(model.transcript.first?.text == "Current revised timeline")
        #expect(model.revisions.map(\.snapshotConversationID) == ["snapshot-1"])
        #expect(model.revisionState.workspaceWarning == .workspaceChanged)
        #expect(!model.selectedConversationIsReadOnly)

        model.selectRevision(at: 0)
        try await waitForRevisionWork(model)

        #expect(model.revisionState.viewedSnapshotConversationID == "snapshot-1")
        #expect(model.transcript.first?.text == "Previous timeline")
        #expect(model.selectedConversationIsReadOnly)
    }

    private static func history(runID: String, message: String, conversationID: String) -> String {
        """
        {"runs":[{"id":"\(runID)","conversation_id":"\(conversationID)","project_id":"project-1","message":"\(message)","status":"completed","error":null,"permission_mode":null,"internal":false}],"events":{},"next_cursor":null,"session_events":[]}
        """
    }

    private func waitForRevisionWork(_ model: AppModel) async throws {
        for _ in 0..<200 where model.isChangingRevision {
            try await Task.sleep(for: .milliseconds(10))
        }
        if model.isChangingRevision { Issue.record("Revision workflow did not finish") }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
