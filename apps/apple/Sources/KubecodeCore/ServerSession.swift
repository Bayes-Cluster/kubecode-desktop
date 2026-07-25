import Foundation
import KubecodeKit

private struct SummaryLoad<Value: Sendable>: Sendable {
    let id = UUID()
    let task: Task<Value, Error>
}

public actor ServerSession {
    public nonisolated let id: UUID
    public nonisolated let client: RuntimeClient

    typealias WorkspaceEventCursorLoader = @Sendable () async throws -> Int
    typealias WorkspaceEventStreamFactory = @Sendable (
        Int
    ) async throws -> AsyncThrowingStream<WorkspaceEvent, Error>
    typealias WorkspaceEventSleep = @Sendable (Int) async -> Void
    typealias WorkspaceSummaryLoader = @Sendable () async throws -> WorkspaceSummaryProjection
    typealias SessionSummaryLoader = @Sendable () async throws -> [Conversation]
    typealias ConversationSummaryLoader = @Sendable (String) async throws -> [Conversation]
    typealias TeamSummaryLoader = @Sendable (String) async throws -> [TeamSnapshot]
    typealias TerminalSummaryLoader = @Sendable (String) async throws -> [TerminalInfo]

    private let workspaceEventCursorLoader: WorkspaceEventCursorLoader
    private let workspaceEventStreamFactory: WorkspaceEventStreamFactory
    private let workspaceEventSleep: WorkspaceEventSleep
    private let workspaceSummaryLoader: WorkspaceSummaryLoader
    private let sessionSummaryLoader: SessionSummaryLoader
    private let conversationSummaryLoader: ConversationSummaryLoader
    private let teamSummaryLoader: TeamSummaryLoader
    private let terminalSummaryLoader: TerminalSummaryLoader
    private var eventCursor: Int?
    private var eventCursorTask: Task<Int, Error>?
    private var workspaceEventSubscribers: [
        UUID: AsyncThrowingStream<WorkspaceEvent, Error>.Continuation
    ] = [:]
    private var workspaceEventTask: Task<Void, Never>?
    private var workspaceEventTaskGeneration: UUID?
    private var workspaceSummary: WorkspaceSummaryProjection?
    private var workspaceSummaryTask: SummaryLoad<WorkspaceSummaryProjection>?
    private var sessionSummary: [Conversation]?
    private var sessionSummaryTask: SummaryLoad<[Conversation]>?
    private var conversationSummariesByProject: [String: [Conversation]] = [:]
    private var conversationSummaryTasks: [String: SummaryLoad<[Conversation]>] = [:]
    private var teamSummariesByProject: [String: [TeamSnapshot]] = [:]
    private var teamSummaryTasks: [String: SummaryLoad<[TeamSnapshot]>] = [:]
    private var terminalSummariesByProject: [String: [TerminalInfo]] = [:]
    private var terminalSummaryTasks: [String: SummaryLoad<[TerminalInfo]>] = [:]

    public init(id: UUID = UUID(), client: RuntimeClient) {
        self.id = id
        self.client = client
        workspaceEventCursorLoader = { try await client.workspaceEventCursor() }
        workspaceEventStreamFactory = { cursor in client.workspaceEvents(after: cursor) }
        workspaceEventSleep = { milliseconds in
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
        workspaceSummaryLoader = {
            async let projects = client.listProjects()
            async let agents = client.listAgents()
            return try await WorkspaceSummaryProjection(projects: projects, agents: agents)
        }
        sessionSummaryLoader = { try await client.listSessions() }
        conversationSummaryLoader = { projectID in
            try await client.listConversations(projectID: projectID)
        }
        teamSummaryLoader = { projectID in
            try await client.listTeams(projectID: projectID)
        }
        terminalSummaryLoader = { projectID in
            try await client.listTerminals(projectID: projectID)
        }
    }

    init(
        id: UUID = UUID(),
        client: RuntimeClient,
        workspaceEventCursor: @escaping WorkspaceEventCursorLoader,
        workspaceEventStream: @escaping WorkspaceEventStreamFactory,
        workspaceEventSleep: @escaping WorkspaceEventSleep,
        workspaceSummary: WorkspaceSummaryLoader? = nil,
        sessionSummaries: SessionSummaryLoader? = nil,
        conversationSummaries: ConversationSummaryLoader? = nil,
        teamSummaries: TeamSummaryLoader? = nil,
        terminalSummaries: TerminalSummaryLoader? = nil
    ) {
        self.id = id
        self.client = client
        workspaceEventCursorLoader = workspaceEventCursor
        workspaceEventStreamFactory = workspaceEventStream
        self.workspaceEventSleep = workspaceEventSleep
        workspaceSummaryLoader = workspaceSummary ?? {
            async let projects = client.listProjects()
            async let agents = client.listAgents()
            return try await WorkspaceSummaryProjection(projects: projects, agents: agents)
        }
        sessionSummaryLoader = sessionSummaries ?? { try await client.listSessions() }
        conversationSummaryLoader = conversationSummaries ?? { projectID in
            try await client.listConversations(projectID: projectID)
        }
        teamSummaryLoader = teamSummaries ?? { projectID in
            try await client.listTeams(projectID: projectID)
        }
        terminalSummaryLoader = terminalSummaries ?? { projectID in
            try await client.listTerminals(projectID: projectID)
        }
    }

    public func discovery() async throws -> RuntimeDiscovery { try await client.discovery() }
    public func listProjects() async throws -> [Project] { try await client.listProjects() }
    public func listAgents() async throws -> [AgentDescriptor] { try await client.listAgents() }
    public func listSessions() async throws -> [Conversation] { try await client.listSessions() }

    public func loadWorkspaceSummary(
        forceRefresh: Bool = false
    ) async throws -> WorkspaceSummaryProjection {
        if let load = workspaceSummaryTask {
            do {
                let value = try await load.task.value
                if workspaceSummaryTask?.id == load.id {
                    workspaceSummary = value
                    workspaceSummaryTask = nil
                }
                return value
            } catch {
                if workspaceSummaryTask?.id == load.id { workspaceSummaryTask = nil }
                throw error
            }
        }
        if !forceRefresh, let workspaceSummary { return workspaceSummary }
        let loader = workspaceSummaryLoader
        let load = SummaryLoad(task: Task { try await loader() })
        workspaceSummaryTask = load
        do {
            let value = try await load.task.value
            if workspaceSummaryTask?.id == load.id {
                workspaceSummary = value
                workspaceSummaryTask = nil
            }
            return value
        } catch {
            if workspaceSummaryTask?.id == load.id { workspaceSummaryTask = nil }
            throw error
        }
    }

    public func sessionSummaries(forceRefresh: Bool = false) async throws -> [Conversation] {
        if let load = sessionSummaryTask {
            do {
                let value = try await load.task.value
                if sessionSummaryTask?.id == load.id {
                    sessionSummary = value
                    sessionSummaryTask = nil
                }
                return value
            } catch {
                if sessionSummaryTask?.id == load.id { sessionSummaryTask = nil }
                throw error
            }
        }
        if !forceRefresh, let sessionSummary { return sessionSummary }
        let loader = sessionSummaryLoader
        let load = SummaryLoad(task: Task { try await loader() })
        sessionSummaryTask = load
        do {
            let value = try await load.task.value
            if sessionSummaryTask?.id == load.id {
                sessionSummary = value
                sessionSummaryTask = nil
            }
            return value
        } catch {
            if sessionSummaryTask?.id == load.id { sessionSummaryTask = nil }
            throw error
        }
    }

    public func conversationSummaries(
        projectID: String,
        forceRefresh: Bool = false
    ) async throws -> [Conversation] {
        if let load = conversationSummaryTasks[projectID] {
            do {
                let value = try await load.task.value
                if conversationSummaryTasks[projectID]?.id == load.id {
                    conversationSummariesByProject[projectID] = value
                    conversationSummaryTasks[projectID] = nil
                }
                return value
            } catch {
                if conversationSummaryTasks[projectID]?.id == load.id {
                    conversationSummaryTasks[projectID] = nil
                }
                throw error
            }
        }
        if !forceRefresh, let value = conversationSummariesByProject[projectID] {
            return value
        }
        let loader = conversationSummaryLoader
        let load = SummaryLoad(task: Task { try await loader(projectID) })
        conversationSummaryTasks[projectID] = load
        do {
            let value = try await load.task.value
            if conversationSummaryTasks[projectID]?.id == load.id {
                conversationSummariesByProject[projectID] = value
                conversationSummaryTasks[projectID] = nil
            }
            return value
        } catch {
            if conversationSummaryTasks[projectID]?.id == load.id {
                conversationSummaryTasks[projectID] = nil
            }
            throw error
        }
    }

    public func teamSummaries(
        projectID: String,
        forceRefresh: Bool = false
    ) async throws -> [TeamSnapshot] {
        if let load = teamSummaryTasks[projectID] {
            do {
                let value = try await load.task.value
                if teamSummaryTasks[projectID]?.id == load.id {
                    teamSummariesByProject[projectID] = value
                    teamSummaryTasks[projectID] = nil
                }
                return value
            } catch {
                if teamSummaryTasks[projectID]?.id == load.id { teamSummaryTasks[projectID] = nil }
                throw error
            }
        }
        if !forceRefresh, let value = teamSummariesByProject[projectID] { return value }
        let loader = teamSummaryLoader
        let load = SummaryLoad(task: Task { try await loader(projectID) })
        teamSummaryTasks[projectID] = load
        do {
            let value = try await load.task.value
            if teamSummaryTasks[projectID]?.id == load.id {
                teamSummariesByProject[projectID] = value
                teamSummaryTasks[projectID] = nil
            }
            return value
        } catch {
            if teamSummaryTasks[projectID]?.id == load.id { teamSummaryTasks[projectID] = nil }
            throw error
        }
    }

    public func terminalSummaries(
        projectID: String,
        forceRefresh: Bool = false
    ) async throws -> [TerminalInfo] {
        if let load = terminalSummaryTasks[projectID] {
            do {
                let value = try await load.task.value
                if terminalSummaryTasks[projectID]?.id == load.id {
                    terminalSummariesByProject[projectID] = value
                    terminalSummaryTasks[projectID] = nil
                }
                return value
            } catch {
                if terminalSummaryTasks[projectID]?.id == load.id {
                    terminalSummaryTasks[projectID] = nil
                }
                throw error
            }
        }
        if !forceRefresh, let value = terminalSummariesByProject[projectID] { return value }
        let loader = terminalSummaryLoader
        let load = SummaryLoad(task: Task { try await loader(projectID) })
        terminalSummaryTasks[projectID] = load
        do {
            let value = try await load.task.value
            if terminalSummaryTasks[projectID]?.id == load.id {
                terminalSummariesByProject[projectID] = value
                terminalSummaryTasks[projectID] = nil
            }
            return value
        } catch {
            if terminalSummaryTasks[projectID]?.id == load.id {
                terminalSummaryTasks[projectID] = nil
            }
            throw error
        }
    }

    private func invalidateWorkspaceSummary() {
        workspaceSummary = nil
        workspaceSummaryTask = nil
    }

    private func invalidateConversationSummaries(projectID: String? = nil) {
        sessionSummary = nil
        sessionSummaryTask = nil
        if let projectID {
            conversationSummariesByProject[projectID] = nil
            conversationSummaryTasks[projectID] = nil
        } else {
            conversationSummariesByProject.removeAll()
            conversationSummaryTasks.removeAll()
        }
    }

    private func invalidateTeamSummaries(projectID: String? = nil) {
        if let projectID {
            teamSummariesByProject[projectID] = nil
            teamSummaryTasks[projectID] = nil
        } else {
            teamSummariesByProject.removeAll()
            teamSummaryTasks.removeAll()
        }
    }

    private func invalidateTerminalSummaries(projectID: String? = nil) {
        if let projectID {
            terminalSummariesByProject[projectID] = nil
            terminalSummaryTasks[projectID] = nil
        } else {
            terminalSummariesByProject.removeAll()
            terminalSummaryTasks.removeAll()
        }
    }

    private func invalidateSummaries(for event: WorkspaceEvent) {
        let kind = event.kind
        if kind.hasPrefix("project_") || kind.hasPrefix("agent_") {
            invalidateWorkspaceSummary()
        }
        if kind.hasPrefix("terminal_") {
            invalidateTerminalSummaries(projectID: event.projectID)
        }
        if kind.hasPrefix("team_") {
            invalidateTeamSummaries(projectID: event.projectID)
            invalidateConversationSummaries(projectID: event.projectID)
            return
        }
        if kind.hasPrefix("conversation_")
            || kind.hasPrefix("session_")
            || [
                "run_started", "run_completed",
                "permission_requested", "permission_resolved",
                "elicitation_requested", "elicitation_resolved",
            ].contains(kind) {
            invalidateConversationSummaries(projectID: event.projectID)
        }
    }

    public func listDirectories(path: String? = nil) async throws -> DirectoryListing {
        try await client.listDirectories(path: path)
    }
    public func refreshAgents() async throws -> [AgentDescriptor] {
        let agents = try await client.refreshAgents()
        workspaceSummaryTask = nil
        if let workspaceSummary {
            self.workspaceSummary = WorkspaceSummaryProjection(
                projects: workspaceSummary.projects,
                agents: agents
            )
        }
        return agents
    }

    public func registerProject(path: String, create: Bool = false) async throws -> Project {
        let project = try await client.registerProject(path: path, create: create)
        invalidateWorkspaceSummary()
        return project
    }

    public func unregisterProject(id: String) async throws {
        try await client.unregisterProject(id: id)
        invalidateWorkspaceSummary()
        invalidateConversationSummaries(projectID: id)
        invalidateTeamSummaries(projectID: id)
        invalidateTerminalSummaries(projectID: id)
    }
    public func authorizeProjectPath(projectID: String, path: String) async throws {
        try await client.authorizeProjectPath(projectID: projectID, path: path)
    }
    public func setProjectWorkspaces(id: String, enabled: Bool) async throws -> Project {
        let project = try await client.setProjectWorkspaces(id: id, enabled: enabled)
        invalidateWorkspaceSummary()
        invalidateConversationSummaries(projectID: id)
        return project
    }
    public func workspaceMigration(projectID: String) async throws -> WorkspaceMigrationPreview {
        try await client.workspaceMigration(projectID: projectID)
    }
    public func migrateProjectWorkspaces(
        projectID: String,
        resolutions: [WorkspaceMigrationResolution]
    ) async throws -> WorkspaceMigrationResponse {
        let response = try await client.migrateProjectWorkspaces(
            projectID: projectID,
            resolutions: resolutions
        )
        invalidateWorkspaceSummary()
        invalidateConversationSummaries(projectID: projectID)
        return response
    }

    public func listConversations(projectID: String) async throws -> [Conversation] {
        try await client.listConversations(projectID: projectID)
    }
    public func listProjectRuns(projectID: String) async throws -> [AgentRun] {
        try await client.listProjectRuns(projectID: projectID)
    }

    public func createConversation(
        projectID: String,
        agentID: AgentID,
        title: String? = nil,
        providerSessionID: String? = nil,
        agentTitle: String? = nil,
        workspaceMode: String? = nil
    ) async throws -> Conversation {
        let conversation = try await client.createConversation(
            projectID: projectID,
            agentID: agentID,
            title: title,
            providerSessionID: providerSessionID,
            agentTitle: agentTitle,
            workspaceMode: workspaceMode
        )
        invalidateConversationSummaries(projectID: projectID)
        return conversation
    }

    public func startRun(
        projectID: String,
        conversationID: String,
        message: String
    ) async throws -> AgentRun {
        let run = try await client.startRun(
            projectID: projectID,
            conversationID: conversationID,
            message: message
        )
        invalidateConversationSummaries(projectID: projectID)
        return run
    }

    public func createTeamMember(
        conversationID: String,
        agentID: AgentID,
        isolated: Bool = false
    ) async throws -> Conversation {
        let member = try await client.createTeamMember(
            conversationID: conversationID,
            agentID: agentID,
            isolated: isolated
        )
        invalidateConversationSummaries(projectID: member.projectID)
        return member
    }

    public func getRun(id: String) async throws -> AgentRun {
        try await client.getRun(id: id)
    }

    public func listRuns(conversationID: String) async throws -> [AgentRun] {
        try await client.listRuns(conversationID: conversationID)
    }

    public func listRunEvents(id: String, after sequence: Int = 0) async throws -> [AgentEvent] {
        try await client.listRunEvents(id: id, after: sequence)
    }

    public func listSessionEvents(
        conversationID: String,
        after sequence: Int = 0
    ) async throws -> [SessionEvent] {
        try await client.listSessionEvents(conversationID: conversationID, after: sequence)
    }

    public func history(conversationID: String, limit: Int = 50) async throws -> ConversationHistoryPage {
        try await client.history(conversationID: conversationID, limit: limit)
    }

    public func history(conversationID: String, before: String?, limit: Int = 50) async throws -> ConversationHistoryPage {
        try await client.history(conversationID: conversationID, before: before, limit: limit)
    }

    public func sessionState(conversationID: String) async throws -> AgentSessionState {
        try await client.sessionState(conversationID: conversationID)
    }

    public func setSessionMode(conversationID: String, value: String) async throws {
        try await client.setSessionMode(conversationID: conversationID, value: value)
    }

    public func setSessionConfig(conversationID: String, configID: String, value: JSONValue) async throws {
        try await client.setSessionConfig(conversationID: conversationID, configID: configID, value: value)
    }

    public func askSideQuestion(conversationID: String, question: String) async throws -> SideQuestionAccepted {
        try await client.askSideQuestion(conversationID: conversationID, question: question)
    }

    public func cancelRun(id: String) async throws {
        try await client.cancelRun(id: id)
        invalidateConversationSummaries()
    }
    public func resolvePermission(requestID: String, optionID: String) async throws {
        try await client.resolvePermission(requestID: requestID, optionID: optionID)
    }
    public func resolveElicitation(requestID: String, content: [String: JSONValue]?) async throws {
        try await client.resolveElicitation(requestID: requestID, content: content)
    }
    public func updateConversation(id: String, manualTitle: String?) async throws -> Conversation {
        let conversation = try await client.updateConversation(id: id, manualTitle: manualTitle)
        invalidateConversationSummaries(projectID: conversation.projectID)
        return conversation
    }
    public func archiveConversation(id: String, archived: Bool) async throws -> Conversation {
        let conversation = try await client.archiveConversation(id: id, archived: archived)
        invalidateConversationSummaries(projectID: conversation.projectID)
        return conversation
    }
    public func deleteConversation(id: String) async throws {
        try await client.deleteConversation(id: id)
        invalidateConversationSummaries()
        invalidateTeamSummaries()
    }
    public func forkConversation(id: String) async throws -> Conversation {
        let conversation = try await client.forkConversation(id: id)
        invalidateConversationSummaries(projectID: conversation.projectID)
        return conversation
    }
    public func branchConversation(
        id: String,
        runID: String,
        restoreFiles: Bool = true
    ) async throws -> Conversation {
        let conversation = try await client.branchConversation(
            id: id,
            runID: runID,
            restoreFiles: restoreFiles
        )
        invalidateConversationSummaries(projectID: conversation.projectID)
        return conversation
    }
    public func reviseConversation(id: String, runID: String) async throws -> ConversationRevision {
        let revision = try await client.reviseConversation(id: id, runID: runID)
        invalidateConversationSummaries()
        return revision
    }
    public func listConversationRevisions(id: String) async throws -> [ConversationRevision] {
        try await client.listConversationRevisions(id: id)
    }
    public func listProviderSessions(projectID: String, agentID: AgentID) async throws -> [ProviderSessionInfo] {
        try await client.listProviderSessions(projectID: projectID, agentID: agentID)
    }

    public func listEntries(projectID: String, path: String = "") async throws -> [FileEntry] {
        try await client.listEntries(projectID: projectID, path: path)
    }

    public func readFile(projectID: String, path: String) async throws -> TextDocument {
        try await client.readFile(projectID: projectID, path: path)
    }

    public func writeFile(projectID: String, document: TextDocument) async throws -> TextDocument {
        try await client.writeFile(projectID: projectID, document: document)
    }
    public func createEntry(projectID: String, path: String, kind: String) async throws {
        try await client.createEntry(projectID: projectID, path: path, kind: kind)
    }
    public func renameEntry(projectID: String, from: String, to: String) async throws {
        try await client.renameEntry(projectID: projectID, from: from, to: to)
    }
    public func deleteEntry(projectID: String, path: String) async throws {
        try await client.deleteEntry(projectID: projectID, path: path)
    }

    public func gitStatus(projectID: String) async throws -> GitStatus {
        try await client.gitStatus(projectID: projectID)
    }
    public func initializeGit(projectID: String) async throws -> GitStatus {
        try await client.initializeGit(projectID: projectID)
    }
    public func commitGit(projectID: String, message: String) async throws -> GitStatus {
        try await client.commitGit(projectID: projectID, message: message)
    }

    public func gitDiff(projectID: String, path: String, staged: Bool) async throws -> String {
        try await client.gitDiff(projectID: projectID, path: path, staged: staged)
    }

    public func mutateGit(
        projectID: String,
        action: GitMutation,
        paths: [String]
    ) async throws -> GitStatus {
        try await client.mutateGit(projectID: projectID, action: action, paths: paths)
    }

    public func listTerminals(projectID: String) async throws -> [TerminalInfo] {
        try await client.listTerminals(projectID: projectID)
    }

    public func createTerminal(
        projectID: String,
        conversationID: String? = nil,
        kind: TerminalKind = .regular,
        cols: Int = 100,
        rows: Int = 28
    ) async throws -> TerminalInfo {
        let terminal = try await client.createTerminal(
            projectID: projectID,
            conversationID: conversationID,
            kind: kind,
            cols: cols,
            rows: rows
        )
        invalidateTerminalSummaries(projectID: projectID)
        return terminal
    }
    public func closeTerminal(id: String) async throws {
        try await client.closeTerminal(id: id)
        invalidateTerminalSummaries()
    }
    public func renameTerminal(id: String, title: String) async throws -> TerminalInfo {
        let terminal = try await client.renameTerminal(id: id, title: title)
        invalidateTerminalSummaries(projectID: terminal.projectID)
        return terminal
    }

    public nonisolated func terminalConnection(
        projectID: String,
        terminalID: String,
        cursor: Int = 0
    ) throws -> TerminalConnection {
        try client.terminalConnection(projectID: projectID, terminalID: terminalID, cursor: cursor)
    }

    public nonisolated func runEvents(
        id: String,
        after sequence: Int = 0
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        client.runEvents(id: id, after: sequence)
    }

    public func listTeams(projectID: String) async throws -> [TeamSnapshot] {
        try await client.listTeams(projectID: projectID)
    }
    public func createTeam(
        projectID: String,
        agentID: AgentID,
        leaderName: String,
        title: String?,
        workspace: String = "shared"
    ) async throws -> TeamSnapshot {
        let team = try await client.createTeam(
            projectID: projectID,
            agentID: agentID,
            leaderName: leaderName,
            title: title,
            workspace: workspace
        )
        invalidateTeamMutation(team)
        return team
    }
    public func startTeam(id: String, input: StartTeamInput) async throws -> TeamSnapshot {
        let team = try await client.startTeam(id: id, input: input)
        invalidateTeamMutation(team)
        return team
    }
    public func getTeam(id: String) async throws -> TeamSnapshot { try await client.getTeam(id: id) }
    public func promoteConversationToTeam(
        conversationID: String,
        leaderName: String,
        title: String? = nil,
        workspace: String? = nil
    ) async throws -> TeamSnapshot {
        let team = try await client.promoteConversationToTeam(
            conversationID: conversationID,
            leaderName: leaderName,
            title: title,
            workspace: workspace
        )
        invalidateTeamMutation(team)
        return team
    }

    public func pauseTeam(id: String) async throws -> TeamSnapshot {
        let team = try await client.pauseTeam(id: id)
        invalidateTeamMutation(team)
        return team
    }
    public func resumeTeam(id: String) async throws -> TeamSnapshot {
        let team = try await client.resumeTeam(id: id)
        invalidateTeamMutation(team)
        return team
    }
    public func retryTeamTask(teamID: String, taskID: String) async throws -> TeamSnapshot {
        let team = try await client.retryTeamTask(teamID: teamID, taskID: taskID)
        invalidateTeamMutation(team)
        return team
    }
    public func cancelTeamTask(teamID: String, taskID: String, reason: String? = nil) async throws -> TeamSnapshot {
        let team = try await client.cancelTeamTask(teamID: teamID, taskID: taskID, reason: reason)
        invalidateTeamMutation(team)
        return team
    }
    public func assignTeamTask(teamID: String, taskID: String, memberID: String) async throws -> TeamSnapshot {
        let team = try await client.assignTeamTask(teamID: teamID, taskID: taskID, memberID: memberID)
        invalidateTeamMutation(team)
        return team
    }
    public func removeTeamMember(teamID: String, memberID: String) async throws -> TeamSnapshot {
        let team = try await client.removeTeamMember(teamID: teamID, memberID: memberID)
        invalidateTeamMutation(team)
        return team
    }
    public func completeTeam(id: String, finalSummary: String) async throws -> TeamSnapshot {
        let team = try await client.completeTeam(id: id, finalSummary: finalSummary)
        invalidateTeamMutation(team)
        return team
    }
    public func resolveTeamUserInput(teamID: String, requestID: String, answer: String) async throws -> TeamSnapshot {
        let team = try await client.resolveTeamUserInput(
            teamID: teamID,
            requestID: requestID,
            answer: answer
        )
        invalidateTeamMutation(team)
        return team
    }
    public func updateTeamSettings(
        id: String,
        memberManagementPolicy: String,
        maxParallelRuns: Int
    ) async throws -> TeamSnapshot {
        let team = try await client.updateTeamSettings(
            id: id,
            memberManagementPolicy: memberManagementPolicy,
            maxParallelRuns: maxParallelRuns
        )
        invalidateTeamMutation(team)
        return team
    }
    public func resolveTeamProposal(
        teamID: String,
        proposalID: String,
        decision: String
    ) async throws -> TeamSnapshot {
        let team = try await client.resolveTeamProposal(
            teamID: teamID,
            proposalID: proposalID,
            decision: decision
        )
        invalidateTeamMutation(team)
        return team
    }

    private func invalidateTeamMutation(_ snapshot: TeamSnapshot) {
        invalidateTeamSummaries(projectID: snapshot.team.projectID)
        invalidateConversationSummaries(projectID: snapshot.team.projectID)
    }

    public func prepareEventCursor() async throws -> Int {
        if let eventCursor { return eventCursor }
        if let eventCursorTask {
            do {
                let cursor = try await eventCursorTask.value
                self.eventCursor = self.eventCursor ?? cursor
                self.eventCursorTask = nil
                return self.eventCursor ?? cursor
            } catch {
                self.eventCursorTask = nil
                throw error
            }
        }
        let loader = workspaceEventCursorLoader
        let task = Task { try await loader() }
        eventCursorTask = task
        do {
            let cursor = try await task.value
            eventCursor = cursor
            eventCursorTask = nil
            return cursor
        } catch {
            eventCursorTask = nil
            throw error
        }
    }

    public func workspaceEvents() async throws -> AsyncThrowingStream<WorkspaceEvent, Error> {
        _ = try await prepareEventCursor()
        let subscriberID = UUID()
        let pair = AsyncThrowingStream<WorkspaceEvent, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWorkspaceEventSubscriber(subscriberID) }
        }
        workspaceEventSubscribers[subscriberID] = pair.continuation
        startWorkspaceEventTaskIfNeeded()
        return pair.stream
    }

    private func startWorkspaceEventTaskIfNeeded() {
        guard workspaceEventTask == nil, !workspaceEventSubscribers.isEmpty else { return }
        let generation = UUID()
        workspaceEventTaskGeneration = generation
        workspaceEventTask = Task { [weak self] in
            await self?.consumeWorkspaceEvents(generation: generation)
        }
    }

    private func consumeWorkspaceEvents(generation: UUID) async {
        var failureCount = 0
        while !Task.isCancelled, !workspaceEventSubscribers.isEmpty {
            do {
                let cursor = try await prepareEventCursor()
                let events = try await workspaceEventStreamFactory(cursor)
                for try await event in events {
                    try Task.checkCancellation()
                    guard event.id > (eventCursor ?? cursor) else { continue }
                    eventCursor = event.id
                    failureCount = 0
                    invalidateSummaries(for: event)
                    for continuation in workspaceEventSubscribers.values {
                        continuation.yield(event)
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
            }

            guard !Task.isCancelled, !workspaceEventSubscribers.isEmpty else { break }
            failureCount += 1
            await workspaceEventSleep(Self.workspaceEventRetryDelayMilliseconds(
                failureCount: failureCount
            ))
        }

        if workspaceEventTaskGeneration == generation {
            workspaceEventTask = nil
            workspaceEventTaskGeneration = nil
        }
    }

    private func removeWorkspaceEventSubscriber(_ id: UUID) {
        workspaceEventSubscribers[id] = nil
        guard workspaceEventSubscribers.isEmpty else { return }
        workspaceEventTask?.cancel()
        workspaceEventTask = nil
        workspaceEventTaskGeneration = nil
    }

    static func workspaceEventRetryDelayMilliseconds(failureCount: Int) -> Int {
        let exponent = min(max(failureCount - 1, 0), 5)
        return min(5_000, 250 * (1 << exponent))
    }
}
