import Foundation

public struct APIError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public let status: Int
    public let stage: String?

    public var errorDescription: String? { message }
}

private struct APIErrorBody: Decodable {
    let code: String?
    let message: String?
    let stage: String?
}

private struct CreateProjectBody: Encodable {
    let kind: String
    let path: String
}
private struct ProjectPathAuthorizationBody: Encodable { let path: String }
private struct ProjectWorkspacesBody: Encodable { let enabled: Bool }
private struct WorkspaceMigrationBody: Encodable { let resolutions: [WorkspaceMigrationResolution] }

private struct CreateConversationBody: Encodable {
    let agentID: AgentID
    let title: String?
    let providerSessionID: String?
    let agentTitle: String?
    let workspaceMode: String?

    enum CodingKeys: String, CodingKey {
        case title
        case agentID = "agent_id"
        case providerSessionID = "provider_session_id"
        case agentTitle = "agent_title"
        case workspaceMode = "workspace_mode"
    }
}
private struct CreateTeamMemberBody: Encodable {
    let agentID: AgentID
    let isolated: Bool

    enum CodingKeys: String, CodingKey {
        case isolated
        case agentID = "agent_id"
    }
}

private struct MessageBody: Encodable { let message: String }
private struct EmptyBody: Encodable {}
private struct WriteFileBody: Encodable { let content: String; let revision: String }
private struct CreateEntryBody: Encodable { let path: String; let kind: String }
private struct RenameEntryBody: Encodable { let from: String; let to: String }
private struct SessionModeBody: Encodable { let kind = "mode"; let value: String }
private struct SessionConfigBody: Encodable { let kind = "config"; let configID: String; let value: JSONValue
    enum CodingKeys: String, CodingKey { case kind, value; case configID = "config_id" }
}
private struct PermissionBody: Encodable { let optionID: String
    enum CodingKeys: String, CodingKey { case optionID = "option_id" }
}
private struct ElicitationBody: Encodable { let content: [String: JSONValue]? }
private struct SideQuestionBody: Encodable { let question: String }
private struct ConversationUpdateBody: Encodable { let manualTitle: String?
    enum CodingKeys: String, CodingKey { case manualTitle = "manual_title" }
}
private struct ConversationArchiveBody: Encodable { let archived: Bool }
private struct BranchBody: Encodable { let restoreFiles: Bool
    enum CodingKeys: String, CodingKey { case restoreFiles = "restore_files" }
}
private struct GitMutationBody: Encodable { let action: GitMutation; let paths: [String] }
private struct CommitBody: Encodable { let message: String }
private struct TerminalTitleBody: Encodable { let title: String }
private struct TeamTaskReasonBody: Encodable { let reason: String? }
private struct TeamTaskAssigneeBody: Encodable { let memberID: String
    enum CodingKeys: String, CodingKey { case memberID = "member_id" }
}
private struct TeamCompleteBody: Encodable { let finalSummary: String
    enum CodingKeys: String, CodingKey { case finalSummary = "final_summary" }
}
private struct TeamInputBody: Encodable { let answer: String }
private struct TeamSettingsBody: Encodable { let memberManagementPolicy: String; let maxParallelRuns: Int
    enum CodingKeys: String, CodingKey {
        case memberManagementPolicy = "member_management_policy"
        case maxParallelRuns = "max_parallel_runs"
    }
}
private struct TeamProposalBody: Encodable { let decision: String }
private struct CreateTeamBody: Encodable {
    let agentID: AgentID
    let leaderName: String
    let title: String?
    let workspace: String
    enum CodingKeys: String, CodingKey {
        case title, workspace
        case agentID = "agent_id"
        case leaderName = "leader_name"
    }
}
private struct PromoteTeamBody: Encodable {
    let leaderName: String
    let title: String?
    let workspace: String?
    enum CodingKeys: String, CodingKey {
        case title, workspace
        case leaderName = "leader_name"
    }
}
private struct CreateTerminalBody: Encodable {
    let kind: TerminalKind
    let cols: Int
    let rows: Int
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case kind, cols, rows
        case conversationID = "conversation_id"
    }
}

