import Foundation
import Testing
@testable import KubecodeCore
import KubecodeKit

private enum WorkspaceStreamTestError: Error {
    case disconnected
}

private actor ScriptedWorkspaceEventSource {
    private var requestedCursors: [Int] = []
    private var continuations: [AsyncThrowingStream<WorkspaceEvent, Error>.Continuation] = []

    func connect(after cursor: Int) -> AsyncThrowingStream<WorkspaceEvent, Error> {
        let pair = AsyncThrowingStream<WorkspaceEvent, Error>.makeStream()
        requestedCursors.append(cursor)
        continuations.append(pair.continuation)
        return pair.stream
    }

    func cursors() -> [Int] { requestedCursors }

    func waitForConnectionCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if continuations.count >= expected { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(expected) workspace event connections")
    }

    func yield(_ event: WorkspaceEvent, connection index: Int) {
        continuations[index].yield(event)
    }

    func fail(connection index: Int) {
        continuations[index].finish(throwing: WorkspaceStreamTestError.disconnected)
    }
}

private actor SuspendedWorkspaceCursorLoader {
    private var requestCount = 0
    private var continuation: CheckedContinuation<Int, Never>?

    func load() async -> Int {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForRequest() async {
        for _ in 0..<1_000 {
            if requestCount > 0 { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the workspace cursor request")
    }

    func count() -> Int { requestCount }

    func resume(returning cursor: Int) {
        continuation?.resume(returning: cursor)
        continuation = nil
    }
}

private actor SuspendedSummaryLoader {
    private var workspaceRequests = 0
    private var workspaceContinuation: CheckedContinuation<WorkspaceSummaryProjection, Never>?
    private var conversationRequests: [String: Int] = [:]
    private var conversationContinuations: [
        String: [CheckedContinuation<[Conversation], Never>]
    ] = [:]

    func loadWorkspace() async -> WorkspaceSummaryProjection {
        workspaceRequests += 1
        return await withCheckedContinuation { workspaceContinuation = $0 }
    }

    func loadConversations(projectID: String) async -> [Conversation] {
        conversationRequests[projectID, default: 0] += 1
        return await withCheckedContinuation {
            conversationContinuations[projectID, default: []].append($0)
        }
    }

    func waitForWorkspaceRequests(_ expected: Int) async {
        for _ in 0..<1_000 {
            if workspaceRequests >= expected { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(expected) workspace summary requests")
    }

    func waitForConversationRequests(_ expected: Int, projectID: String) async {
        for _ in 0..<1_000 {
            if conversationRequests[projectID, default: 0] >= expected { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(expected) conversation requests for \(projectID)")
    }

    func resumeWorkspace(returning value: WorkspaceSummaryProjection) {
        workspaceContinuation?.resume(returning: value)
        workspaceContinuation = nil
    }

    func resumeConversations(projectID: String, returning value: [Conversation]) {
        resumeConversations(projectID: projectID, requestIndex: 0, returning: value)
    }

    func resumeConversations(
        projectID: String,
        requestIndex: Int,
        returning value: [Conversation]
    ) {
        guard var continuations = conversationContinuations[projectID],
              continuations.indices.contains(requestIndex)
        else { return }
        continuations.remove(at: requestIndex).resume(returning: value)
        conversationContinuations[projectID] = continuations.isEmpty ? nil : continuations
    }

    func workspaceRequestCount() -> Int { workspaceRequests }
    func conversationRequestCount(projectID: String) -> Int {
        conversationRequests[projectID, default: 0]
    }
}

private actor SequencedSummaryLoader {
    private var sessionValues: [[Conversation]]
    private var conversationValues: [String: [[Conversation]]]
    private var teamValues: [String: [[TeamSnapshot]]]
    private var terminalValues: [String: [[TerminalInfo]]]
    private var sessionRequests = 0
    private var conversationRequests: [String: Int] = [:]
    private var teamRequests: [String: Int] = [:]
    private var terminalRequests: [String: Int] = [:]

    init(
        sessions: [[Conversation]],
        conversations: [String: [[Conversation]]],
        teams: [String: [[TeamSnapshot]]],
        terminals: [String: [[TerminalInfo]]]
    ) {
        sessionValues = sessions
        conversationValues = conversations
        teamValues = teams
        terminalValues = terminals
    }

    func loadSessions() -> [Conversation] {
        sessionRequests += 1
        return sessionValues.removeFirst()
    }

    func loadConversations(projectID: String) -> [Conversation] {
        conversationRequests[projectID, default: 0] += 1
        return conversationValues[projectID, default: []].removeFirst()
    }

    func loadTeams(projectID: String) -> [TeamSnapshot] {
        teamRequests[projectID, default: 0] += 1
        return teamValues[projectID, default: []].removeFirst()
    }

    func loadTerminals(projectID: String) -> [TerminalInfo] {
        terminalRequests[projectID, default: 0] += 1
        return terminalValues[projectID, default: []].removeFirst()
    }

    func counts(projectID: String) -> (sessions: Int, conversations: Int, teams: Int, terminals: Int) {
        (
            sessionRequests,
            conversationRequests[projectID, default: 0],
            teamRequests[projectID, default: 0],
            terminalRequests[projectID, default: 0]
        )
    }
}

private func workspaceEvent(
    id: Int,
    kind: String = "session_updated",
    projectID: String = "project-1"
) throws -> WorkspaceEvent {
    let data = Data(
        """
        {"id":\(id),"kind":"\(kind)","project_id":"\(projectID)","conversation_id":"session-1","run_id":null,"payload":{},"created_at":"now"}
        """.utf8
    )
    return try JSONDecoder().decode(WorkspaceEvent.self, from: data)
}

private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func project(_ id: String) throws -> Project {
    try decode(Project.self, from: """
    {"id":"\(id)","name":"\(id)","workspaces_enabled":false}
    """)
}

private func agent() throws -> AgentDescriptor {
    try decode(AgentDescriptor.self, from: """
    {"id":"claude_code","available":true,"version":"1","executable":"claude","error":null,"readiness":"ready","checked_at":1,"cli":null,"adapter":null}
    """)
}

private func conversation(_ id: String, projectID: String) throws -> Conversation {
    try decode(Conversation.self, from: """
    {"id":"\(id)","project_id":"\(projectID)","agent_id":"claude_code","title":"\(id)","execution_mode":"default","read_only":false}
    """)
}

private func team(_ id: String, projectID: String, status: String) throws -> TeamSnapshot {
    try decode(TeamSnapshot.self, from: """
    {"team":{"id":"\(id)","project_id":"\(projectID)","title":"\(id)","status":"\(status)","goal":"Ship"},"summary":{"running":0,"queued":0,"needs_attention":0,"done":0,"total_tasks":0},"members":[],"tasks":[],"attention":[]}
    """)
}

private func terminal(_ id: String, projectID: String, status: String) throws -> TerminalInfo {
    try decode(TerminalInfo.self, from: """
    {"id":"\(id)","project_id":"\(projectID)","conversation_id":null,"title":"\(id)","kind":"regular","cols":80,"rows":24,"status":"\(status)","exit_code":null,"signal":null}
    """)
}

private func collectEventIDs(
    from stream: AsyncThrowingStream<WorkspaceEvent, Error>,
    count: Int
) async throws -> [Int] {
    var ids: [Int] = []
    for try await event in stream {
        ids.append(event.id)
        if ids.count == count { break }
    }
    return ids
}

@Suite
struct ServerSessionTests {
    @Test func server_session_has_stable_identity_and_exposes_its_transport() {
        let client = RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token")
        let id = UUID()
        let session = ServerSession(id: id, client: client)

        #expect(session.id == id)
        #expect(session.client.origin == client.origin)
    }

    @Test func workspace_events_share_one_upstream_connection_across_subscribers() async throws {
        let source = ScriptedWorkspaceEventSource()
        let session = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token"),
            workspaceEventCursor: { 10 },
            workspaceEventStream: { cursor in await source.connect(after: cursor) },
            workspaceEventSleep: { _ in }
        )

        let first = try await session.workspaceEvents()
        let second = try await session.workspaceEvents()
        let firstResult = Task { try await collectEventIDs(from: first, count: 1) }
        let secondResult = Task { try await collectEventIDs(from: second, count: 1) }

        await source.waitForConnectionCount(1)
        await source.yield(try workspaceEvent(id: 11), connection: 0)

        #expect(try await firstResult.value == [11])
        #expect(try await secondResult.value == [11])
        #expect(await source.cursors() == [10])
    }

    @Test func concurrent_first_subscribers_coalesce_cursor_initialization() async throws {
        let cursorLoader = SuspendedWorkspaceCursorLoader()
        let source = ScriptedWorkspaceEventSource()
        let session = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token"),
            workspaceEventCursor: { await cursorLoader.load() },
            workspaceEventStream: { cursor in await source.connect(after: cursor) },
            workspaceEventSleep: { _ in }
        )

        async let first = session.workspaceEvents()
        async let second = session.workspaceEvents()
        await cursorLoader.waitForRequest()
        await cursorLoader.resume(returning: 10)
        _ = try await (first, second)
        await source.waitForConnectionCount(1)

        #expect(await cursorLoader.count() == 1)
        #expect(await source.cursors() == [10])
    }

    @Test func workspace_event_reconnect_resumes_from_last_cursor_and_deduplicates_replay() async throws {
        let source = ScriptedWorkspaceEventSource()
        let session = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token"),
            workspaceEventCursor: { 40 },
            workspaceEventStream: { cursor in await source.connect(after: cursor) },
            workspaceEventSleep: { _ in }
        )

        let stream = try await session.workspaceEvents()
        let result = Task { try await collectEventIDs(from: stream, count: 2) }

        await source.waitForConnectionCount(1)
        await source.yield(try workspaceEvent(id: 41), connection: 0)
        await source.fail(connection: 0)
        await source.waitForConnectionCount(2)
        await source.yield(try workspaceEvent(id: 41), connection: 1)
        await source.yield(try workspaceEvent(id: 42), connection: 1)

        #expect(try await result.value == [41, 42])
        #expect(await source.cursors() == [40, 41])
    }

    @Test func workspace_event_retry_backoff_is_exponential_and_bounded() {
        #expect(ServerSession.workspaceEventRetryDelayMilliseconds(failureCount: 1) == 250)
        #expect(ServerSession.workspaceEventRetryDelayMilliseconds(failureCount: 2) == 500)
        #expect(ServerSession.workspaceEventRetryDelayMilliseconds(failureCount: 5) == 4_000)
        #expect(ServerSession.workspaceEventRetryDelayMilliseconds(failureCount: 6) == 5_000)
        #expect(ServerSession.workspaceEventRetryDelayMilliseconds(failureCount: 20) == 5_000)
    }

    @Test func concurrent_workspace_summary_hydration_is_coalesced() async throws {
        let loader = SuspendedSummaryLoader()
        let session = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token"),
            workspaceEventCursor: { 0 },
            workspaceEventStream: { _ in AsyncThrowingStream { $0.finish() } },
            workspaceEventSleep: { _ in },
            workspaceSummary: { await loader.loadWorkspace() },
            conversationSummaries: { projectID in
                await loader.loadConversations(projectID: projectID)
            }
        )
        let expected = WorkspaceSummaryProjection(
            projects: [try project("project-a")],
            agents: [try agent()]
        )

        async let first = session.loadWorkspaceSummary()
        async let second = session.loadWorkspaceSummary()
        await loader.waitForWorkspaceRequests(1)
        await loader.resumeWorkspace(returning: expected)

        #expect(try await first == expected)
        #expect(try await second == expected)
        #expect(await loader.workspaceRequestCount() == 1)
        #expect(try await session.loadWorkspaceSummary() == expected)
        #expect(await loader.workspaceRequestCount() == 1)
    }

    @Test func project_summary_cache_is_scoped_and_force_refresh_is_coalesced() async throws {
        let loader = SuspendedSummaryLoader()
        let session = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token"),
            workspaceEventCursor: { 0 },
            workspaceEventStream: { _ in AsyncThrowingStream { $0.finish() } },
            workspaceEventSleep: { _ in },
            workspaceSummary: { await loader.loadWorkspace() },
            conversationSummaries: { projectID in
                await loader.loadConversations(projectID: projectID)
            }
        )
        let firstA = [try conversation("session-a1", projectID: "project-a")]
        async let initialA = session.conversationSummaries(projectID: "project-a")
        await loader.waitForConversationRequests(1, projectID: "project-a")
        await loader.resumeConversations(projectID: "project-a", returning: firstA)
        #expect(try await initialA == firstA)
        #expect(try await session.conversationSummaries(projectID: "project-a") == firstA)
        #expect(await loader.conversationRequestCount(projectID: "project-a") == 1)

        let projectB = [try conversation("session-b1", projectID: "project-b")]
        async let initialB = session.conversationSummaries(projectID: "project-b")
        await loader.waitForConversationRequests(1, projectID: "project-b")
        await loader.resumeConversations(projectID: "project-b", returning: projectB)
        #expect(try await initialB == projectB)

        let refreshedA = [try conversation("session-a2", projectID: "project-a")]
        async let refreshA = session.conversationSummaries(
            projectID: "project-a",
            forceRefresh: true
        )
        async let sameRefreshA = session.conversationSummaries(
            projectID: "project-a",
            forceRefresh: true
        )
        await loader.waitForConversationRequests(2, projectID: "project-a")
        await loader.resumeConversations(projectID: "project-a", returning: refreshedA)

        #expect(try await refreshA == refreshedA)
        #expect(try await sameRefreshA == refreshedA)
        #expect(await loader.conversationRequestCount(projectID: "project-a") == 2)
    }

    @Test func workspace_events_invalidate_shared_resource_summaries_before_delivery() async throws {
        let projectID = "project-1"
        let firstSession = try conversation("session-1", projectID: projectID)
        let nextSession = try conversation("session-2", projectID: projectID)
        let firstTeam = try team("team-1", projectID: projectID, status: "active")
        let nextTeam = try team("team-1", projectID: projectID, status: "paused")
        let firstTerminal = try terminal("terminal-1", projectID: projectID, status: "running")
        let nextTerminal = try terminal("terminal-1", projectID: projectID, status: "exited")
        let loader = SequencedSummaryLoader(
            sessions: [[firstSession], [nextSession], [nextSession]],
            conversations: [projectID: [[firstSession], [nextSession], [nextSession]]],
            teams: [projectID: [[firstTeam], [nextTeam]]],
            terminals: [projectID: [[firstTerminal], [nextTerminal]]]
        )
        let source = ScriptedWorkspaceEventSource()
        let session = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token"),
            workspaceEventCursor: { 0 },
            workspaceEventStream: { cursor in await source.connect(after: cursor) },
            workspaceEventSleep: { _ in },
            sessionSummaries: { await loader.loadSessions() },
            conversationSummaries: { projectID in
                await loader.loadConversations(projectID: projectID)
            },
            teamSummaries: { projectID in await loader.loadTeams(projectID: projectID) },
            terminalSummaries: { projectID in await loader.loadTerminals(projectID: projectID) }
        )

        #expect(try await session.sessionSummaries() == [firstSession])
        #expect(try await session.conversationSummaries(projectID: projectID) == [firstSession])
        #expect(try await session.teamSummaries(projectID: projectID) == [firstTeam])
        #expect(try await session.terminalSummaries(projectID: projectID) == [firstTerminal])
        #expect(await loader.counts(projectID: projectID) == (1, 1, 1, 1))

        let stream = try await session.workspaceEvents()
        var iterator = stream.makeAsyncIterator()
        await source.waitForConnectionCount(1)
        await source.yield(
            try workspaceEvent(id: 1, kind: "session_updated", projectID: projectID),
            connection: 0
        )
        _ = try await iterator.next()

        #expect(try await session.sessionSummaries() == [nextSession])
        #expect(try await session.conversationSummaries(projectID: projectID) == [nextSession])
        #expect(await loader.counts(projectID: projectID) == (2, 2, 1, 1))

        await source.yield(
            try workspaceEvent(id: 2, kind: "team_task_updated", projectID: projectID),
            connection: 0
        )
        _ = try await iterator.next()
        #expect(try await session.teamSummaries(projectID: projectID) == [nextTeam])
        #expect(try await session.sessionSummaries() == [nextSession])
        #expect(try await session.conversationSummaries(projectID: projectID) == [nextSession])

        await source.yield(
            try workspaceEvent(id: 3, kind: "terminal_exited", projectID: projectID),
            connection: 0
        )
        _ = try await iterator.next()
        #expect(try await session.terminalSummaries(projectID: projectID) == [nextTerminal])
        #expect(await loader.counts(projectID: projectID) == (3, 3, 2, 2))
    }

    @Test func invalidated_in_flight_summary_cannot_overwrite_the_new_generation() async throws {
        let projectID = "project-1"
        let stale = [try conversation("session-stale", projectID: projectID)]
        let fresh = [try conversation("session-fresh", projectID: projectID)]
        let loader = SuspendedSummaryLoader()
        let source = ScriptedWorkspaceEventSource()
        let session = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token"),
            workspaceEventCursor: { 0 },
            workspaceEventStream: { cursor in await source.connect(after: cursor) },
            workspaceEventSleep: { _ in },
            conversationSummaries: { projectID in
                await loader.loadConversations(projectID: projectID)
            }
        )

        let staleRequest = Task {
            try await session.conversationSummaries(projectID: projectID)
        }
        await loader.waitForConversationRequests(1, projectID: projectID)

        let stream = try await session.workspaceEvents()
        var iterator = stream.makeAsyncIterator()
        await source.waitForConnectionCount(1)
        await source.yield(
            try workspaceEvent(id: 1, kind: "session_updated", projectID: projectID),
            connection: 0
        )
        _ = try await iterator.next()

        let freshRequest = Task {
            try await session.conversationSummaries(projectID: projectID)
        }
        await loader.waitForConversationRequests(2, projectID: projectID)
        await loader.resumeConversations(
            projectID: projectID,
            requestIndex: 1,
            returning: fresh
        )
        #expect(try await freshRequest.value == fresh)

        await loader.resumeConversations(projectID: projectID, returning: stale)
        #expect(try await staleRequest.value == stale)
        #expect(try await session.conversationSummaries(projectID: projectID) == fresh)
        #expect(await loader.conversationRequestCount(projectID: projectID) == 2)
    }
}
