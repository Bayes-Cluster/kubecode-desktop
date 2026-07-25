import Foundation
import Testing
@testable import KubecodeApp
import KubecodeCore
import KubecodeKit
import KubecodeMacRuntime

private final class SessionLifecycleURLProtocol: URLProtocol, @unchecked Sendable {
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
struct SessionLifecyclePolicyTests {
    @Test func blank_titles_restore_the_agent_title() {
        #expect(SessionLifecyclePolicy.manualTitle(from: "  ") == nil)
        #expect(SessionLifecyclePolicy.manualTitle(from: "  Release work  ") == "Release work")
    }

    @Test func destructive_actions_are_hidden_for_non_leader_team_members() throws {
        let solo = try conversation(id: "solo", teamID: nil, role: nil)
        let leader = try conversation(id: "leader", teamID: "team-1", role: "leader")
        let teammate = try conversation(id: "worker", teamID: "team-1", role: "teammate")
        let discriminator = try conversation(
            id: "reviewer",
            teamID: "team-1",
            role: "discriminator"
        )

        #expect(SessionLifecyclePolicy.canDelete(solo))
        #expect(SessionLifecyclePolicy.canDelete(leader))
        #expect(!SessionLifecyclePolicy.canDelete(teammate))
        #expect(!SessionLifecyclePolicy.canDelete(discriminator))
    }

    @Test func deleting_a_team_leader_removes_every_team_session_projection() throws {
        let solo = try conversation(id: "solo", teamID: nil, role: nil)
        let leader = try conversation(id: "leader", teamID: "team-1", role: "leader")
        let teammate = try conversation(id: "worker", teamID: "team-1", role: "teammate")
        let discriminator = try conversation(
            id: "reviewer",
            teamID: "team-1",
            role: "discriminator"
        )

        #expect(SessionLifecyclePolicy.removedConversationIDs(
            deleting: solo,
            conversations: [solo, leader, teammate, discriminator]
        ) == ["solo"])
        #expect(Set(SessionLifecyclePolicy.removedConversationIDs(
            deleting: leader,
            conversations: [solo, leader, teammate, discriminator]
        )) == Set(["leader", "worker", "reviewer"]))
    }

    @Test func only_provider_backed_sessions_can_fork() throws {
        let providerBacked = try conversation(
            id: "provider",
            teamID: nil,
            role: nil,
            providerSessionID: "native-1"
        )
        let recreated = try conversation(id: "recreated", teamID: nil, role: nil)

        #expect(SessionLifecyclePolicy.canFork(providerBacked))
        #expect(!SessionLifecyclePolicy.canFork(recreated))
    }

    @Test func deleting_a_leader_clears_the_whole_team_from_the_window_model() async throws {
        SessionLifecycleURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path.hasSuffix("/sessions/leader") == true)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { SessionLifecycleURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionLifecycleURLProtocol.self]
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:4123")!,
            token: "test-token",
            session: URLSession(configuration: configuration)
        )
        let model = AppModel(
            connections: MacConnectionManager(),
            serverSession: ServerSession(client: client)
        )
        let leader = try conversation(id: "leader", teamID: "team-1", role: "leader")
        let teammate = try conversation(id: "worker", teamID: "team-1", role: "teammate")
        let discriminator = try conversation(
            id: "reviewer",
            teamID: "team-1",
            role: "discriminator"
        )
        model.conversations = [leader, teammate, discriminator]
        model.selectedConversationID = teammate.id
        model.composer = "Private teammate draft"

        model.deleteConversation(leader)
        try await waitUntil { model.conversations.isEmpty }

        #expect(model.selectedConversationID == nil)
        #expect(model.composer.isEmpty)
    }

    private func conversation(
        id: String,
        teamID: String?,
        role: String?,
        providerSessionID: String? = nil
    ) throws -> Conversation {
        let teamFields = teamID.map {
            ",\"team_id\":\"\($0)\",\"team_role\":\"\(role ?? "")\",\"team_title\":\"Research Team\""
        } ?? ""
        let providerField = providerSessionID.map { ",\"provider_session_id\":\"\($0)\"" } ?? ""
        return try JSONDecoder().decode(Conversation.self, from: Data("""
        {"id":"\(id)","project_id":"project-1","agent_id":"claude_code","title":"\(id)","execution_mode":"shared","read_only":false\(teamFields)\(providerField)}
        """.utf8))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { Issue.record("Timed out waiting for Session lifecycle mutation") }
    }
}