struct SSEEventDecoder<Value: Decodable> {
    private var buffer = Data()
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    mutating func consume(_ byte: UInt8) throws -> Value? {
        buffer.append(byte)
        let boundaryLength: Int?
        if buffer.count >= 4, buffer.suffix(4).elementsEqual([13, 10, 13, 10]) {
            boundaryLength = 4
        } else if buffer.count >= 2, buffer.suffix(2).elementsEqual([10, 10]) {
            boundaryLength = 2
        } else {
            boundaryLength = nil
        }
        guard let boundaryLength else { return nil }
        let frame = Data(buffer.dropLast(boundaryLength))
        buffer.removeAll(keepingCapacity: true)
        return try decode(frame)
    }

    mutating func finish() throws -> Value? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll(keepingCapacity: true) }
        return try decode(buffer)
    }

    private func decode(_ frame: some DataProtocol) throws -> Value? {
        let normalized = String(decoding: frame, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let dataLines = lines.compactMap { rawLine -> String? in
            guard rawLine.hasPrefix("data:") else { return nil }
            return String(rawLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !dataLines.isEmpty else { return nil }
        return try decoder.decode(Value.self, from: Data(dataLines.joined(separator: "\n").utf8))
    }
}

public struct RuntimeClient: Sendable {
    public let origin: URL
    public let basePath: String
    private let token: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(origin: URL, basePath: String = "", token: String, session: URLSession = .shared) {
        self.origin = origin
        self.basePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token
        self.session = session
    }

    public func discovery() async throws -> RuntimeDiscovery {
        try await request(path: "/.well-known/kubecode", authenticated: false)
    }

    public func listProjects() async throws -> [Project] { try await request(path: "/projects") }
    public func listAgents() async throws -> [AgentDescriptor] { try await request(path: "/agents") }
    public func listSessions() async throws -> [Conversation] { try await request(path: "/sessions") }

    public func listDirectories(path: String? = nil) async throws -> DirectoryListing {
        let query = path.map { "?path=\(queryEscaped($0))" } ?? ""
        return try await request(path: "/filesystem/directories\(query)")
    }

    public func refreshAgents() async throws -> [AgentDescriptor] {
        try await request(path: "/agents/refresh", method: "POST", body: EmptyBody())
    }

    public func registerProject(path: String, create: Bool = false) async throws -> Project {
        try await request(
            path: "/projects",
            method: "POST",
            body: CreateProjectBody(kind: create ? "create" : "import", path: path)
        )
    }

    public func unregisterProject(id: String) async throws {
        try await requestEmpty(path: "/projects/\(escaped(id))", method: "DELETE")
    }

    public func authorizeProjectPath(projectID: String, path: String) async throws {
        try await requestEmpty(
            path: projectPath(projectID) + "/authorize",
            method: "POST",
            body: ProjectPathAuthorizationBody(path: path)
        )
    }

    public func setProjectWorkspaces(id: String, enabled: Bool) async throws -> Project {
        try await request(
            path: projectPath(id) + "/workspaces",
            method: "PATCH",
            body: ProjectWorkspacesBody(enabled: enabled)
        )
    }

    public func workspaceMigration(projectID: String) async throws -> WorkspaceMigrationPreview {
        try await request(path: projectPath(projectID) + "/workspaces/migration")
    }

    public func migrateProjectWorkspaces(
        projectID: String,
        resolutions: [WorkspaceMigrationResolution]
    ) async throws -> WorkspaceMigrationResponse {
        try await request(
            path: projectPath(projectID) + "/workspaces/migration",
            method: "POST",
            body: WorkspaceMigrationBody(resolutions: resolutions)
        )
    }

    public func listConversations(projectID: String) async throws -> [Conversation] {
        try await request(path: projectPath(projectID) + "/sessions")
    }

    public func listProjectRuns(projectID: String) async throws -> [AgentRun] {
        try await request(path: projectPath(projectID) + "/runs")
    }

    public func createConversation(
        projectID: String,
        agentID: AgentID,
        title: String? = nil,
        providerSessionID: String? = nil,
        agentTitle: String? = nil,
        workspaceMode: String? = nil
    ) async throws -> Conversation {
        try await request(
            path: projectPath(projectID) + "/sessions",
            method: "POST",
            body: CreateConversationBody(
                agentID: agentID,
                title: title,
                providerSessionID: providerSessionID,
                agentTitle: agentTitle,
                workspaceMode: workspaceMode
            )
        )
    }

    public func startRun(projectID: String, conversationID: String, message: String) async throws -> AgentRun {
        try await request(
            path: projectPath(projectID) + "/sessions/\(escaped(conversationID))/runs",
            method: "POST",
            body: MessageBody(message: message)
        )
    }

    public func createTeamMember(
        conversationID: String,
        agentID: AgentID,
        isolated: Bool = false
    ) async throws -> Conversation {
        try await request(
            path: "/sessions/\(escaped(conversationID))/team-members",
            method: "POST",
            body: CreateTeamMemberBody(agentID: agentID, isolated: isolated)
        )
    }

    public func getRun(id: String) async throws -> AgentRun {
        try await request(path: "/runs/\(escaped(id))")
    }

    public func listRuns(conversationID: String) async throws -> [AgentRun] {
        try await request(path: "/sessions/\(escaped(conversationID))/runs")
    }

    public func listRunEvents(id: String, after sequence: Int = 0) async throws -> [AgentEvent] {
        try await request(path: "/runs/\(escaped(id))/events?after=\(sequence)")
    }

    public func listSessionEvents(
        conversationID: String,
        after sequence: Int = 0
    ) async throws -> [SessionEvent] {
        try await request(
            path: "/sessions/\(escaped(conversationID))/events?after=\(sequence)"
        )
    }

    public func history(
        conversationID: String,
        before: String? = nil,
        limit: Int = 50
    ) async throws -> ConversationHistoryPage {
        var values = ["limit=\(limit)"]
        if let before { values.insert("before=\(queryEscaped(before))", at: 0) }
        return try await request(path: "/sessions/\(escaped(conversationID))/history?\(values.joined(separator: "&"))")
    }

    public func sessionState(conversationID: String) async throws -> AgentSessionState {
        try await request(path: "/sessions/\(escaped(conversationID))/state")
    }

    public func setSessionMode(conversationID: String, value: String) async throws {
        try await requestEmpty(
            path: "/sessions/\(escaped(conversationID))/options",
            method: "PATCH",
            body: SessionModeBody(value: value)
        )
    }

    public func setSessionConfig(conversationID: String, configID: String, value: JSONValue) async throws {
        try await requestEmpty(
            path: "/sessions/\(escaped(conversationID))/options",
            method: "PATCH",
            body: SessionConfigBody(configID: configID, value: value)
        )
    }

    public func askSideQuestion(conversationID: String, question: String) async throws -> SideQuestionAccepted {
        try await request(
            path: "/sessions/\(escaped(conversationID))/side-questions",
            method: "POST",
            body: SideQuestionBody(question: question)
        )
    }

    public func cancelRun(id: String) async throws {
        try await requestEmpty(path: "/runs/\(escaped(id))", method: "DELETE")
    }

    public func resolvePermission(requestID: String, optionID: String) async throws {
        try await requestEmpty(
            path: "/permissions/\(escaped(requestID))",
            method: "POST",
            body: PermissionBody(optionID: optionID)
        )
    }

    public func resolveElicitation(requestID: String, content: [String: JSONValue]?) async throws {
        try await requestEmpty(
            path: "/elicitations/\(escaped(requestID))",
            method: "POST",
            body: ElicitationBody(content: content)
        )
    }

    public func updateConversation(id: String, manualTitle: String?) async throws -> Conversation {
        try await request(
            path: "/sessions/\(escaped(id))",
            method: "PATCH",
            body: ConversationUpdateBody(manualTitle: manualTitle)
        )
    }

    public func archiveConversation(id: String, archived: Bool) async throws -> Conversation {
        try await request(
            path: "/sessions/\(escaped(id))",
            method: "PATCH",
            body: ConversationArchiveBody(archived: archived)
        )
    }

    public func deleteConversation(id: String) async throws {
        try await requestEmpty(path: "/sessions/\(escaped(id))", method: "DELETE")
    }

    public func forkConversation(id: String) async throws -> Conversation {
        try await request(path: "/sessions/\(escaped(id))/fork", method: "POST", body: EmptyBody())
    }

    public func branchConversation(id: String, runID: String, restoreFiles: Bool = true) async throws -> Conversation {
        try await request(
            path: "/sessions/\(escaped(id))/turns/\(escaped(runID))/branch",
            method: "POST",
            body: BranchBody(restoreFiles: restoreFiles)
        )
    }

    public func reviseConversation(id: String, runID: String) async throws -> ConversationRevision {
        try await request(
            path: "/sessions/\(escaped(id))/turns/\(escaped(runID))/revise",
            method: "POST",
            body: EmptyBody()
        )
    }

    public func listConversationRevisions(id: String) async throws -> [ConversationRevision] {
        try await request(path: "/sessions/\(escaped(id))/revisions")
    }

    public func listProviderSessions(projectID: String, agentID: AgentID) async throws -> [ProviderSessionInfo] {
        try await request(path: projectPath(projectID) + "/agents/\(escaped(agentID.rawValue))/sessions")
    }

    public func listEntries(projectID: String, path: String = "") async throws -> [FileEntry] {
        try await request(path: projectPath(projectID) + "/entries?path=\(queryEscaped(path))")
    }

    public func readFile(projectID: String, path: String) async throws -> TextDocument {
        try await request(path: projectPath(projectID) + "/file?path=\(queryEscaped(path))")
    }

    public func writeFile(projectID: String, document: TextDocument) async throws -> TextDocument {
        try await request(
            path: projectPath(projectID) + "/file?path=\(queryEscaped(document.path))",
            method: "PUT",
            body: WriteFileBody(content: document.content, revision: document.revision)
        )
    }

    public func createEntry(projectID: String, path: String, kind: String) async throws {
        try await requestEmpty(
            path: projectPath(projectID) + "/entries",
            method: "POST",
            body: CreateEntryBody(path: path, kind: kind)
        )
    }

    public func renameEntry(projectID: String, from: String, to: String) async throws {
        try await requestEmpty(
            path: projectPath(projectID) + "/entries",
            method: "PATCH",
            body: RenameEntryBody(from: from, to: to)
        )
    }

    public func deleteEntry(projectID: String, path: String) async throws {
        try await requestEmpty(
            path: projectPath(projectID) + "/entries?path=\(queryEscaped(path))",
            method: "DELETE"
        )
    }

    public func gitStatus(projectID: String) async throws -> GitStatus {
        try await request(path: projectPath(projectID) + "/git/status")
    }

    public func initializeGit(projectID: String) async throws -> GitStatus {
        try await request(path: projectPath(projectID) + "/git/init", method: "POST", body: EmptyBody())
    }

    public func commitGit(projectID: String, message: String) async throws -> GitStatus {
        try await request(
            path: projectPath(projectID) + "/git/commit",
            method: "POST",
            body: CommitBody(message: message)
        )
    }

    public func gitDiff(projectID: String, path: String, staged: Bool) async throws -> String {
        struct Diff: Decodable { let diff: String }
        let response: Diff = try await request(
            path: projectPath(projectID) + "/git/diff?path=\(queryEscaped(path))&staged=\(staged)"
        )
        return response.diff
    }

    public func mutateGit(projectID: String, action: GitMutation, paths: [String]) async throws -> GitStatus {
        try await request(
            path: projectPath(projectID) + "/git/mutate",
            method: "POST",
            body: GitMutationBody(action: action, paths: paths)
        )
    }

    public func listTerminals(projectID: String) async throws -> [TerminalInfo] {
        try await request(path: projectPath(projectID) + "/terminals")
    }

    public func createTerminal(
        projectID: String,
        conversationID: String? = nil,
        kind: TerminalKind = .regular,
        cols: Int = 100,
        rows: Int = 28
    ) async throws -> TerminalInfo {
        try await request(
            path: projectPath(projectID) + "/terminals",
            method: "POST",
            body: CreateTerminalBody(
                kind: kind,
                cols: cols,
                rows: rows,
                conversationID: conversationID
            )
        )
    }

    public func closeTerminal(id: String) async throws {
        try await requestEmpty(path: "/terminals/\(escaped(id))", method: "DELETE")
    }

    public func renameTerminal(id: String, title: String) async throws -> TerminalInfo {
        try await request(
            path: "/terminals/\(escaped(id))",
            method: "PATCH",
            body: TerminalTitleBody(title: title)
        )
    }

    public func terminalConnection(
        projectID: String,
        terminalID: String,
        cursor: Int = 0
    ) throws -> TerminalConnection {
        let request = try terminalAttachmentRequest(
            projectID: projectID,
            terminalID: terminalID,
            cursor: cursor
        )
        return TerminalConnection(task: session.webSocketTask(with: request))
    }

    func terminalAttachmentRequest(
        projectID: String,
        terminalID: String,
        cursor: Int = 0
    ) throws -> URLRequest {
        var request = try makeRequest(
            path: projectPath(projectID)
                + "/terminals/\(escaped(terminalID))/attach?cursor=\(cursor)"
        )
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        return request
    }

    public func listTeams(projectID: String) async throws -> [TeamSnapshot] {
        try await request(path: projectPath(projectID) + "/teams")
    }

    public func createTeam(
        projectID: String,
        agentID: AgentID,
        leaderName: String,
        title: String?,
        workspace: String = "shared"
    ) async throws -> TeamSnapshot {
        try await request(
            path: projectPath(projectID) + "/teams",
            method: "POST",
            body: CreateTeamBody(
                agentID: agentID,
                leaderName: leaderName,
                title: title,
                workspace: workspace
            )
        )
    }

    public func promoteConversationToTeam(
        conversationID: String,
        leaderName: String,
        title: String? = nil,
        workspace: String? = nil
    ) async throws -> TeamSnapshot {
        try await request(
            path: "/sessions/\(escaped(conversationID))/promote-to-team",
            method: "POST",
            body: PromoteTeamBody(leaderName: leaderName, title: title, workspace: workspace)
        )
    }

    public func startTeam(id: String, input: StartTeamInput) async throws -> TeamSnapshot {
        try await request(path: "/teams/\(escaped(id))/start", method: "POST", body: input)
    }

    public func getTeam(id: String) async throws -> TeamSnapshot {
        try await request(path: "/teams/\(escaped(id))")
    }

    public func pauseTeam(id: String) async throws -> TeamSnapshot {
        try await request(path: "/teams/\(escaped(id))/pause", method: "POST", body: EmptyBody())
    }

    public func resumeTeam(id: String) async throws -> TeamSnapshot {
        try await request(path: "/teams/\(escaped(id))/resume", method: "POST", body: EmptyBody())
    }

    public func retryTeamTask(teamID: String, taskID: String) async throws -> TeamSnapshot {
        try await request(
            path: "/teams/\(escaped(teamID))/tasks/\(escaped(taskID))/retry",
            method: "POST",
            body: EmptyBody()
        )
    }

    public func cancelTeamTask(teamID: String, taskID: String, reason: String? = nil) async throws -> TeamSnapshot {
        try await request(
            path: "/teams/\(escaped(teamID))/tasks/\(escaped(taskID))/cancel",
            method: "POST",
            body: TeamTaskReasonBody(reason: reason)
        )
    }

    public func assignTeamTask(teamID: String, taskID: String, memberID: String) async throws -> TeamSnapshot {
        try await request(
            path: "/teams/\(escaped(teamID))/tasks/\(escaped(taskID))/assign",
            method: "POST",
            body: TeamTaskAssigneeBody(memberID: memberID)
        )
    }

    public func removeTeamMember(teamID: String, memberID: String) async throws -> TeamSnapshot {
        var request = try makeRequest(path: "/teams/\(escaped(teamID))/members/\(escaped(memberID))")
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(TeamSnapshot.self, from: data)
    }

    public func completeTeam(id: String, finalSummary: String) async throws -> TeamSnapshot {
        try await request(
            path: "/teams/\(escaped(id))/complete",
            method: "POST",
            body: TeamCompleteBody(finalSummary: finalSummary)
        )
    }

    public func resolveTeamUserInput(teamID: String, requestID: String, answer: String) async throws -> TeamSnapshot {
        try await request(
            path: "/teams/\(escaped(teamID))/attention/\(escaped(requestID))/resolve",
            method: "POST",
            body: TeamInputBody(answer: answer)
        )
    }

    public func updateTeamSettings(id: String, memberManagementPolicy: String, maxParallelRuns: Int) async throws -> TeamSnapshot {
        try await request(
            path: "/teams/\(escaped(id))/settings",
            method: "PATCH",
            body: TeamSettingsBody(
                memberManagementPolicy: memberManagementPolicy,
                maxParallelRuns: maxParallelRuns
            )
        )
    }

    public func resolveTeamProposal(teamID: String, proposalID: String, decision: String) async throws -> TeamSnapshot {
        try await request(
            path: "/teams/\(escaped(teamID))/proposals/\(escaped(proposalID))/decision",
            method: "POST",
            body: TeamProposalBody(decision: decision)
        )
    }

    public func workspaceEventCursor() async throws -> Int {
        struct Cursor: Decodable { let cursor: Int }
        let value: Cursor = try await request(path: "/events/cursor")
        return value.cursor
    }

    public func workspaceEvents(after cursor: Int) -> AsyncThrowingStream<WorkspaceEvent, Error> {
        eventStream(path: "/events?after=\(cursor)", as: WorkspaceEvent.self)
    }

    public func runEvents(id: String, after sequence: Int = 0) -> AsyncThrowingStream<AgentEvent, Error> {
        eventStream(path: "/runs/\(escaped(id))/events/stream?after=\(sequence)", as: AgentEvent.self)
    }

    private func eventStream<Value: Decodable & Sendable>(
        path: String,
        as type: Value.Type
    ) -> AsyncThrowingStream<Value, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var request = try makeRequest(path: path)
                    request.timeoutInterval = 60 * 60
                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response: response, data: nil)
                    var parser = SSEEventDecoder<Value>()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if let event = try parser.consume(byte) { continuation.yield(event) }
                    }
                    if let event = try parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request<T: Decodable>(path: String, authenticated: Bool = true) async throws -> T {
        var request = try makeRequest(path: path, authenticated: authenticated)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func request<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> T {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func requestEmpty(path: String, method: String) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func requestEmpty<Body: Encodable>(path: String, method: String, body: Body) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func makeRequest(path: String, authenticated: Bool = true) throws -> URLRequest {
        let prefix = basePath.isEmpty ? "" : "/\(basePath)"
        let apiPrefix = path.hasPrefix("/.well-known/") ? "" : "/api/v1"
        guard let url = URL(string: prefix + apiPrefix + path, relativeTo: origin)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { try? decoder.decode(APIErrorBody.self, from: $0) }
            throw APIError(
                code: body?.code ?? "request_failed",
                message: body?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                status: http.statusCode,
                stage: body?.stage
            )
        }
    }

    private func projectPath(_ id: String) -> String { "/projects/\(escaped(id))" }
    private func escaped(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    private func queryEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
