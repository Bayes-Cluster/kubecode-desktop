import Foundation
import Testing
@testable import KubecodeApp
import KubecodeCore
import KubecodeKit
import KubecodeMacRuntime

private final class DraftRunURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized)
@MainActor
struct SessionDraftStateTests {
    @Test func drafts_are_isolated_by_session_and_window_without_default_disk_persistence() throws {
        let suite = "SessionDraftState-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionDraftStore(defaults: defaults)

        store.save("First follow-up", windowID: "window-1", sessionID: "session-1")
        store.save("Second follow-up", windowID: "window-1", sessionID: "session-2")
        store.save("Other window", windowID: "window-2", sessionID: "session-1")

        #expect(store.load(windowID: "window-1", sessionID: "session-1") == "First follow-up")
        #expect(store.load(windowID: "window-1", sessionID: "session-2") == "Second follow-up")
        #expect(store.load(windowID: "window-2", sessionID: "session-1") == "Other window")
        #expect(SessionDraftStore(defaults: defaults).load(
            windowID: "window-1",
            sessionID: "session-1"
        ).isEmpty)
    }

    @Test func opted_in_drafts_restore_after_model_recreation_and_purge_when_disabled() throws {
        let suite = "SessionDraftPersistence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SessionDraftStore.setRelaunchPersistenceEnabled(true, defaults: defaults)
        SessionDraftStore(defaults: defaults).save(
            "Persisted follow-up",
            windowID: "window-1",
            sessionID: "session-1"
        )

        let restored = SessionDraftStore(defaults: defaults)
        #expect(restored.load(windowID: "window-1", sessionID: "session-1") == "Persisted follow-up")
        #expect(restored.load(windowID: "window-2", sessionID: "session-1").isEmpty)

        SessionDraftStore.setRelaunchPersistenceEnabled(false, defaults: defaults)
        #expect(SessionDraftStore(defaults: defaults).load(
            windowID: "window-1",
            sessionID: "session-1"
        ).isEmpty)
    }

    @Test func app_model_restores_each_session_draft_when_switching() throws {
        let suite = "SessionDraftSwitching-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            connections: MacConnectionManager(),
            sessionDraftStore: SessionDraftStore(defaults: defaults)
        )
        model.configureWindowPersistence(id: "window-1")
        let first = try conversation(id: "session-1", title: "First")
        let second = try conversation(id: "session-2", title: "Second")
        model.conversations = [first, second]

        model.selectConversation(first)
        model.runs = [try JSONDecoder().decode(AgentRun.self, from: Data("""
        {"id":"run-1","conversation_id":"session-1","project_id":"project-1","message":"Working","status":"running","error":null,"permission_mode":null,"internal":false}
        """.utf8))]
        #expect(model.activeRun?.id == "run-1")
        model.composer = "Prepared while running"
        model.selectConversation(second)
        #expect(model.composer.isEmpty)

        model.composer = "Second draft"
        model.selectConversation(first)
        #expect(model.composer == "Prepared while running")
        model.selectConversation(second)
        #expect(model.composer == "Second draft")
    }

    @Test func failed_run_restores_the_prompt_and_removes_the_optimistic_turn() async throws {
        DraftRunURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"error\":\"Runtime unavailable\"}".utf8))
        }
        defer { DraftRunURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftRunURLProtocol.self]
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:4123")!,
            token: "test-token",
            session: URLSession(configuration: configuration)
        )
        let model = AppModel(
            connections: MacConnectionManager(),
            serverSession: ServerSession(client: client)
        )
        let selected = try conversation(id: "session-1", title: "Work")
        model.selectedProjectID = "project-1"
        model.selectedConversationID = "session-1"
        model.conversations = [selected]
        model.composer = "Do not lose this prompt"

        model.sendMessage()
        try await waitUntil { model.errorMessage != nil }

        #expect(model.composer == "Do not lose this prompt")
        #expect(model.transcript.allSatisfy { !$0.id.hasPrefix("pending-") })
    }

    @Test func return_during_an_active_run_keeps_the_follow_up_as_a_draft() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftRunURLProtocol.self]
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
        model.conversations = [try conversation(id: "session-1", title: "Work")]
        model.runs = [try JSONDecoder().decode(AgentRun.self, from: Data("""
        {"id":"run-1","conversation_id":"session-1","project_id":"project-1","message":"Working","status":"running","error":null,"permission_mode":null,"internal":false}
        """.utf8))]
        model.composer = "Prepared follow-up"

        model.sendMessage()

        #expect(model.composer == "Prepared follow-up")
        #expect(model.transcript.isEmpty)
    }

    private func conversation(id: String, title: String) throws -> Conversation {
        try JSONDecoder().decode(Conversation.self, from: Data("""
        {"id":"\(id)","project_id":"project-1","agent_id":"claude_code","title":"\(title)","execution_mode":"shared","read_only":false}
        """.utf8))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { Issue.record("Timed out waiting for asynchronous draft behavior") }
    }
}
