import Foundation
import Testing
import KubecodeCore
import KubecodeKit
import KubecodeMacRuntime
@testable import KubecodeApp

@Suite
struct WorkspaceNavigationIndexTests {
    @Test @MainActor func file_change_publishes_one_safe_path_scoped_markdown_invalidation() async throws {
        let model = AppModel(connections: MacConnectionManager())
        model.selectedProjectID = "project-1"
        let first = try decode(
            WorkspaceEvent.self,
            from: #"{"id":11,"kind":"file_changed","project_id":"project-1","conversation_id":null,"run_id":null,"payload":{"path":"docs/diagram.png"},"created_at":"now"}"#
        )

        await model.handleWorkspaceEvent(first)
        await model.handleWorkspaceEvent(first)
        #expect(model.markdownResourceInvalidation == .init(
            eventID: 11,
            projectID: "project-1",
            projectPath: "docs/diagram.png"
        ))

        let unrelated = try decode(
            WorkspaceEvent.self,
            from: #"{"id":12,"kind":"file_changed","project_id":"project-2","conversation_id":null,"run_id":null,"payload":{"path":"docs/diagram.png"},"created_at":"now"}"#
        )
        await model.handleWorkspaceEvent(unrelated)
        #expect(model.markdownResourceInvalidation?.eventID == 11)

        let unsafe = try decode(
            WorkspaceEvent.self,
            from: #"{"id":13,"kind":"file_changed","project_id":"project-1","conversation_id":null,"run_id":null,"payload":{"path":"../secret.png"},"created_at":"now"}"#
        )
        await model.handleWorkspaceEvent(unsafe)
        #expect(model.markdownResourceInvalidation?.eventID == 11)

        let stale = try decode(
            WorkspaceEvent.self,
            from: #"{"id":10,"kind":"file_changed","project_id":"project-1","conversation_id":null,"run_id":null,"payload":{"path":"docs/other.png"},"created_at":"now"}"#
        )
        await model.handleWorkspaceEvent(stale)
        #expect(model.markdownResourceInvalidation?.eventID == 11)
    }

    @Test func search_matches_projects_sessions_and_teams_across_projects() throws {
        let research = try project(id: "project-research", name: "Research Lab")
        let product = try project(id: "project-product", name: "Product")
        let catalogs = [
            WorkspaceNavigationCatalog(
                project: research,
                conversations: [try conversation(
                    id: "session-notes",
                    projectID: research.id,
                    title: "Experiment Notes",
                    status: "running"
                )],
                teams: []
            ),
            WorkspaceNavigationCatalog(
                project: product,
                conversations: [try conversation(
                    id: "session-research",
                    projectID: product.id,
                    title: "Research rollout",
                    status: nil
                )],
                teams: [try team(
                    id: "team-eval",
                    projectID: product.id,
                    title: "Evaluation",
                    goal: "Review research metrics",
                    status: "active",
                    attention: 0
                )]
            ),
        ]

        let results = WorkspaceNavigationIndex.search("research", catalogs: catalogs)

        #expect(Set(results.map(\.resourceID)) == Set([
            "project-research", "session-notes", "session-research", "team-eval",
        ]))
        #expect(results.allSatisfy { !$0.title.isEmpty && !$0.projectName.isEmpty })
    }

    @Test func search_is_diacritic_insensitive_and_bounded() throws {
        let project = try project(id: "project-1", name: "Résumé")
        let conversations = try (0..<140).map { index in
            try conversation(
                id: "session-\(index)",
                projectID: project.id,
                title: "Resume task \(index)",
                status: nil
            )
        }
        let catalog = WorkspaceNavigationCatalog(
            project: project,
            conversations: conversations,
            teams: []
        )

        let results = WorkspaceNavigationIndex.search("resume", catalogs: [catalog])

        #expect(results.count == WorkspaceNavigationIndex.maximumResults)
        #expect(results.first?.kind == .project)
    }

    @Test func attention_includes_actionable_sessions_and_team_counts_only() throws {
        let project = try project(id: "project-1", name: "Demo")
        let waiting = try conversation(
            id: "session-waiting",
            projectID: project.id,
            title: "Waiting Session",
            status: "waiting_permission"
        )
        let archived = try conversation(
            id: "session-archived",
            projectID: project.id,
            title: "Archived Session",
            status: "waiting_permission",
            archived: true
        )
        let running = try conversation(
            id: "session-running",
            projectID: project.id,
            title: "Running Session",
            status: "running"
        )
        let needsAttention = try team(
            id: "team-attention",
            projectID: project.id,
            title: "Review Team",
            goal: "Review results",
            status: "needs_attention",
            attention: 3
        )
        let catalog = WorkspaceNavigationCatalog(
            project: project,
            conversations: [waiting, archived, running],
            teams: [needsAttention]
        )

        let attention = WorkspaceNavigationIndex.attentionItems(catalogs: [catalog])

        #expect(attention.map(\.resourceID) == ["session-waiting", "team-attention"])
        #expect(attention.last?.attentionCount == 3)
    }

    @Test func project_attention_badges_sum_session_and_team_work() throws {
        let project = try project(id: "project-1", name: "Demo")
        let catalog = WorkspaceNavigationCatalog(
            project: project,
            conversations: [try conversation(
                id: "session-waiting",
                projectID: project.id,
                title: "Waiting Session",
                status: "waiting_permission"
            )],
            teams: [try team(
                id: "team-attention",
                projectID: project.id,
                title: "Review Team",
                goal: "Review results",
                status: "needs_attention",
                attention: 3
            )]
        )

        let counts = WorkspaceNavigationIndex.attentionCountsByProject(catalogs: [catalog])

        #expect(counts == [project.id: 4])
    }

    @Test func only_summary_changing_events_refresh_global_navigation() {
        for kind in [
            "run_started", "run_completed", "permission_requested", "permission_resolved",
            "elicitation_requested", "elicitation_resolved", "session_info", "team_task_updated",
        ] {
            #expect(WorkspaceNavigationIndex.eventChangesNavigation(kind), "Expected \(kind) to refresh")
        }
        for kind in ["text_delta", "thinking_delta", "tool_updated", "usage", "plan"] {
            #expect(!WorkspaceNavigationIndex.eventChangesNavigation(kind), "Unexpected refresh for \(kind)")
        }
    }

    @Test @MainActor func navigation_results_open_loaded_sessions_and_teams() throws {
        let project = try project(id: "project-1", name: "Demo")
        let conversation = try conversation(
            id: "session-1",
            projectID: project.id,
            title: "Session Result",
            status: nil
        )
        let team = try team(
            id: "team-1",
            projectID: project.id,
            title: "Team Result",
            goal: "Ship",
            status: "active",
            attention: 0
        )
        let model = AppModel(connections: MacConnectionManager())
        model.projects = [project]
        model.selectedProjectID = project.id
        model.conversations = [conversation]
        model.teams = [team]
        let catalog = WorkspaceNavigationCatalog(
            project: project,
            conversations: [conversation],
            teams: [team]
        )
        let sessionItem = try #require(
            WorkspaceNavigationIndex.search("Session Result", catalogs: [catalog]).first
        )
        let teamItem = try #require(
            WorkspaceNavigationIndex.search("Team Result", catalogs: [catalog]).first
        )

        model.openNavigationItem(sessionItem)
        #expect(model.selectedConversationID == conversation.id)
        model.openNavigationItem(teamItem)
        #expect(model.selectedTeamID == team.id)
        #expect(model.selectedConversationID == nil)
    }

    @Test @MainActor func local_projects_use_native_folder_authorization_but_remote_projects_do_not() throws {
        let suite = "ProjectPickerRoutingTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ServerProfileStore(defaults: defaults)
        let remote = ServerProfile(
            name: "Remote",
            mode: .httpsAttached,
            url: URL(string: "https://runtime.example")
        )
        try profiles.upsert(remote)
        let access = ProjectAccessStore(defaults: defaults)
        let model = AppModel(connections: MacConnectionManager(
            profiles: profiles,
            projectAccess: access
        ))
        let project = try project(id: "project-native", name: "Native")

        #expect(model.isLocalManagedConnection)
        #expect(model.projectNeedsFolderAccess(project))

        model.currentServerProfileID = remote.id
        #expect(!model.isLocalManagedConnection)
        #expect(!model.projectNeedsFolderAccess(project))
    }

    private func project(id: String, name: String) throws -> Project {
        try decode(Project.self, from: """
        {"id":"\(id)","name":"\(name)","workspaces_enabled":false}
        """)
    }

    private func conversation(
        id: String,
        projectID: String,
        title: String,
        status: String?,
        archived: Bool = false
    ) throws -> Conversation {
        let statusJSON = status.map { "\"\($0)\"" } ?? "null"
        return try decode(Conversation.self, from: """
        {
            "id":"\(id)","project_id":"\(projectID)","agent_id":"codex",
            "title":"\(title)","execution_mode":"default","archived":\(archived),
            "latest_run_status":\(statusJSON)
        }
        """)
    }

    private func team(
        id: String,
        projectID: String,
        title: String,
        goal: String,
        status: String,
        attention: Int
    ) throws -> TeamSnapshot {
        try decode(TeamSnapshot.self, from: """
        {
            "team":{
                "id":"\(id)","project_id":"\(projectID)","title":"\(title)",
                "status":"\(status)","goal":"\(goal)"
            },
            "summary":{
                "running":0,"queued":0,"needs_attention":\(attention),"done":0,"total_tasks":0
            },
            "members":[],"tasks":[],"attention":[]
        }
        """)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

private final class NavigationURLProtocol: URLProtocol, @unchecked Sendable {
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
struct WorkspaceNavigationEventTests {
    @Test func cross_project_permission_event_refreshes_global_attention() async throws {
        NavigationURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            switch path {
            case "/api/v1/sessions":
                body = """
                [
                  {"id":"session-local","project_id":"project-1","agent_id":"claude_code","title":"Local","execution_mode":"shared","latest_run_status":"running"},
                  {"id":"session-remote","project_id":"project-2","agent_id":"codex","title":"Remote Approval","execution_mode":"shared","latest_run_status":"waiting_permission"}
                ]
                """
            case "/api/v1/projects/project-2/sessions":
                body = """
                [{"id":"session-remote","project_id":"project-2","agent_id":"codex","title":"Remote Approval","execution_mode":"shared","latest_run_status":"waiting_permission"}]
                """
            case "/api/v1/projects/project-1/teams", "/api/v1/projects/project-2/teams":
                body = "[]"
            case "/api/v1/projects/project-2/terminals":
                body = "[]"
            case "/api/v1/sessions/session-remote/history":
                body = #"{"runs":[],"events":{},"next_cursor":null,"session_events":[]}"#
            case "/api/v1/sessions/session-remote/state":
                body = #"{"capabilities":null,"available_commands":null,"current_mode":null,"config_options":null,"plan":null,"usage":null,"mode_access":{"can_change":true,"reason":null}}"#
            case "/api/v1/sessions/session-remote/revisions":
                body = "[]"
            default:
                throw URLError(.unsupportedURL)
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NavigationURLProtocol.self]
        let client = RuntimeClient(
            origin: URL(string: "http://127.0.0.1:4123")!,
            token: "test-token",
            session: URLSession(configuration: configuration)
        )
        let model = AppModel(
            connections: MacConnectionManager(),
            serverSession: ServerSession(client: client)
        )
        model.projects = [
            try decode(Project.self, from: #"{"id":"project-1","name":"Local Project","workspaces_enabled":false}"#),
            try decode(Project.self, from: #"{"id":"project-2","name":"Remote Project","workspaces_enabled":false}"#),
        ]
        model.selectedProjectID = "project-1"
        model.conversations = [try decode(Conversation.self, from: #"{"id":"session-local","project_id":"project-1","agent_id":"claude_code","title":"Local","execution_mode":"shared","latest_run_status":"running"}"#)]
        let event = try decode(WorkspaceEvent.self, from: #"{"id":9,"kind":"permission_requested","project_id":"project-2","conversation_id":"session-remote","run_id":"run-2","payload":{},"created_at":"now"}"#)

        await model.handleWorkspaceEvent(event)
        try await waitUntil { model.navigationAttentionItems.count == 1 }

        #expect(model.navigationAttentionItems.first?.resourceID == "session-remote")
        #expect(model.navigationAttentionCount(projectID: "project-2") == 1)
        #expect(model.totalNavigationAttentionCount == 1)

        model.openNavigationItem(try #require(model.navigationAttentionItems.first))
        try await waitUntil {
            model.selectedProjectID == "project-2"
                && model.selectedConversationID == "session-remote"
        }
        #expect(model.selectedProject?.name == "Remote Project")
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { Issue.record("Global navigation catalog did not refresh") }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
