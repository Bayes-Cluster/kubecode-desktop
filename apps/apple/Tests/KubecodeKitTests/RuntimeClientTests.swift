import Foundation
import Testing
@testable import KubecodeKit

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

@Suite(.serialized)
struct RuntimeClientTests {
    private func client() -> RuntimeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return RuntimeClient(
            origin: URL(string: "http://127.0.0.1:4123")!,
            token: "test-token",
            session: URLSession(configuration: configuration)
        )
    }

    @Test func discovery_is_public_and_decodes_protocol_metadata() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/.well-known/kubecode")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = #"{"protocol_version":1,"server_version":"0.1.1","api_base":"/api/v1","authentication":"bearer","capabilities":["projects"]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let discovery = try await client().discovery()
        #expect(discovery.protocolVersion == 1)
        #expect(discovery.capabilities == ["projects"])
    }

    @Test func sse_parser_treats_crlf_separator_as_an_event_boundary() throws {
        var parser = SSEEventDecoder<WorkspaceEvent>()
        let first = "id: 1\r\nevent: workspace_event\r\ndata: {\"id\":1,\"kind\":\"text_delta\",\"project_id\":\"p\",\"conversation_id\":\"c\",\"run_id\":\"r\",\"payload\":{\"text\":\"live\"},\"created_at\":\"now\"}\r\n\r\n"
        var event: WorkspaceEvent?
        for byte in first.utf8 { event = try parser.consume(byte) ?? event }

        #expect(event?.id == 1)
        #expect(event?.payload["text"]?.stringValue == "live")

        let second = "data: {\"id\":2,\"kind\":\"run_completed\",\"project_id\":\"p\",\"conversation_id\":\"c\",\"run_id\":\"r\",\"payload\":{},\"created_at\":\"now\"}\n\n"
        var secondEvent: WorkspaceEvent?
        for byte in second.utf8 { secondEvent = try parser.consume(byte) ?? secondEvent }
        #expect(secondEvent?.id == 2)
    }

    @Test func authenticated_requests_use_bearer_token_and_ignore_server_paths() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/projects")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let body = #"[{"id":"project-1","name":"Demo","path":"/secret/server/path","workspaces_enabled":false}]"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let projects = try await client().listProjects()
        #expect(projects == [Project(id: "project-1", name: "Demo", workspacesEnabled: false)])
    }

    @Test func project_assets_preserve_binary_data_and_relative_path_scope() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/projects/project-1/asset")
            #expect(request.url?.query == "path=docs/diagram%20one.png")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!,
                Data([0x89, 0x50, 0x4e, 0x47])
            )
        }

        let data = try await client().readAsset(
            projectID: "project-1",
            path: "docs/diagram one.png"
        )
        #expect(data == Data([0x89, 0x50, 0x4e, 0x47]))
    }

    @Test func project_path_authorization_is_scoped_to_an_existing_project() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/projects/project-1/authorize")
            #expect(request.httpMethod == "POST")
            let body = try #require(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]
            )
            #expect(body["path"] == "/Users/example/Downloads/Project")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client().authorizeProjectPath(
            projectID: "project-1",
            path: "/Users/example/Downloads/Project"
        )
    }

    @Test func structured_errors_remain_copyable_at_the_client_boundary() async throws {
        MockURLProtocol.handler = { request in
            let body = #"{"code":"revision_conflict","message":"File changed","stage":"write"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            let _: [Project] = try await client().listProjects()
            Issue.record("Expected APIError")
        } catch let error as APIError {
            #expect(error == APIError(code: "revision_conflict", message: "File changed", status: 409, stage: "write"))
        }
    }

    @Test func provider_native_state_and_mode_updates_preserve_agent_values() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                #expect(request.url?.path == "/api/v1/sessions/session-1/state")
                let body = #"{"capabilities":null,"available_commands":{"availableCommands":[{"name":"btw","description":"Ask a side question"}]},"current_mode":{"currentModeId":"plan","availableModes":[{"id":"plan","name":"Plan"}]},"config_options":null,"plan":null,"usage":null,"mode_access":{"can_change":true,"reason":null}}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            #expect(request.url?.path == "/api/v1/sessions/session-1/options")
            #expect(request.httpMethod == "PATCH")
            #expect(String(decoding: requestBody(request), as: UTF8.self).contains(#""value":"plan""#))
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        let runtime = client()
        let state = try await runtime.sessionState(conversationID: "session-1")
        #expect(state.availableCommands?.objectValue?["availableCommands"]?.arrayValue?.count == 1)
        #expect(state.currentMode?.objectValue?["currentModeId"]?.stringValue == "plan")
        try await runtime.setSessionMode(conversationID: "session-1", value: "plan")
    }

    @Test func conversation_run_listing_matches_browser_api_route() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/sessions/session-1/runs")
            #expect(request.httpMethod == "GET")
            let body = #"[{"id":"run-1","conversation_id":"session-1","project_id":"project-1","message":"Ship","status":"completed","permission_mode":"safe","error":null,"internal":false}]"#
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let runs = try await client().listRuns(conversationID: "session-1")
        #expect(runs.map(\.id) == ["run-1"])
        #expect(runs.first?.conversationID == "session-1")
    }

    @Test func team_draft_leader_configuration_precedes_team_start() async throws {
        var requests: [URLRequest] = []
        let draft = #"{"team":{"id":"team-1","project_id":"project-1","title":"Research","status":"draft","goal":"","leader_member_id":"leader-1","workspace":"shared"},"summary":{"running":0,"queued":0,"needs_attention":0,"done":0,"total_tasks":0},"members":[{"id":"leader-1","name":"Leader","role":"leader","status":"idle","conversation_id":"leader-session"}],"tasks":[],"attention":[],"leader_conversation":{"id":"leader-session","project_id":"project-1","agent_id":"claude_code","title":"Research","execution_mode":"shared","team_id":"team-1","team_role":"leader"}}"#
        let state = #"{"capabilities":null,"available_commands":null,"current_mode":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan"}]},"config_options":{"configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"sonnet","options":[{"value":"sonnet","name":"Sonnet"}]}]},"plan":null,"usage":null,"mode_access":{"can_change":true,"reason":null}}"#
        let active = draft.replacingOccurrences(of: #""status":"draft""#, with: #""status":"active""#)
        MockURLProtocol.handler = { request in
            requests.append(request)
            let body: String
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v1/projects/project-1/teams"):
                body = draft
            case ("GET", "/api/v1/sessions/leader-session/state"):
                body = state
            case ("PATCH", "/api/v1/sessions/leader-session/options"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            case ("POST", "/api/v1/teams/team-1/start"):
                body = active
            default:
                Issue.record("Unexpected route: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                body = "{}"
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let runtime = client()
        let created = try await runtime.createTeam(
            projectID: "project-1",
            agentID: .claudeCode,
            leaderName: "Leader",
            title: "Research"
        )
        let leaderID = try #require(created.leaderConversation?.id)
        _ = try await runtime.sessionState(conversationID: leaderID)
        try await runtime.setSessionMode(conversationID: leaderID, value: "plan")
        try await runtime.setSessionConfig(
            conversationID: leaderID,
            configID: "model",
            value: .string("sonnet")
        )
        _ = try await runtime.startTeam(
            id: created.id,
            input: StartTeamInput(
                goal: "Ship",
                acceptanceCriteria: ["Tests pass"],
                allowedAgentIDs: [.claudeCode]
            )
        )

        #expect(requests.map { $0.url?.path } == [
            "/api/v1/projects/project-1/teams",
            "/api/v1/sessions/leader-session/state",
            "/api/v1/sessions/leader-session/options",
            "/api/v1/sessions/leader-session/options",
            "/api/v1/teams/team-1/start",
        ])
        #expect(String(decoding: requestBody(requests[2]), as: UTF8.self).contains(#""kind":"mode""#))
        #expect(String(decoding: requestBody(requests[3]), as: UTF8.self).contains(#""config_id":"model""#))
        #expect(String(decoding: requestBody(requests[4]), as: UTF8.self).contains(#""goal":"Ship""#))
    }

    @Test func git_mutations_are_project_scoped_and_decode_the_new_status() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/projects/project-1/git/mutate")
            #expect(request.httpMethod == "POST")
            let body = String(decoding: requestBody(request), as: UTF8.self)
            #expect(body.contains(#""action":"stage""#))
            #expect(body.contains("README.md"))
            let response = #"{"is_repository":true,"branch":"main","files":[{"path":"README.md","index_status":"M","worktree_status":null}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(response.utf8))
        }

        let status = try await client().mutateGit(
            projectID: "project-1",
            action: .stage,
            paths: ["README.md"]
        )
        #expect(status.branch == "main")
        #expect(status.files.first?.indexStatus == "M")
    }

    @Test func session_interactions_use_runtime_protocol_routes() async throws {
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        let runtime = client()
        try await runtime.cancelRun(id: "run/1")
        try await runtime.resolvePermission(requestID: "permission 1", optionID: "allow_once")
        try await runtime.resolveElicitation(
            requestID: "question-1",
            content: ["branch": .string("main"), "force": .bool(false)]
        )
        try await runtime.setSessionConfig(
            conversationID: "session-1",
            configID: "effort",
            value: .string("high")
        )

        #expect(requests.map(\.httpMethod) == ["DELETE", "POST", "POST", "PATCH"])
        #expect(requests[0].url?.path == "/api/v1/runs/run/1")
        #expect(requests[1].url?.path == "/api/v1/permissions/permission 1")
        #expect(String(decoding: requestBody(requests[1]), as: UTF8.self).contains("allow_once"))
        #expect(requests[2].url?.path == "/api/v1/elicitations/question-1")
        #expect(String(decoding: requestBody(requests[2]), as: UTF8.self).contains(#""force":false"#))
        #expect(String(decoding: requestBody(requests[3]), as: UTF8.self).contains(#""kind":"config""#))
    }

    @Test func conversation_lifecycle_and_history_pagination_match_server_contract() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                #expect(request.url?.path == "/api/v1/sessions/session-1/history")
                #expect(request.url?.query == "before=cursor%201&limit=25")
                let body = #"{"runs":[],"events":{},"session_events":[{"conversation_id":"session-1","seq":7,"kind":"plan","payload":{},"created_at":"now"}],"next_cursor":null}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            #expect(request.url?.path == "/api/v1/sessions/session-1")
            #expect(request.httpMethod == "PATCH")
            let requestJSON = String(decoding: requestBody(request), as: UTF8.self)
            #expect(requestJSON.contains(#""manual_title":"Focused work""#))
            let body = #"{"id":"session-1","agent_session_id":"native-1","project_id":"project-1","agent_id":"claude_code","provider_session_id":null,"title":"Focused work","manual_title":"Focused work","agent_title":null,"archived":false,"latest_run_status":null,"execution_mode":"shared","workspace_path":null,"recreated_context":false}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let runtime = client()
        let history = try await runtime.history(conversationID: "session-1", before: "cursor 1", limit: 25)
        #expect(history.sessionEvents.first?.kind == "plan")
        let conversation = try await runtime.updateConversation(id: "session-1", manualTitle: "Focused work")
        #expect(conversation.agentSessionID == "native-1")
    }

    @Test func run_and_team_member_routes_match_browser_api_contract() async throws {
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            let path = request.url?.path ?? ""
            let body: String
            switch path {
            case "/api/v1/sessions/session-1/team-members":
                body = #"{"id":"member-1","project_id":"project-1","agent_session_id":"native-2","agent_id":"codex","provider_session_id":null,"title":"Codex","manual_title":null,"agent_title":"Codex","archived":false,"latest_run_status":null,"execution_mode":"worktree","workspace_path":"/tmp/worktree","recreated_context":false,"parent_conversation_id":"session-1","relationship":"team_member"}"#
            case "/api/v1/runs/run-1":
                body = #"{"id":"run-1","conversation_id":"session-1","project_id":"project-1","message":"Inspect","status":"completed","error":null,"permission_mode":null,"internal":false}"#
            case "/api/v1/runs/run-1/events":
                body = #"[{"run_id":"run-1","seq":2,"kind":"text_delta","payload":{"text":"done"},"created_at":"now"}]"#
            case "/api/v1/sessions/session-1/events":
                body = #"[{"conversation_id":"session-1","seq":3,"kind":"plan","payload":{},"created_at":"now"}]"#
            default:
                Issue.record("Unexpected route: \(path)")
                body = "[]"
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let runtime = client()
        let member = try await runtime.createTeamMember(
            conversationID: "session-1",
            agentID: .codex,
            isolated: true
        )
        let run = try await runtime.getRun(id: "run-1")
        let runEvents = try await runtime.listRunEvents(id: "run-1", after: 1)
        let sessionEvents = try await runtime.listSessionEvents(conversationID: "session-1", after: 2)

        #expect(member.id == "member-1")
        #expect(run.id == "run-1")
        #expect(runEvents.first?.payload["text"]?.stringValue == "done")
        #expect(sessionEvents.first?.kind == "plan")
        #expect(requests[0].httpMethod == "POST")
        #expect(String(decoding: requestBody(requests[0]), as: UTF8.self).contains(#""agent_id":"codex""#))
        #expect(String(decoding: requestBody(requests[0]), as: UTF8.self).contains(#""isolated":true"#))
        #expect(requests[2].url?.query == "after=1")
        #expect(requests[3].url?.query == "after=2")
    }

    @Test func workstation_mutations_remain_resource_scoped() async throws {
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            if request.url?.path.contains("/teams/") == true {
                let body = #"{"team":{"id":"team-1","project_id":"project-1","title":"Ship","status":"active","goal":"Finish"},"summary":{"running":0,"queued":0,"needs_attention":0,"done":1,"total_tasks":1},"members":[],"tasks":[],"attention":[]}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            if request.url?.path.hasSuffix("/git/commit") == true {
                let body = #"{"is_repository":true,"branch":"main","files":[]}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            if request.httpMethod == "PATCH", request.url?.path.contains("/terminals/") == true {
                let body = #"{"id":"term-1","project_id":"project-1","conversation_id":null,"title":"Build","kind":"regular","cols":80,"rows":24,"status":"running","exit_code":null,"signal":null}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        let runtime = client()
        try await runtime.createEntry(projectID: "project-1", path: "Sources/New.swift", kind: "file")
        try await runtime.renameEntry(projectID: "project-1", from: "old", to: "new")
        try await runtime.deleteEntry(projectID: "project-1", path: "old file")
        _ = try await runtime.commitGit(projectID: "project-1", message: "feat: native")
        _ = try await runtime.renameTerminal(id: "term-1", title: "Build")
        try await runtime.closeTerminal(id: "term-1")
        _ = try await runtime.cancelTeamTask(teamID: "team-1", taskID: "task-1", reason: "Superseded")

        #expect(requests[0].url?.path == "/api/v1/projects/project-1/entries")
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[2].url?.query == "path=old%20file")
        #expect(requests[3].url?.path == "/api/v1/projects/project-1/git/commit")
        #expect(requests[5].httpMethod == "DELETE")
        #expect(requests[6].url?.path == "/api/v1/teams/team-1/tasks/task-1/cancel")
    }

    @Test func workstation_parity_routes_are_typed_and_resource_scoped() async throws {
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            let path = request.url!.path
            let body: String
            switch path {
            case "/api/v1/filesystem/directories":
                body = #"{"path":"/workspace","parent":"/","entries":[{"name":"demo","path":"/workspace/demo","hidden":false}]}"#
            case "/api/v1/agents/refresh":
                body = #"[{"id":"claude_code","available":true,"version":"1","executable":"claude","error":null,"checked_at":1,"readiness":"ready","cli":{"status":"ready","executable":"claude","version":"1","source":"path","error_code":null,"detail":null},"adapter":{"kind":"bundled","status":"ready","executable":"adapter","version":null,"source":"known_location","error_code":null,"detail":null}}]"#
            case "/api/v1/projects/project-1/runs":
                body = "[]"
            case "/api/v1/projects/project-1/workspaces":
                body = #"{"id":"project-1","name":"Demo","workspaces_enabled":true}"#
            case "/api/v1/projects/project-1/workspaces/migration":
                if request.httpMethod == "GET" {
                    body = #"{"active_conversation_ids":[],"worktrees":[{"conversation_id":"session-1","title":"Work","path":"/private/worktree","dirty":true}]}"#
                } else {
                    body = #"{"project":{"id":"project-1","name":"Demo","workspaces_enabled":false},"exports":[{"conversation_id":"session-1","path":"/private/export.patch"}]}"#
                }
            case "/api/v1/projects/project-1/terminals":
                body = #"{"id":"terminal-1","project_id":"project-1","conversation_id":"session-1","title":"Claude Code","kind":"claude_code","cols":100,"rows":28,"status":"running","exit_code":null,"signal":null}"#
            case "/api/v1/sessions/session-1/promote-to-team":
                body = #"{"team":{"id":"team-1","project_id":"project-1","title":"Ship","status":"draft","goal":""},"summary":{"running":0,"queued":0,"needs_attention":0,"done":0,"total_tasks":0},"members":[],"tasks":[],"attention":[]}"#
            default:
                Issue.record("Unexpected route: \(path)")
                body = "{}"
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let runtime = client()
        let listing = try await runtime.listDirectories(path: "/workspace")
        let agents = try await runtime.refreshAgents()
        _ = try await runtime.listProjectRuns(projectID: "project-1")
        _ = try await runtime.setProjectWorkspaces(id: "project-1", enabled: true)
        let preview = try await runtime.workspaceMigration(projectID: "project-1")
        let migration = try await runtime.migrateProjectWorkspaces(
            projectID: "project-1",
            resolutions: [.init(conversationID: "session-1", strategy: .exportPatch)]
        )
        let terminal = try await runtime.createTerminal(
            projectID: "project-1",
            conversationID: "session-1",
            kind: .claudeCode
        )
        _ = try await runtime.promoteConversationToTeam(
            conversationID: "session-1",
            leaderName: "Leader",
            workspace: "worktree"
        )

        #expect(listing.entries.first?.name == "demo")
        #expect(agents.first?.adapter?.kind == "bundled")
        #expect(preview.worktrees.first?.dirty == true)
        #expect(migration.exports.first?.conversationID == "session-1")
        #expect(terminal.kind == .claudeCode)
        #expect(requests[0].url?.query == "path=/workspace")
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[3].httpMethod == "PATCH")
        #expect(String(decoding: requestBody(requests[3]), as: UTF8.self).contains(#""enabled":true"#))
        #expect(String(decoding: requestBody(requests[5]), as: UTF8.self).contains(#""strategy":"export_patch""#))
        #expect(String(decoding: requestBody(requests[6]), as: UTF8.self).contains(#""kind":"claude_code""#))
        #expect(String(decoding: requestBody(requests[7]), as: UTF8.self).contains(#""leader_name":"Leader""#))
    }

    @Test func team_control_mutations_use_typed_team_scoped_routes() async throws {
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            let body = #"{"team":{"id":"team-1","project_id":"project-1","title":"Research","status":"active","goal":"Ship"},"summary":{"running":0,"queued":0,"needs_attention":0,"done":0,"total_tasks":0},"members":[],"tasks":[],"attention":[]}"#
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let runtime = client()
        _ = try await runtime.assignTeamTask(teamID: "team-1", taskID: "task-1", memberID: "member-1")
        _ = try await runtime.retryTeamTask(teamID: "team-1", taskID: "task-1")
        _ = try await runtime.updateTeamSettings(
            id: "team-1",
            memberManagementPolicy: "auto",
            maxParallelRuns: 3
        )
        _ = try await runtime.removeTeamMember(teamID: "team-1", memberID: "member-1")

        #expect(requests.map(\.url?.path) == [
            "/api/v1/teams/team-1/tasks/task-1/assign",
            "/api/v1/teams/team-1/tasks/task-1/retry",
            "/api/v1/teams/team-1/settings",
            "/api/v1/teams/team-1/members/member-1",
        ])
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "PATCH", "DELETE"])
        #expect(String(decoding: requestBody(requests[0]), as: UTF8.self).contains(#""member_id":"member-1""#))
        let settingsBody = String(decoding: requestBody(requests[2]), as: UTF8.self)
        #expect(settingsBody.contains(#""member_management_policy":"auto""#))
        #expect(settingsBody.contains(#""max_parallel_runs":3"#))
    }

    @Test func terminal_kinds_map_to_provider_protocol_ids() {
        #expect(TerminalKind(agentID: .claudeCode) == .claudeCode)
        #expect(TerminalKind(agentID: .codex) == .codex)
        #expect(TerminalKind(agentID: .opencode) == .openCode)
        #expect(TerminalKind.claudeCode.rawValue == "claude_code")
        #expect(TerminalKind.openCode.rawValue == "opencode")
    }

    @Test func terminal_attachment_preserves_authentication_base_path_and_cursor() throws {
        let runtime = RuntimeClient(
            origin: URL(string: "https://example.test")!,
            basePath: "kubecode",
            token: "terminal-token"
        )

        let request = try runtime.terminalAttachmentRequest(
            projectID: "project one",
            terminalID: "terminal/two",
            cursor: 42
        )

        #expect(request.url?.scheme == "wss")
        let components = try #require(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })
        #expect(components.percentEncodedPath == "/kubecode/api/v1/projects/project%20one/terminals/terminal%2Ftwo/attach")
        #expect(request.url?.query == "cursor=42")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer terminal-token")
    }

    @Test func branch_revise_and_revision_history_use_the_session_turn_contract() async throws {
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/branch") {
                body = #"{"id":"branch-1","project_id":"project-1","agent_id":"claude_code","title":"Branch","execution_mode":"shared","read_only":false}"#
            } else if path.hasSuffix("/revise") {
                body = #"{"id":"revision-1","conversation_id":"session-1","snapshot_conversation_id":"snapshot-1","forked_at_run_id":"run-1","created_at":"now","workspace_restore":"kept","workspace_restore_reason":"workspace_changed"}"#
            } else {
                body = #"[{"id":"revision-1","conversation_id":"session-1","snapshot_conversation_id":"snapshot-1","forked_at_run_id":"run-1","created_at":"now","workspace_restore":"kept","workspace_restore_reason":"workspace_changed"}]"#
            }
            let status = path.hasSuffix("/revisions") ? 200 : 201
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let runtime = client()
        let branch = try await runtime.branchConversation(
            id: "session-1",
            runID: "run-1",
            restoreFiles: false
        )
        let revision = try await runtime.reviseConversation(id: "session-1", runID: "run-1")
        let revisions = try await runtime.listConversationRevisions(id: "session-1")

        #expect(branch.id == "branch-1")
        #expect(revision.workspaceRestoreReason == "workspace_changed")
        #expect(revisions.map(\.snapshotConversationID) == ["snapshot-1"])
        #expect(requests.map(\.url?.path) == [
            "/api/v1/sessions/session-1/turns/run-1/branch",
            "/api/v1/sessions/session-1/turns/run-1/revise",
            "/api/v1/sessions/session-1/revisions",
        ])
        #expect(String(decoding: requestBody(requests[0]), as: UTF8.self).contains(#""restore_files":false"#))
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[2].httpMethod == "GET")
    }
}
