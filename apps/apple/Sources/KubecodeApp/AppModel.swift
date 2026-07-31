import AppKit
import Foundation
import Observation
import KubecodeCore
import KubecodeKit
import KubecodeMarkdown
import KubecodeMacRuntime
import KubecodeUI

struct NativeCommand: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
}

struct NativeMode: Identifiable, Hashable {
    let id: String
    let name: String
    let value: JSONValue
    let controlID: String
    let controlKind: NativeSessionControlKind
}

struct NativeConfigChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let value: JSONValue
}

struct NativeConfig: Identifiable, Hashable {
    let id: String
    let name: String
    let currentValue: JSONValue?
    let choices: [NativeConfigChoice]
    let isBoolean: Bool
}

struct GitDiffDocument: Hashable {
    let path: String
    let staged: Bool
    let content: String
}

enum DocumentSaveFailure: Equatable {
    case revisionConflict(String)
    case other(String)

    init(code: String, message: String) {
        self = code == "revision_conflict" ? .revisionConflict(message) : .other(message)
    }

    init(error: Error) {
        if let error = error as? APIError {
            self.init(code: error.code, message: error.message)
        } else {
            self = .other(error.localizedDescription)
        }
    }
}

enum WindowDocumentSaveOutcome: Equatable {
    case saved
    case busy
    case failed
}

struct DocumentRevisionConflict: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let message: String
}

struct TerminalRestartDescriptor: Equatable {
    let projectID: String
    let conversationID: String?
    let title: String
    let kind: TerminalKind
    let cols: Int
    let rows: Int

    init(terminal: TerminalInfo) {
        projectID = terminal.projectID
        conversationID = terminal.conversationID
        title = terminal.title
        kind = terminal.kind
        cols = terminal.cols
        rows = terminal.rows
    }
}

enum TerminalCreationContext {
    static func conversationID(
        for kind: TerminalKind,
        selectedConversationID: String?
    ) -> String? {
        kind == .regular ? nil : selectedConversationID
    }
}

struct SessionSetupRequest: Identifiable, Equatable {
    let id = UUID()
    let agentID: AgentID

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentID == rhs.agentID
    }
}

struct MarkdownResourceInvalidation: Equatable {
    let eventID: Int
    let projectID: String
    let projectPath: String?
}

@MainActor
@Observable
final class AppModel {
    let connections: MacConnectionManager
    let projections: ServerProjectionStore
    var transcript: [TranscriptItem] = []
    var selectedProjectID: String?
    var selectedConversationID: String?
    var selectedTeamID: String?
    var isTerminalPanelPresented = false
    var isInspectorPresented = true
    var isTeamSetupPresented = false
    var currentServerProfileID: UUID?
    var currentServerName = "Local Runtime"
    var composer = "" {
        didSet { persistSelectedSessionDraft() }
    }
    var errorMessage: String?
    var isRefreshing = false
    var activeDocument: TextDocument?
    var nativeFindRequest = NativeFindRequest()
    var documentDraft = ""
    var openDocuments: [TextDocument] = []
    var documentDrafts: [String: String] = [:]
    private(set) var savingDocumentPaths: Set<String> = []
    var pendingDocumentClosePath: String?
    var documentRevisionConflict: DocumentRevisionConflict?
    var fileTree = ProjectFileTreeState()
    var fileTreeLoadingPaths: Set<String> = []
    var explorerSections = ExplorerSectionState()
    var activeDiff: GitDiffDocument?
    var commitMessage = ""
    var terminalWorkspace = TerminalWorkspaceState.empty
    var isCreatingTerminal = false
    var restartingTerminalIDs: Set<String> = []
    var sessionState: AgentSessionState?
    var runs: [AgentRun] = []
    var sessionEvents: [SessionEvent] = []
    var historyCursor: String?
    var isLoadingEarlierHistory = false
    var revisionState = SessionRevisionState()
    var isChangingRevision = false
    var interaction = AgentInteractionState()
    var elicitationAnswers: [String: JSONValue] = [:]
    var projectDirectoryListing: DirectoryListing?
    var providerSessions: [ProviderSessionInfo] = []
    var workspaceMigrationPreview: WorkspaceMigrationPreview?
    var navigationSearchQuery = ""
    var navigationSearchResults: [WorkspaceNavigationItem] = []
    var navigationAttentionItems: [WorkspaceNavigationItem] = []
    var isSearchingNavigation = false
    var isNavigationSearchPresented = false
    var isRefreshingNavigationCatalog = false
    var isLoadingProjectDirectory = false
    var isLoadingProviderSessions = false
    var isProjectBrowserPresented = false
    var sessionSetupRequest: SessionSetupRequest?
    var isQuickOpenPresented = false
    var isSearchingQuickOpen = false
    var quickOpenResults: [FileEntry] = []
    var isRunStreamReconnecting = false
    private(set) var markdownResourceInvalidation: MarkdownResourceInvalidation?
    private(set) var forcedReadOnlyConversationID: String?

    private var server: ServerSession?
    private var eventsTask: Task<Void, Never>?
    private var runEventsTask: Task<Void, Never>?
    private var runEventBridge: AgentEventDispatchBridge?
    private var directlyStreamedRunID: String?
    private var processedRunSequence = 0
    private var runStreamGeneration = 0
    private var quickOpenTask: Task<Void, Never>?
    private var navigationSearchTask: Task<Void, Never>?
    private var navigationCatalogTask: Task<Void, Never>?
    private var projectFilesTask: Task<Void, Never>?
    private var projectGitTask: Task<Void, Never>?
    private var navigationCatalogs: [WorkspaceNavigationCatalog] = []
    private let terminalWorkspaceStore: TerminalWorkspaceStore
    private let sessionDraftStore: SessionDraftStore
    private let notificationCoordinator: WorkspaceNotificationCoordinator?
    private var windowPersistenceID = UUID().uuidString
    private var terminalWorkspaceProjectID: String?
    private var isRestoringSessionDraft = false
    private var latestMarkdownResourceEventID: Int?

    init(
        connections: MacConnectionManager,
        projections: ServerProjectionStore = ServerProjectionStore(),
        terminalWorkspaceStore: TerminalWorkspaceStore = TerminalWorkspaceStore(),
        sessionDraftStore: SessionDraftStore = SessionDraftStore(),
        serverSession: ServerSession? = nil,
        notificationCoordinator: WorkspaceNotificationCoordinator? = nil
    ) {
        self.connections = connections
        self.projections = projections
        self.terminalWorkspaceStore = terminalWorkspaceStore
        self.sessionDraftStore = sessionDraftStore
        self.notificationCoordinator = notificationCoordinator
        server = serverSession
    }

    var runtime: LocalRuntimeManager { connections.localRuntime }
    var isReady: Bool { server != nil }
    var projects: [Project] {
        get { projections.projects }
        set { projections.projects = newValue }
    }
    var agents: [AgentDescriptor] {
        get { projections.agents }
        set { projections.agents = newValue }
    }
    var conversations: [Conversation] {
        get { projections.conversations }
        set { projections.conversations = newValue }
    }
    var teams: [TeamSnapshot] {
        get { projections.teams }
        set { projections.teams = newValue }
    }
    var files: [FileEntry] {
        get { projections.files }
        set { projections.files = newValue }
    }
    var gitStatus: GitStatus? {
        get { projections.gitStatus }
        set { projections.gitStatus = newValue }
    }
    var terminals: [TerminalInfo] {
        get { projections.terminals }
        set { projections.terminals = newValue }
    }
    var selectedProject: Project? { projects.first { $0.id == selectedProjectID } }
    var markdownProjectResourceContext: MarkdownProjectResourceContext? {
        guard let selectedProjectID, let server else { return nil }
        return MarkdownProjectResourceContext(
            identity: "\(server.id.uuidString):\(selectedProjectID)",
            projectID: selectedProjectID,
            client: server.client
        )
    }
    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }
    var selectedConversationIsReadOnly: Bool {
        selectedConversation?.readOnly == true
            || selectedConversationID == forcedReadOnlyConversationID
            || revisionState.isViewingRevision
    }
    var revisions: [ConversationRevision] {
        get { revisionState.revisions }
        set { revisionState.replaceRevisions(newValue) }
    }
    var canReviseSelectedConversation: Bool {
        SessionRevisionPolicy.canRevise(
            isReadOnly: selectedConversation?.readOnly == true
                || selectedConversationID == forcedReadOnlyConversationID,
            isViewingRevision: revisionState.isViewingRevision,
            hasActiveRun: activeRun != nil
        ) && !isChangingRevision
    }
    var selectedTeam: TeamSnapshot? { teams.first { $0.id == selectedTeamID } }
    var agentPlanEntries: [AgentPlanEntry] {
        AgentPlanProjection.entries(from: sessionState?.plan)
    }
    var agentUsage: AgentUsage? {
        AgentUsageProjection.usage(from: sessionState?.usage)
    }
    var activeTerminalID: String? { terminalWorkspace.activeTerminalID }
    var activeTerminal: TerminalInfo? { terminals.first { $0.id == activeTerminalID } }
    var activeTerminalPanes: [TerminalInfo] {
        (terminalWorkspace.activeGroup?.layout.terminalIDs ?? []).compactMap { id in
            terminals.first { $0.id == id }
        }
    }
    var availableAgents: [AgentDescriptor] { agents.filter(\.available) }
    var canCreateTeam: Bool {
        selectedProject != nil && !availableAgents.isEmpty
    }
    var canToggleTerminalPanel: Bool {
        isTerminalPanelPresented || (selectedProject != nil && !isCreatingTerminal)
    }
    var canToggleInspector: Bool {
        selectedProject != nil
    }
    var serverProfiles: [ServerProfile] { connections.profiles.profiles }
    var nativeCommands: [NativeCommand] {
        let values = sessionState?.availableCommands?.objectValue?["availableCommands"]?.arrayValue ?? []
        let providerCommands: [NativeCommand] = values.compactMap { value in
            guard let command = value.objectValue,
                  let name = command["name"]?.stringValue,
                  !name.isEmpty
            else { return nil }
            return NativeCommand(
                name: name,
                description: command["description"]?.stringValue ?? ""
            )
        }
        return ComposerCapabilityProjection.commands(
            provider: providerCommands,
            includeClaudeSideQuestion: canAskSideQuestion
        )
    }
    var nativeModes: [NativeMode] {
        guard let control = nativeSessionControls.mode else { return [] }
        return control.choices.map { choice in
            NativeMode(
                id: choice.id,
                name: choice.name,
                value: choice.value,
                controlID: control.id,
                controlKind: control.kind
            )
        }
    }
    var currentNativeModeID: String? {
        nativeSessionControls.mode?.currentChoiceID
    }
    var nativeConfigs: [NativeConfig] {
        nativeSessionControls.configs.map { control in
            return NativeConfig(
                id: control.id,
                name: control.name,
                currentValue: control.currentValue,
                choices: control.choices.map { choice in
                    NativeConfigChoice(
                        id: "\(control.id)-\(choice.id)",
                        name: choice.name,
                        value: choice.value
                    )
                },
                isBoolean: control.isBoolean
            )
        }
    }
    var nativeSessionControls: NativeSessionControls {
        NativeSessionControlProjection.controls(from: sessionState)
    }
    var activeRun: AgentRun? {
        runs.last { ["running", "waiting_permission"].contains($0.status) }
    }
    var canAskSideQuestion: Bool {
        selectedConversation?.agentID == .claudeCode && activeRun != nil
            && sessionState?.capabilities?.objectValue?["_meta"]?.objectValue?["claudeCode"]?.objectValue?["sideQuestion"]?.boolValue == true
    }
    var activeDocumentIsDirty: Bool {
        guard let activeDocument else { return false }
        return isDocumentDirty(activeDocument)
    }
    var isSavingDocument: Bool { !savingDocumentPaths.isEmpty }
    var isLocalManagedConnection: Bool {
        guard let currentServerProfileID else { return true }
        return serverProfiles.first(where: { $0.id == currentServerProfileID })?.mode == .localManaged
    }
    var selectedProjectNeedsFolderAccess: Bool {
        selectedProject.map(projectNeedsFolderAccess) ?? false
    }
    var canUseSelectedProjectFiles: Bool {
        selectedProject != nil && !selectedProjectNeedsFolderAccess
    }
    var canSaveActiveDocument: Bool {
        canUseSelectedProjectFiles && activeDocumentIsDirty && !isSavingDocument
    }
    var totalNavigationAttentionCount: Int {
        navigationAttentionItems.reduce(0) { $0 + max(1, $1.attentionCount) }
    }

    func navigationAttentionCount(projectID: String) -> Int {
        navigationAttentionItems
            .filter { $0.projectID == projectID }
            .reduce(0) { $0 + max(1, $1.attentionCount) }
    }

    func projectNeedsFolderAccess(_ project: Project) -> Bool {
        isLocalManagedConnection && !connections.projectAccess.isAuthorized(projectID: project.id)
    }

    func start() async {
        guard server == nil else { return }
        do {
            server = try await connections.connectLocal()
            try await loadWorkspace()
            startWorkspaceEvents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect(to profile: ServerProfile?) {
        eventsTask?.cancel()
        stopRunEventStream()
        cancelProjectResourceLoads()
        Task {
            do {
                if let profile {
                    server = try await connections.connect(profile)
                    currentServerProfileID = profile.id
                    currentServerName = profile.name
                    var used = profile
                    used.lastUsedAt = Date()
                    try connections.profiles.upsert(used)
                } else {
                    server = try await connections.connectLocal()
                    currentServerProfileID = nil
                    currentServerName = "Local Runtime"
                }
                selectedProjectID = nil
                markdownResourceInvalidation = nil
                latestMarkdownResourceEventID = nil
                switchComposer(to: nil)
                selectedTeamID = nil
                projects = []
                agents = []
                conversations = []
                teams = []
                files = []
                fileTree.reset()
                fileTreeLoadingPaths = []
                terminals = []
                terminalWorkspace = .empty
                terminalWorkspaceProjectID = nil
                navigationCatalogTask?.cancel()
                navigationSearchTask?.cancel()
                navigationCatalogs = []
                navigationSearchQuery = ""
                navigationSearchResults = []
                navigationAttentionItems = []
                gitStatus = nil
                resetSessionPresentation()
                try await loadWorkspace()
                startWorkspaceEvents()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func refresh() async {
        guard server != nil else { return }
        do { try await loadWorkspace(forceRefresh: true) }
        catch { errorMessage = error.localizedDescription }
    }

    func selectProject(_ project: Project) {
        prepareProjectSelection(project)
        Task {
            do { try await loadProject(project.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func prepareProjectSelection(_ project: Project) {
        cancelQuickOpenSearch()
        cancelProjectResourceLoads()
        forcedReadOnlyConversationID = nil
        selectedProjectID = project.id
        markdownResourceInvalidation = nil
        latestMarkdownResourceEventID = nil
        switchComposer(to: nil)
        selectedTeamID = nil
        terminalWorkspace = .empty
        terminalWorkspaceProjectID = nil
        isTerminalPanelPresented = false
        transcript = []
        files = []
        gitStatus = nil
        activeDocument = nil
        openDocuments = []
        documentDrafts = [:]
        documentDraft = ""
        pendingDocumentClosePath = nil
        documentRevisionConflict = nil
        activeDiff = nil
        fileTree.reset()
        fileTreeLoadingPaths = []
        resetSessionPresentation()
    }

    func searchNavigation(_ query: String) {
        navigationSearchTask?.cancel()
        navigationSearchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            navigationSearchResults = []
            isSearchingNavigation = false
            return
        }
        isSearchingNavigation = true
        navigationSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            if navigationCatalogs.isEmpty { await refreshNavigationCatalog() }
            guard !Task.isCancelled, navigationSearchQuery == query else { return }
            navigationSearchResults = WorkspaceNavigationIndex.search(
                query,
                catalogs: navigationCatalogs
            )
            isSearchingNavigation = false
        }
    }

    func openNavigationItem(_ item: WorkspaceNavigationItem) {
        navigationSearchTask?.cancel()
        navigationSearchQuery = ""
        navigationSearchResults = []
        isSearchingNavigation = false
        guard let project = projects.first(where: { $0.id == item.projectID }) else { return }
        if selectedProjectID == project.id {
            openLoadedNavigationItem(item)
            return
        }
        prepareProjectSelection(project)
        Task {
            do {
                try await loadProject(project.id)
                guard selectedProjectID == project.id else { return }
                openLoadedNavigationItem(item)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func openLoadedNavigationItem(_ item: WorkspaceNavigationItem) {
        switch item.kind {
        case .project:
            break
        case .conversation:
            if let conversation = conversations.first(where: { $0.id == item.resourceID }) {
                selectConversation(conversation)
            }
        case .team:
            if let team = teams.first(where: { $0.id == item.resourceID }) {
                selectTeam(team)
            }
        }
    }

    func searchQuickOpen(
        _ query: String,
        includeHidden: Bool,
        includeIgnored: Bool,
        includeGenerated: Bool
    ) {
        quickOpenTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !selectedProjectNeedsFolderAccess,
              let projectID = selectedProjectID, let server else {
            quickOpenResults = []
            isSearchingQuickOpen = false
            return
        }

        isSearchingQuickOpen = true
        quickOpenTask = Task {
            do {
                let results = try await QuickOpenIndexer.search(
                    query: query,
                    includeHidden: includeHidden,
                    includeIgnored: includeIgnored,
                    includeGenerated: includeGenerated
                ) { path in
                    try await server.listEntries(projectID: projectID, path: path)
                }
                guard !Task.isCancelled else { return }
                quickOpenResults = results
                isSearchingQuickOpen = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isSearchingQuickOpen = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func openQuickOpenResult(_ entry: FileEntry) {
        isQuickOpenPresented = false
        cancelQuickOpenSearch()
        openFile(entry)
    }

    func cancelQuickOpenSearch() {
        quickOpenTask?.cancel()
        quickOpenTask = nil
        isSearchingQuickOpen = false
        quickOpenResults = []
    }

    func dismissQuickOpen() {
        cancelQuickOpenSearch()
        isQuickOpenPresented = false
    }

    func selectConversation(_ conversation: Conversation) {
        stopRunEventStream()
        forcedReadOnlyConversationID = nil
        revisionState.reset()
        switchComposer(to: conversation.id)
        selectedTeamID = nil
        activeDocument = nil
        activeDiff = nil
        Task { await loadTranscript(conversation.id) }
    }

    func selectTeam(_ team: TeamSnapshot) {
        forcedReadOnlyConversationID = nil
        selectedTeamID = team.id
        switchComposer(to: nil)
        activeDocument = nil
        activeDiff = nil
        resetSessionPresentation()
    }

    func clearActivitySelection() {
        selectedTeamID = nil
        switchComposer(to: nil)
        resetSessionPresentation()
    }

    func updateTeamLifecycle() {
        guard let selectedTeam, let server else { return }
        Task {
            do {
                let updated = if selectedTeam.team.status == "paused" {
                    try await server.resumeTeam(id: selectedTeam.id)
                } else {
                    try await server.pauseTeam(id: selectedTeam.id)
                }
                if let index = teams.firstIndex(where: { $0.id == updated.id }) {
                    teams[index] = updated
                }
                updateSelectedProjectNavigationCatalog()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func createTeamDraft(
        agentID: AgentID,
        leaderName: String,
        title: String,
        workspace: String
    ) async -> TeamSnapshot? {
        guard let projectID = selectedProjectID, let server else { return nil }
        do {
            let draft = try await server.createTeam(
                projectID: projectID,
                agentID: agentID,
                leaderName: leaderName,
                title: title.isEmpty ? nil : title,
                workspace: workspace
            )
            await reconcileTeamSetupProjection(draft, projectID: projectID, server: server)
            return teams.first(where: { $0.id == draft.id }) ?? draft
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func promoteConversationToTeamDraft(
        conversation: Conversation,
        leaderName: String,
        title: String,
        workspace: String
    ) async -> TeamSnapshot? {
        guard let projectID = selectedProjectID, let server else { return nil }
        do {
            let draft = try await server.promoteConversationToTeam(
                conversationID: conversation.id,
                leaderName: leaderName,
                title: title.isEmpty ? nil : title,
                workspace: workspace
            )
            await reconcileTeamSetupProjection(draft, projectID: projectID, server: server)
            return teams.first(where: { $0.id == draft.id }) ?? draft
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func loadSessionStateForSetup(conversationID: String) async -> AgentSessionState? {
        guard let server else { return nil }
        do {
            return try await server.sessionState(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateSessionControl(
        conversationID: String,
        control: NativeSessionControl,
        value: JSONValue
    ) async -> AgentSessionState? {
        guard let server else { return nil }
        do {
            switch control.kind {
            case .mode:
                guard let value = value.stringValue else { return nil }
                try await server.setSessionMode(conversationID: conversationID, value: value)
            case .config:
                try await server.setSessionConfig(
                    conversationID: conversationID,
                    configID: control.id,
                    value: value
                )
            }
            return try await server.sessionState(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func startTeamDraft(
        _ draft: TeamSnapshot,
        goal: String,
        acceptanceCriteria: [String],
        mode: String,
        allowedAgentIDs: [AgentID],
        maxTeammates: Int,
        maxParallelRuns: Int,
        maxReviewRounds: Int
    ) async -> TeamSnapshot? {
        guard let projectID = selectedProjectID, let server else { return nil }
        do {
            let started = try await server.startTeam(
                id: draft.id,
                input: StartTeamInput(
                    goal: goal,
                    acceptanceCriteria: acceptanceCriteria,
                    allowedAgentIDs: allowedAgentIDs,
                    mode: mode,
                    maxTeammates: maxTeammates,
                    maxParallelRuns: TeamSetupPolicy.parallelRuns(maxParallelRuns, limitedBy: maxTeammates),
                    maxReviewRounds: maxReviewRounds
                )
            )
            await reconcileTeamSetupProjection(started, projectID: projectID, server: server)
            selectTeam(teams.first(where: { $0.id == started.id }) ?? started)
            return started
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func reconcileTeamSetupProjection(
        _ snapshot: TeamSnapshot,
        projectID: String,
        server: ServerSession
    ) async {
        if let refreshed = try? await server.teamSummaries(projectID: projectID) {
            teams = refreshed
        } else if let index = teams.firstIndex(where: { $0.id == snapshot.id }) {
            teams[index] = snapshot
        } else {
            teams.append(snapshot)
        }
        if let refreshed = try? await server.conversationSummaries(projectID: projectID) {
            conversations = refreshed
        } else {
            let returned = ([snapshot.leaderConversation].compactMap { $0 })
                + (snapshot.conversations ?? [])
            for conversation in returned {
                replaceConversation(conversation)
            }
        }
        updateSelectedProjectNavigationCatalog()
    }

    func retryTeamTask(_ task: TeamTask) { mutateSelectedTeam { server, teamID in
        try await server.retryTeamTask(teamID: teamID, taskID: task.id)
    } }

    func cancelTeamTask(_ task: TeamTask) { mutateSelectedTeam { server, teamID in
        try await server.cancelTeamTask(teamID: teamID, taskID: task.id, reason: "Cancelled from macOS")
    } }

    func assignTeamTask(_ task: TeamTask, to member: TeamMember) { mutateSelectedTeam { server, teamID in
        try await server.assignTeamTask(teamID: teamID, taskID: task.id, memberID: member.id)
    } }

    func removeTeamMember(_ member: TeamMember) { mutateSelectedTeam { server, teamID in
        try await server.removeTeamMember(teamID: teamID, memberID: member.id)
    } }

    func updateSelectedTeamSettings(memberManagementPolicy: String, maxParallelRuns: Int) {
        mutateSelectedTeam { server, teamID in
            try await server.updateTeamSettings(
                id: teamID,
                memberManagementPolicy: memberManagementPolicy,
                maxParallelRuns: maxParallelRuns
            )
        }
    }

    func completeSelectedTeam(summary: String) { mutateSelectedTeam { server, teamID in
        try await server.completeTeam(id: teamID, finalSummary: summary)
    } }

    func resolveTeamUserInput(_ request: TeamUserInputRequest, answer: String) {
        mutateSelectedTeam { server, teamID in
            try await server.resolveTeamUserInput(teamID: teamID, requestID: request.id, answer: answer)
        }
    }

    func resolveTeamProposal(_ proposal: TeamProposal, decision: String) {
        mutateSelectedTeam { server, teamID in
            try await server.resolveTeamProposal(teamID: teamID, proposalID: proposal.id, decision: decision)
        }
    }

    func openTeamMember(_ member: TeamMember) {
        guard let conversation = conversations.first(where: { $0.id == member.conversationID })
            ?? selectedTeam?.conversations?.first(where: { $0.id == member.conversationID })
        else { return }
        selectConversation(conversation)
        forcedReadOnlyConversationID = conversation.id
    }

    private func mutateSelectedTeam(
        _ operation: @escaping @Sendable (ServerSession, String) async throws -> TeamSnapshot
    ) {
        guard let selectedTeamID, let server else { return }
        Task {
            do {
                let updated = try await operation(server, selectedTeamID)
                if let index = teams.firstIndex(where: { $0.id == updated.id }) { teams[index] = updated }
                let latestConversations = ([updated.leaderConversation].compactMap { $0 })
                    + (updated.conversations ?? [])
                if !latestConversations.isEmpty {
                    conversations = TeamConversationProjection.reconcile(
                        teamID: updated.id,
                        latest: latestConversations,
                        existing: conversations
                    )
                }
                updateSelectedProjectNavigationCatalog()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func insertNativeCommand(_ command: NativeCommand) {
        composer = ComposerCapabilityProjection.inserting("/\(command.name)", into: composer)
    }

    func insertComposerReference(_ entry: FileEntry) {
        composer = ComposerCapabilityProjection.inserting("@\(entry.path)", into: composer)
    }

    func setNativeMode(_ mode: NativeMode) {
        guard let conversationID = selectedConversationID, let server else { return }
        Task {
            do {
                switch mode.controlKind {
                case .mode:
                    guard let value = mode.value.stringValue else { return }
                    try await server.setSessionMode(conversationID: conversationID, value: value)
                case .config:
                    try await server.setSessionConfig(
                        conversationID: conversationID,
                        configID: mode.controlID,
                        value: mode.value
                    )
                }
                applySessionState(try await server.sessionState(conversationID: conversationID))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setNativeConfig(_ config: NativeConfig, choice: NativeConfigChoice) {
        setNativeConfig(config, value: choice.value)
    }

    func setNativeConfig(_ config: NativeConfig, value: JSONValue) {
        guard let conversationID = selectedConversationID, let server else { return }
        Task {
            do {
                try await server.setSessionConfig(
                    conversationID: conversationID,
                    configID: config.id,
                    value: value
                )
                applySessionState(try await server.sessionState(conversationID: conversationID))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func presentProjectRegistration() {
        if isLocalManagedConnection { chooseAndRegisterProject() }
        else { isProjectBrowserPresented = true }
    }

    func chooseAndRegisterProject() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Project folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let server else { return }
                let project = try await server.registerProject(path: url.path)
                try connections.projectAccess.authorize(projectID: project.id, url: url)
                try await loadWorkspace()
                selectProject(project)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func reauthorizeProject(_ project: Project) {
        guard isLocalManagedConnection else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Restore Project Folder Access")
        panel.prompt = String(localized: "Restore Access")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let server else { return }
                try await server.authorizeProjectPath(projectID: project.id, path: url.path)
                try connections.projectAccess.authorize(projectID: project.id, url: url)
                if selectedProjectID == project.id {
                    cancelProjectResourceLoads()
                    scheduleProjectResourceLoads(projectID: project.id)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func createDefaultSession() {
        guard let project = selectedProject,
              let agent = availableAgents.first
        else { return }
        createSession(agent: agent.id, projectID: project.id)
    }

    func presentSessionSetup(preferredAgent: AgentID? = nil) {
        guard selectedProject != nil else { return }
        let available = availableAgents.map(\.id)
        guard let agentID = if let preferredAgent, available.contains(preferredAgent) {
            preferredAgent
        } else if let selectedAgent = selectedConversation?.agentID,
                  available.contains(selectedAgent) {
            selectedAgent
        } else {
            available.first
        } else { return }
        sessionSetupRequest = SessionSetupRequest(agentID: agentID)
    }

    func createSession(
        agent: AgentID,
        projectID: String? = nil,
        workspaceMode: String = "shared",
        providerSession: ProviderSessionInfo? = nil
    ) {
        guard let projectID = projectID ?? selectedProjectID else { return }
        Task {
            do {
                guard let server else { return }
                let conversation = try await server.createConversation(
                    projectID: projectID,
                    agentID: agent,
                    providerSessionID: providerSession?.sessionID,
                    agentTitle: providerSession?.title,
                    workspaceMode: providerSession == nil ? workspaceMode : nil
                )
                try await loadProject(projectID)
                selectConversation(conversation)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func loadProviderSessions(agent: AgentID) async {
        guard let projectID = selectedProjectID, let server else { return }
        isLoadingProviderSessions = true
        defer { isLoadingProviderSessions = false }
        do { providerSessions = try await server.listProviderSessions(projectID: projectID, agentID: agent) }
        catch {
            providerSessions = []
            errorMessage = error.localizedDescription
        }
    }

    func loadProjectDirectories(path: String? = nil) async {
        guard let server else { return }
        isLoadingProjectDirectory = true
        defer { isLoadingProjectDirectory = false }
        do { projectDirectoryListing = try await server.listDirectories(path: path) }
        catch { errorMessage = error.localizedDescription }
    }

    func registerServerProject(path: String, create: Bool) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let server else { return }
        Task {
            do {
                let project = try await server.registerProject(path: value, create: create)
                try await loadWorkspace()
                selectProject(project)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func unregisterProject(_ project: Project) {
        guard let server else { return }
        Task {
            do {
                try await server.unregisterProject(id: project.id)
                connections.projectAccess.remove(projectID: project.id)
                projects.removeAll { $0.id == project.id }
                navigationCatalogs.removeAll { $0.project.id == project.id }
                refreshNavigationPresentation()
                if selectedProjectID == project.id {
                    selectedProjectID = nil
                    projections.clearProjectResources()
                    resetSessionPresentation()
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setWorkspacesEnabled(_ project: Project, enabled: Bool) {
        guard let server else { return }
        Task {
            do {
                let updated = try await server.setProjectWorkspaces(id: project.id, enabled: enabled)
                replaceProject(updated)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func loadWorkspaceMigration(projectID: String) async {
        guard let server else { return }
        do { workspaceMigrationPreview = try await server.workspaceMigration(projectID: projectID) }
        catch { errorMessage = error.localizedDescription }
    }

    func migrateWorkspaces(projectID: String, resolutions: [WorkspaceMigrationResolution]) {
        guard let server else { return }
        Task {
            do {
                let response = try await server.migrateProjectWorkspaces(
                    projectID: projectID,
                    resolutions: resolutions
                )
                replaceProject(response.project)
                conversations = try await server.conversationSummaries(projectID: projectID)
                updateSelectedProjectNavigationCatalog()
                workspaceMigrationPreview = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func sendMessage() {
        let message = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              let projectID = selectedProjectID,
              let conversationID = selectedConversationID,
              let server
        else { return }
        if activeRun != nil {
            guard canAskSideQuestion,
                  message.hasPrefix("/btw "),
                  !message.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            let question = String(message.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            composer = ""
            Task {
                do { _ = try await server.askSideQuestion(conversationID: conversationID, question: question) }
                catch {
                    restoreSentDraft(message, conversationID: conversationID)
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        composer = ""
        let pendingID = "pending-\(UUID())"
        transcript.append(TranscriptItem(
            id: pendingID,
            role: .user,
            text: message
        ))
        Task {
            do {
                let run = try await server.startRun(
                    projectID: projectID,
                    conversationID: conversationID,
                    message: message
                )
                runs.append(run)
                startRunEventStream(runID: run.id, after: 0)
                guard selectedConversationID == conversationID,
                      let index = transcript.firstIndex(where: { $0.id == pendingID })
                else { return }
                transcript[index] = TranscriptItem(
                    id: "run-\(run.id)-user",
                    role: .user,
                    text: message,
                    runID: run.id
                )
            } catch {
                transcript.removeAll { $0.id == pendingID }
                restoreSentDraft(message, conversationID: conversationID)
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelActiveRun() {
        guard let run = activeRun, let server else { return }
        Task {
            do { try await server.cancelRun(id: run.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func selectRevision(at index: Int) {
        guard let logicalConversationID = selectedConversationID,
              (0..<revisionState.totalPositions).contains(index),
              index != revisionState.activeIndex,
              !isChangingRevision
        else { return }
        let previousIndex = revisionState.activeIndex
        let historyConversationID = revisionState.select(index: index)
            ?? logicalConversationID
        stopRunEventStream()
        isChangingRevision = true
        Task {
            let loaded = await loadTimeline(
                historyConversationID: historyConversationID,
                logicalConversationID: logicalConversationID
            )
            if !loaded, selectedConversationID == logicalConversationID {
                let previousHistoryID = revisionState.select(index: previousIndex)
                    ?? logicalConversationID
                _ = await loadTimeline(
                    historyConversationID: previousHistoryID,
                    logicalConversationID: logicalConversationID
                )
            }
            isChangingRevision = false
        }
    }

    func canReviseTurn(_ runID: String) -> Bool {
        canReviseSelectedConversation
            && runs.contains(where: { $0.id == runID && $0.internalRun != true })
    }

    func canUndoTurn(_ runID: String) -> Bool {
        guard let run = runs.first(where: { $0.id == runID }) else { return false }
        return SessionRevisionPolicy.canUndo(
            runStatus: run.status,
            isLatest: runs.last?.id == run.id,
            canRevise: canReviseTurn(runID)
        )
    }

    func reviseTurn(runID: String, replacement: String?) {
        guard canReviseTurn(runID),
              let logicalConversationID = selectedConversationID,
              let projectID = selectedProjectID,
              let server
        else { return }
        let replacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        isChangingRevision = true
        stopRunEventStream()
        Task {
            defer { isChangingRevision = false }
            do {
                let revision = try await server.reviseConversation(
                    id: logicalConversationID,
                    runID: runID
                )
                guard selectedConversationID == logicalConversationID else { return }
                revisionState.recordCreated(revision)
                guard await loadTimeline(
                    historyConversationID: logicalConversationID,
                    logicalConversationID: logicalConversationID
                ) else { return }
                guard let replacement, !replacement.isEmpty else { return }
                let run = try await server.startRun(
                    projectID: projectID,
                    conversationID: logicalConversationID,
                    message: replacement
                )
                guard selectedConversationID == logicalConversationID else { return }
                runs.append(run)
                transcript.append(contentsOf: Self.transcriptItems(run: run, events: []))
                startRunEventStream(runID: run.id, after: 0)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func regenerateTurn(_ runID: String) {
        guard let message = runs.first(where: { $0.id == runID })?.message else { return }
        reviseTurn(runID: runID, replacement: message)
    }

    func undoTurn(_ runID: String) {
        guard canUndoTurn(runID) else { return }
        reviseTurn(runID: runID, replacement: nil)
    }

    func branchTurn(_ runID: String, restoreFiles: Bool) {
        guard canReviseTurn(runID), let logicalConversationID = selectedConversationID,
              let server
        else { return }
        isChangingRevision = true
        Task {
            defer { isChangingRevision = false }
            do {
                let branch = try await server.branchConversation(
                    id: logicalConversationID,
                    runID: runID,
                    restoreFiles: restoreFiles
                )
                if let index = conversations.firstIndex(where: { $0.id == branch.id }) {
                    conversations[index] = branch
                } else {
                    conversations.append(branch)
                }
                updateSelectedProjectNavigationCatalog()
                selectConversation(branch)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func dismissRevisionWorkspaceWarning() {
        revisionState.clearWarning()
    }

    func resolvePermission(_ choice: PermissionChoice) {
        guard let permission = interaction.pendingPermission, let server else { return }
        Task {
            do {
                try await server.resolvePermission(requestID: permission.requestID, optionID: choice.id)
                interaction.pendingPermission = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setElicitationAnswer(propertyID: String, value: JSONValue) {
        elicitationAnswers[propertyID] = value
    }

    func resolveElicitation(accepted: Bool) {
        guard let elicitation = interaction.pendingElicitation, let server else { return }
        let content: [String: JSONValue]?
        if accepted {
            guard let response = ElicitationResponseBuilder.content(
                elicitation,
                answers: elicitationAnswers
            ) else { return }
            content = response
        } else {
            content = nil
        }
        Task {
            do {
                try await server.resolveElicitation(
                    requestID: elicitation.requestID,
                    content: content
                )
                interaction.pendingElicitation = nil
                elicitationAnswers = [:]
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func renameConversation(_ conversation: Conversation, title: String?) {
        guard let server else { return }
        let manualTitle = title.flatMap(SessionLifecyclePolicy.manualTitle(from:))
        Task {
            do {
                let updated = try await server.updateConversation(
                    id: conversation.id,
                    manualTitle: manualTitle
                )
                replaceConversation(updated)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func archiveConversation(_ conversation: Conversation) {
        guard let server else { return }
        Task {
            do {
                let updated = try await server.archiveConversation(
                    id: conversation.id,
                    archived: !(conversation.archived ?? false)
                )
                replaceConversation(updated)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func forkConversation(_ conversation: Conversation) {
        guard SessionLifecyclePolicy.canFork(conversation), let server else { return }
        Task {
            do {
                let fork = try await server.forkConversation(id: conversation.id)
                if let projectID = selectedProjectID { try await loadProject(projectID) }
                selectConversation(fork)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        guard SessionLifecyclePolicy.canDelete(conversation), let server else { return }
        Task {
            do {
                try await server.deleteConversation(id: conversation.id)
                let removedIDs = SessionLifecyclePolicy.removedConversationIDs(
                    deleting: conversation,
                    conversations: conversations
                )
                conversations.removeAll { removedIDs.contains($0.id) }
                if let selectedConversationID, removedIDs.contains(selectedConversationID) {
                    switchComposer(to: nil)
                    resetSessionPresentation()
                }
                for conversationID in removedIDs {
                    sessionDraftStore.clear(
                        windowID: windowPersistenceID,
                        sessionID: conversationID
                    )
                }
                updateSelectedProjectNavigationCatalog()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func openFile(_ entry: FileEntry) {
        guard canUseSelectedProjectFiles else { return }
        if entry.kind == "directory" {
            toggleDirectory(entry)
            return
        }
        guard let projectID = selectedProjectID, let server else { return }
        Task {
            do {
                let document = try await server.readFile(projectID: projectID, path: entry.path)
                activeDiff = nil
                activeDocument = document
                if !openDocuments.contains(where: { $0.path == document.path }) { openDocuments.append(document) }
                documentDrafts[document.path] = documentDrafts[document.path] ?? document.content
                documentDraft = documentDrafts[document.path] ?? document.content
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func selectDocument(_ document: TextDocument) {
        if let activeDocument { documentDrafts[activeDocument.path] = documentDraft }
        activeDocument = document
        activeDiff = nil
        documentDraft = documentDrafts[document.path] ?? document.content
    }

    func isDocumentDirty(_ document: TextDocument) -> Bool {
        draft(for: document) != document.content
    }

    func dirtyDocumentPathsForWindowClose() -> [String] {
        synchronizeActiveDocumentDraft()
        return openDocuments.filter(isDocumentDirty).map(\.path)
    }

    func requestCloseDocument(_ document: TextDocument) {
        synchronizeActiveDocumentDraft()
        if isDocumentDirty(document) {
            pendingDocumentClosePath = document.path
        } else {
            closeDocumentImmediately(document)
        }
    }

    func cancelPendingDocumentClose() {
        pendingDocumentClosePath = nil
    }

    func discardPendingDocumentClose() {
        guard let path = pendingDocumentClosePath,
              let document = openDocuments.first(where: { $0.path == path })
        else {
            pendingDocumentClosePath = nil
            return
        }
        pendingDocumentClosePath = nil
        closeDocumentImmediately(document)
    }

    func savePendingDocumentClose() {
        guard let path = pendingDocumentClosePath,
              let document = openDocuments.first(where: { $0.path == path }),
              !savingDocumentPaths.contains(path)
        else {
            if openDocuments.contains(where: { $0.path == pendingDocumentClosePath }) == false {
                pendingDocumentClosePath = nil
            }
            return
        }
        guard !selectedProjectNeedsFolderAccess else {
            errorMessage = String(localized: "Restore folder access before saving this file.")
            return
        }
        synchronizeActiveDocumentDraft()
        let draft = draft(for: document)
        pendingDocumentClosePath = nil
        saveDocument(document, draft: draft, closeAfterSave: true)
    }

    func closeDocument(_ document: TextDocument) {
        closeDocumentImmediately(document)
    }

    private func closeDocumentImmediately(_ document: TextDocument) {
        openDocuments.removeAll { $0.path == document.path }
        documentDrafts.removeValue(forKey: document.path)
        if pendingDocumentClosePath == document.path { pendingDocumentClosePath = nil }
        if documentRevisionConflict?.path == document.path { documentRevisionConflict = nil }
        if activeDocument?.path == document.path {
            activeDocument = openDocuments.last
            documentDraft = activeDocument.map { documentDrafts[$0.path] ?? $0.content } ?? ""
        }
    }

    func createEntry(path: String, kind: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUseSelectedProjectFiles, !path.isEmpty else { return }
        guard let projectID = selectedProjectID, let server else { return }
        Task {
            do {
                try await server.createEntry(projectID: projectID, path: path, kind: kind)
                await reloadFileTree()
                if kind == "file" {
                    let document = try await server.readFile(projectID: projectID, path: path)
                    activeDiff = nil
                    activeDocument = document
                    if !openDocuments.contains(where: { $0.path == document.path }) {
                        openDocuments.append(document)
                    }
                    documentDrafts[document.path] = document.content
                    documentDraft = document.content
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func renameEntry(_ entry: FileEntry, to path: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUseSelectedProjectFiles, !path.isEmpty, path != entry.path else { return }
        guard let projectID = selectedProjectID, let server else { return }
        Task {
            do {
                try await server.renameEntry(projectID: projectID, from: entry.path, to: path)
                fileTree.discardSubtree(at: entry.path)
                await reloadFileTree()
                await reconcileOpenDocuments(afterRenaming: entry, to: path)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteEntry(_ entry: FileEntry) {
        guard canUseSelectedProjectFiles,
              let projectID = selectedProjectID, let server else { return }
        Task {
            do {
                try await server.deleteEntry(projectID: projectID, path: entry.path)
                fileTree.discardSubtree(at: entry.path)
                if entry.kind == "file", let document = openDocuments.first(where: { $0.path == entry.path }) {
                    closeDocument(document)
                } else if entry.kind == "directory" {
                    let prefix = entry.path + "/"
                    let removed = openDocuments.filter { $0.path.hasPrefix(prefix) }
                    removed.forEach(closeDocument)
                }
                await reloadFileTree()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func toggleDirectory(_ entry: FileEntry) {
        guard canUseSelectedProjectFiles, entry.kind == "directory" else { return }
        if fileTree.expandedPaths.contains(entry.path) {
            fileTree.collapse(entry.path)
            return
        }
        fileTree.expand(entry.path)
        guard !fileTree.hasLoadedChildren(of: entry.path) else { return }
        Task { await loadDirectory(entry.path) }
    }

    func refreshFileTree() {
        guard canUseSelectedProjectFiles else { return }
        Task { await reloadFileTree() }
    }

    func openChange(_ change: GitFileChange, staged: Bool = false) {
        guard canUseSelectedProjectFiles,
              let projectID = selectedProjectID, let server else { return }
        Task {
            do {
                let content: String
                if !staged, change.indexStatus == "?", change.worktreeStatus == "?" {
                    let document = try await server.readFile(projectID: projectID, path: change.path)
                    content = document.content
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "+\($0)" }
                        .joined(separator: "\n")
                } else {
                    content = try await server.gitDiff(
                        projectID: projectID,
                        path: change.path,
                        staged: staged
                    )
                }
                activeDocument = nil
                activeDiff = GitDiffDocument(path: change.path, staged: staged, content: content)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func mutateGit(_ change: GitFileChange, action: GitMutation) {
        mutateGit([change], action: action)
    }

    func mutateGit(_ changes: [GitFileChange], action: GitMutation) {
        let paths = Array(Set(changes.map(\.path))).sorted()
        guard canUseSelectedProjectFiles, !paths.isEmpty else { return }
        guard let projectID = selectedProjectID, let server else { return }
        Task {
            do {
                gitStatus = try await server.mutateGit(
                    projectID: projectID,
                    action: action,
                    paths: paths
                )
                activeDiff = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveDocument() {
        guard canSaveActiveDocument, let document = activeDocument else { return }
        synchronizeActiveDocumentDraft()
        saveDocument(document, draft: documentDraft, closeAfterSave: false)
    }

    func requestFind() {
        guard activeDocument != nil else { return }
        nativeFindRequest.send(.showFindInterface)
    }

    func requestFindAndReplace() {
        guard activeDocument != nil else { return }
        nativeFindRequest.send(.showReplaceInterface)
    }

    func autosaveDocument(path: String) {
        synchronizeActiveDocumentDraft()
        guard canUseSelectedProjectFiles,
              let document = openDocuments.first(where: { $0.path == path }),
              isDocumentDirty(document)
        else { return }
        saveDocument(document, draft: draft(for: document), closeAfterSave: false)
    }

    func saveDocumentForWindowClose(path: String) async -> WindowDocumentSaveOutcome {
        synchronizeActiveDocumentDraft()
        guard let document = openDocuments.first(where: { $0.path == path }),
              isDocumentDirty(document)
        else { return .saved }
        guard !selectedProjectNeedsFolderAccess else {
            errorMessage = String(localized: "Restore folder access before saving this file.")
            return .failed
        }
        guard let projectID = selectedProjectID, let server else {
            errorMessage = String(localized: "The Runtime is not connected. Reconnect before saving this file.")
            return .failed
        }
        guard !savingDocumentPaths.contains(path) else { return .busy }

        let draft = draft(for: document)
        var request = document
        request.content = draft
        if documentRevisionConflict?.path == path { documentRevisionConflict = nil }
        savingDocumentPaths.insert(path)
        return await performDocumentSave(
            server: server,
            projectID: projectID,
            request: request,
            draft: draft,
            closeAfterSave: false
        )
    }

    func reloadConflictedDocument() {
        guard canUseSelectedProjectFiles,
              let conflict = documentRevisionConflict,
              let projectID = selectedProjectID,
              let server
        else { return }
        documentRevisionConflict = nil
        savingDocumentPaths.insert(conflict.path)
        Task {
            defer { savingDocumentPaths.remove(conflict.path) }
            do {
                let reloaded = try await server.readFile(projectID: projectID, path: conflict.path)
                if let index = openDocuments.firstIndex(where: { $0.path == conflict.path }) {
                    openDocuments[index] = reloaded
                }
                documentDrafts[conflict.path] = reloaded.content
                if activeDocument?.path == conflict.path {
                    activeDocument = reloaded
                    documentDraft = reloaded.content
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func keepEditingConflictedDocument() {
        documentRevisionConflict = nil
    }

    private func saveDocument(_ source: TextDocument, draft: String, closeAfterSave: Bool) {
        guard canUseSelectedProjectFiles,
              let projectID = selectedProjectID,
              let server,
              !savingDocumentPaths.contains(source.path)
        else { return }
        var document = source
        document.content = draft
        if documentRevisionConflict?.path == document.path { documentRevisionConflict = nil }
        savingDocumentPaths.insert(source.path)
        Task {
            _ = await performDocumentSave(
                server: server,
                projectID: projectID,
                request: document,
                draft: draft,
                closeAfterSave: closeAfterSave
            )
        }
    }

    private func performDocumentSave(
        server: ServerSession,
        projectID: String,
        request: TextDocument,
        draft: String,
        closeAfterSave: Bool
    ) async -> WindowDocumentSaveOutcome {
        defer { savingDocumentPaths.remove(request.path) }
        do {
            let saved = try await server.writeFile(projectID: projectID, document: request)
            if let index = openDocuments.firstIndex(where: { $0.path == saved.path }) {
                openDocuments[index] = saved
            }

            if activeDocument?.path == saved.path {
                activeDocument = saved
                if documentDraft == draft { documentDraft = saved.content }
                documentDrafts[saved.path] = documentDraft
            } else if documentDrafts[saved.path] == draft {
                documentDrafts[saved.path] = saved.content
            }

            if closeAfterSave,
               let current = openDocuments.first(where: { $0.path == saved.path }) {
                if !isDocumentDirty(current) {
                    closeDocumentImmediately(current)
                } else {
                    pendingDocumentClosePath = saved.path
                }
            }
            return .saved
        } catch {
            switch DocumentSaveFailure(error: error) {
            case let .revisionConflict(message):
                documentRevisionConflict = DocumentRevisionConflict(
                    path: request.path,
                    message: message
                )
            case let .other(message):
                errorMessage = message
            }
            return .failed
        }
    }

    private func draft(for document: TextDocument) -> String {
        if activeDocument?.path == document.path { return documentDraft }
        return documentDrafts[document.path] ?? document.content
    }

    private func synchronizeActiveDocumentDraft() {
        guard let activeDocument else { return }
        documentDrafts[activeDocument.path] = documentDraft
    }

    func initializeGit() {
        guard canUseSelectedProjectFiles,
              let projectID = selectedProjectID, let server else { return }
        Task {
            do { gitStatus = try await server.initializeGit(projectID: projectID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func refreshGitStatus() {
        guard !selectedProjectNeedsFolderAccess,
              let projectID = selectedProjectID, let server else { return }
        Task {
            do { gitStatus = try await server.gitStatus(projectID: projectID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func commitGit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUseSelectedProjectFiles, !message.isEmpty,
              let projectID = selectedProjectID, let server else { return }
        Task {
            do {
                gitStatus = try await server.commitGit(projectID: projectID, message: message)
                commitMessage = ""
                activeDiff = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func configureWindowPersistence(id: String) {
        guard id != windowPersistenceID else { return }
        if let selectedConversationID {
            sessionDraftStore.save(
                composer,
                windowID: windowPersistenceID,
                sessionID: selectedConversationID
            )
        }
        windowPersistenceID = id
        restoreSelectedSessionDraft()
        terminalWorkspaceProjectID = nil
        reconcileTerminalWorkspace()
    }

    func handleDraftPersistencePreferenceChanged() {
        guard let selectedConversationID else { return }
        sessionDraftStore.save(
            composer,
            windowID: windowPersistenceID,
            sessionID: selectedConversationID
        )
    }

    func reconcileTerminalWorkspace() {
        guard let projectID = selectedProjectID else {
            terminalWorkspace = .empty
            terminalWorkspaceProjectID = nil
            return
        }
        let terminalIDs = terminals.map(\.id)
        if terminalWorkspaceProjectID == projectID {
            terminalWorkspace = terminalWorkspace.reconciled(with: terminalIDs)
        } else {
            terminalWorkspace = terminalWorkspaceStore.load(
                windowID: windowPersistenceID,
                projectID: projectID,
                terminalIDs: terminalIDs
            )
            terminalWorkspaceProjectID = projectID
        }
        persistTerminalWorkspace()
        if terminalWorkspace.groups.isEmpty { isTerminalPanelPresented = false }
    }

    func createTerminal(kind: TerminalKind = .regular) {
        guard let projectID = selectedProjectID, let server, !isCreatingTerminal else { return }
        isCreatingTerminal = true
        Task {
            defer { isCreatingTerminal = false }
            do {
                let terminal = try await server.createTerminal(
                    projectID: projectID,
                    conversationID: TerminalCreationContext.conversationID(
                        for: kind,
                        selectedConversationID: selectedConversationID
                    ),
                    kind: kind
                )
                terminals = try await server.terminalSummaries(projectID: projectID)
                terminalWorkspace = terminalWorkspace.reconciled(with: terminals.map(\.id))
                terminalWorkspace.activateTerminal(terminal.id)
                persistTerminalWorkspace()
                isTerminalPanelPresented = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func splitActiveTerminal(axis: TerminalSplitAxis) {
        guard let projectID = selectedProjectID,
              let server,
              let terminal = activeTerminal,
              !isCreatingTerminal
        else { return }
        let descriptor = TerminalRestartDescriptor(terminal: terminal)
        isCreatingTerminal = true
        Task {
            defer { isCreatingTerminal = false }
            do {
                let created = try await server.createTerminal(
                    projectID: projectID,
                    conversationID: TerminalCreationContext.conversationID(
                        for: descriptor.kind,
                        selectedConversationID: descriptor.conversationID
                    ),
                    kind: descriptor.kind,
                    cols: descriptor.cols,
                    rows: descriptor.rows
                )
                terminals = try await server.terminalSummaries(projectID: projectID)
                if !terminalWorkspace.split(
                    terminalID: terminal.id,
                    with: created.id,
                    axis: axis
                ) {
                    terminalWorkspace.addGroup(terminalID: created.id)
                }
                persistTerminalWorkspace()
                isTerminalPanelPresented = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func selectTerminal(_ terminal: TerminalInfo) {
        if terminalWorkspace.terminalIDs.contains(terminal.id) {
            terminalWorkspace.activateTerminal(terminal.id)
        } else {
            terminalWorkspace.addGroup(terminalID: terminal.id)
        }
        persistTerminalWorkspace()
        isTerminalPanelPresented = true
    }

    func openTerminal(_ terminal: TerminalInfo, inSplit axis: TerminalSplitAxis) {
        guard let targetTerminalID = activeTerminalID, targetTerminalID != terminal.id else {
            selectTerminal(terminal)
            return
        }
        terminalWorkspace.removeTerminal(terminal.id)
        if !terminalWorkspace.split(
            terminalID: targetTerminalID,
            with: terminal.id,
            axis: axis
        ) {
            terminalWorkspace.addGroup(terminalID: terminal.id)
        }
        persistTerminalWorkspace()
        isTerminalPanelPresented = true
    }

    func activateTerminalGroup(_ groupID: String) {
        terminalWorkspace.activateGroup(groupID)
        persistTerminalWorkspace()
    }

    func moveActiveTerminalGroup(by offset: Int) {
        terminalWorkspace.moveActiveGroup(by: offset)
        persistTerminalWorkspace()
    }

    func updateTerminalSplitRatio(splitID: String, ratio: Double) {
        terminalWorkspace.updateRatio(splitID: splitID, ratio: ratio)
        persistTerminalWorkspace()
    }

    func toggleTerminalPanel() {
        if isTerminalPanelPresented {
            isTerminalPanelPresented = false
        } else if !activeTerminalPanes.isEmpty {
            isTerminalPanelPresented = true
        } else if let terminal = terminals.first {
            selectTerminal(terminal)
        } else {
            createTerminal()
        }
    }

    func toggleInspector() {
        guard canToggleInspector else { return }
        isInspectorPresented.toggle()
    }

    func closeTerminal(_ terminal: TerminalInfo) {
        guard let server else { return }
        Task {
            do {
                try await server.closeTerminal(id: terminal.id)
                terminals.removeAll { $0.id == terminal.id }
                terminalWorkspace.removeTerminal(terminal.id)
                persistTerminalWorkspace()
                if terminalWorkspace.groups.isEmpty { isTerminalPanelPresented = false }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func closeActiveTerminal() {
        guard let activeTerminal else { return }
        closeTerminal(activeTerminal)
    }

    func restartActiveTerminal() {
        guard let activeTerminal else { return }
        restartTerminal(activeTerminal)
    }

    func restartTerminal(_ terminal: TerminalInfo) {
        guard let server, !restartingTerminalIDs.contains(terminal.id) else { return }
        let descriptor = TerminalRestartDescriptor(terminal: terminal)
        restartingTerminalIDs.insert(terminal.id)
        Task {
            defer { restartingTerminalIDs.remove(terminal.id) }
            do {
                var replacement = try await server.createTerminal(
                    projectID: descriptor.projectID,
                    conversationID: TerminalCreationContext.conversationID(
                        for: descriptor.kind,
                        selectedConversationID: descriptor.conversationID
                    ),
                    kind: descriptor.kind,
                    cols: descriptor.cols,
                    rows: descriptor.rows
                )
                if replacement.title != descriptor.title,
                   let renamed = try? await server.renameTerminal(
                       id: replacement.id,
                       title: descriptor.title
                   ) {
                    replacement = renamed
                }

                if let index = terminals.firstIndex(where: { $0.id == terminal.id }) {
                    terminals[index] = replacement
                } else if !terminals.contains(where: { $0.id == replacement.id }) {
                    terminals.append(replacement)
                }
                terminalWorkspace.replaceTerminal(terminal.id, with: replacement.id)
                persistTerminalWorkspace()
                isTerminalPanelPresented = true

                do {
                    try await server.closeTerminal(id: terminal.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
                terminals = (try? await server.terminalSummaries(projectID: descriptor.projectID)) ?? terminals
                reconcileTerminalWorkspace()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func renameTerminal(_ terminal: TerminalInfo, title: String) {
        guard let server else { return }
        Task {
            do {
                let updated = try await server.renameTerminal(id: terminal.id, title: title)
                if let index = terminals.firstIndex(where: { $0.id == terminal.id }) { terminals[index] = updated }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func updateTerminalStatus(
        id: String,
        status: String,
        exitCode: Int?,
        signal: String?
    ) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[index] = terminals[index].updatingStatus(
            status,
            exitCode: exitCode,
            signal: signal
        )
    }

    func makeTerminalConnection(_ terminal: TerminalInfo, cursor: Int = 0) throws -> TerminalConnection {
        guard let server else { throw URLError(.notConnectedToInternet) }
        return try server.terminalConnection(
            projectID: terminal.projectID,
            terminalID: terminal.id,
            cursor: cursor
        )
    }

    static func replacingTerminalID(
        _ terminalID: String,
        with replacementID: String,
        in terminalIDs: [String]
    ) -> [String] {
        terminalIDs.map { $0 == terminalID ? replacementID : $0 }
    }

    private func persistTerminalWorkspace() {
        guard let projectID = selectedProjectID else { return }
        terminalWorkspaceStore.save(
            terminalWorkspace,
            windowID: windowPersistenceID,
            projectID: projectID
        )
    }

    func dismissError() { errorMessage = nil }

    func loadEarlierHistory() async {
        guard !isLoadingEarlierHistory,
              let cursor = historyCursor,
              let conversationID = selectedConversationID,
              let server
        else { return }

        isLoadingEarlierHistory = true
        defer { isLoadingEarlierHistory = false }
        do {
            let page = try await server.history(conversationID: conversationID, before: cursor)
            guard selectedConversationID == conversationID else { return }
            transcript = Self.prependingHistory(page, to: transcript)

            runs = Self.prependingRuns(page.runs, to: runs)
            var eventIDs = Set<String>()
            sessionEvents = (page.sessionEvents + sessionEvents).filter { eventIDs.insert($0.id).inserted }
            historyCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() {
        navigationSearchTask?.cancel()
        navigationCatalogTask?.cancel()
        eventsTask?.cancel()
        eventsTask = nil
        cancelProjectResourceLoads()
        stopRunEventStream()
        connections.stopAll()
        server = nil
    }

    func disconnectWindow() {
        cancelQuickOpenSearch()
        navigationSearchTask?.cancel()
        navigationCatalogTask?.cancel()
        eventsTask?.cancel()
        eventsTask = nil
        cancelProjectResourceLoads()
        stopRunEventStream()
        server = nil
    }

    func openRuntimeLog() {
        try? connections.diagnostics.ensureExists(.local)
        NSWorkspace.shared.activateFileViewerSelecting([
            connections.diagnostics.url(for: .local),
        ])
    }

    private func scheduleNavigationCatalogRefresh() {
        navigationCatalogTask?.cancel()
        navigationCatalogTask = Task { [weak self] in
            await self?.refreshNavigationCatalog()
        }
    }

    private func refreshNavigationCatalog() async {
        guard let server else { return }
        isRefreshingNavigationCatalog = true
        defer { isRefreshingNavigationCatalog = false }
        let boundedProjects = Array(projects.prefix(50))
        let currentProjectID = selectedProjectID
        let currentConversations = conversations
        let currentTeams = teams
        let globalSessions = (try? await server.sessionSummaries()) ?? currentConversations
        guard !Task.isCancelled else { return }

        var teamsByProject: [String: [TeamSnapshot]] = [:]
        for project in boundedProjects {
            guard !Task.isCancelled else { return }
            if project.id == currentProjectID {
                teamsByProject[project.id] = Array(currentTeams.prefix(500))
                continue
            }
            let snapshots = (try? await server.teamSummaries(projectID: project.id)) ?? []
            teamsByProject[project.id] = Array(snapshots.prefix(500))
        }
        guard !Task.isCancelled else { return }

        let catalogs = boundedProjects.map { project in
            var projectConversations = globalSessions.filter { $0.projectID == project.id }
            if project.id == currentProjectID {
                let currentIDs = Set(currentConversations.map(\.id))
                projectConversations = currentConversations
                    + projectConversations.filter { !currentIDs.contains($0.id) }
            }
            return WorkspaceNavigationCatalog(
                project: project,
                conversations: Array(projectConversations.prefix(500)),
                teams: teamsByProject[project.id] ?? []
            )
        }
        navigationCatalogs = catalogs
        refreshNavigationPresentation()
    }

    private func updateSelectedProjectNavigationCatalog() {
        guard let project = selectedProject else { return }
        let catalog = WorkspaceNavigationCatalog(
            project: project,
            conversations: Array(conversations.prefix(500)),
            teams: Array(teams.prefix(500))
        )
        if let index = navigationCatalogs.firstIndex(where: { $0.project.id == project.id }) {
            navigationCatalogs[index] = catalog
        } else {
            navigationCatalogs.append(catalog)
        }
        refreshNavigationPresentation()
    }

    private func refreshNavigationPresentation() {
        navigationAttentionItems = WorkspaceNavigationIndex.attentionItems(
            catalogs: navigationCatalogs
        )
        if !navigationSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            navigationSearchResults = WorkspaceNavigationIndex.search(
                navigationSearchQuery,
                catalogs: navigationCatalogs
            )
        }
    }

    private func loadWorkspace(forceRefresh: Bool = false) async throws {
        guard let server else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let summary = try await server.loadWorkspaceSummary(forceRefresh: forceRefresh)
        projects = summary.projects
        agents = summary.agents
        if selectedProjectID == nil { selectedProjectID = projects.first?.id }
        if let selectedProjectID {
            try await loadProject(selectedProjectID, forceRefresh: forceRefresh)
        }
        scheduleNavigationCatalogRefresh()
    }

    private func loadProject(_ projectID: String, forceRefresh: Bool = false) async throws {
        guard let server else { return }
        cancelProjectResourceLoads()
        async let loadedConversations = server.conversationSummaries(
            projectID: projectID,
            forceRefresh: forceRefresh
        )
        async let loadedTeams = server.teamSummaries(
            projectID: projectID,
            forceRefresh: forceRefresh
        )
        async let loadedTerminals = server.terminalSummaries(
            projectID: projectID,
            forceRefresh: forceRefresh
        )
        (conversations, teams, terminals) = try await (
            loadedConversations,
            loadedTeams,
            loadedTerminals
        )
        reconcileTerminalWorkspace()
        updateSelectedProjectNavigationCatalog()
        scheduleProjectResourceLoads(projectID: projectID)
        if let selectedConversationID,
           conversations.contains(where: { $0.id == selectedConversationID }) {
            let historyConversationID = revisionState.viewedSnapshotConversationID
                ?? selectedConversationID
            _ = await loadTimeline(
                historyConversationID: historyConversationID,
                logicalConversationID: selectedConversationID
            )
        }
    }

    private func cancelProjectResourceLoads() {
        projectFilesTask?.cancel()
        projectGitTask?.cancel()
        projectFilesTask = nil
        projectGitTask = nil
    }

    private func scheduleProjectResourceLoads(projectID: String) {
        guard let server else { return }
        if isLocalManagedConnection,
           !connections.projectAccess.isAuthorized(projectID: projectID) {
            files = []
            gitStatus = nil
            return
        }
        projectFilesTask = Task { [weak self] in
            do {
                let loadedFiles = try await server.listEntries(projectID: projectID, path: "")
                guard let self, !Task.isCancelled, selectedProjectID == projectID else { return }
                files = loadedFiles
                fileTree.replaceChildren(loadedFiles, of: "")
            } catch {
                guard let self, !Task.isCancelled, selectedProjectID == projectID else { return }
                errorMessage = error.localizedDescription
            }
        }
        projectGitTask = Task { [weak self] in
            guard let loadedStatus = try? await server.gitStatus(projectID: projectID),
                  let self, !Task.isCancelled, selectedProjectID == projectID else { return }
            gitStatus = loadedStatus
        }
    }

    private func loadTranscript(_ conversationID: String) async {
        _ = await loadTimeline(
            historyConversationID: conversationID,
            logicalConversationID: conversationID
        )
    }

    @discardableResult
    private func loadTimeline(
        historyConversationID: String,
        logicalConversationID: String
    ) async -> Bool {
        guard let server else { return false }
        do {
            async let loadedHistory = server.history(conversationID: historyConversationID)
            async let loadedState = server.sessionState(conversationID: historyConversationID)
            async let loadedRevisions = server.listConversationRevisions(id: logicalConversationID)
            let (history, state, currentRevisions) = try await (
                loadedHistory,
                loadedState,
                loadedRevisions
            )
            guard selectedConversationID == logicalConversationID else { return false }
            applySessionState(state)
            runs = history.runs
            sessionEvents = history.sessionEvents
            historyCursor = history.nextCursor
            let allEvents = history.runs.flatMap { history.events[$0.id] ?? [] }
                .sorted { $0.sequence < $1.sequence }
            interaction = AgentInteractionReducer.reduce(allEvents)
            elicitationAnswers = Dictionary(uniqueKeysWithValues:
                interaction.pendingElicitation?.properties.map { ($0.id, $0.defaultValue) } ?? []
            )
            revisionState.replaceRevisions(currentRevisions)
            transcript = history.runs.flatMap {
                Self.transcriptItems(run: $0, events: history.events[$0.id] ?? [])
            }
            if historyConversationID == logicalConversationID,
               let active = history.runs.last(where: {
                   ["running", "waiting_permission"].contains($0.status)
               }) {
                let sequence = history.events[active.id]?.map(\.sequence).max() ?? 0
                startRunEventStream(runID: active.id, after: sequence)
            } else {
                stopRunEventStream()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func loadDirectory(_ path: String) async {
        guard !selectedProjectNeedsFolderAccess,
              let projectID = selectedProjectID, let server else { return }
        fileTreeLoadingPaths.insert(path)
        defer { fileTreeLoadingPaths.remove(path) }
        do {
            let entries = try await server.listEntries(projectID: projectID, path: path)
            guard selectedProjectID == projectID else { return }
            fileTree.replaceChildren(entries, of: path)
            if path.isEmpty { files = entries }
        } catch { errorMessage = error.localizedDescription }
    }

    private func reloadFileTree() async {
        let expanded = fileTree.expandedPaths.sorted()
        fileTree.invalidateLoadedChildren()
        await loadDirectory("")
        for path in expanded where fileTree.expandedPaths.contains(path) && fileTree.containsEntry(at: path) {
            await loadDirectory(path)
        }
    }

    private func reconcileOpenDocuments(afterRenaming entry: FileEntry, to destination: String) async {
        guard let projectID = selectedProjectID, let server else { return }
        let sourcePrefix = entry.kind == "directory" ? entry.path + "/" : entry.path
        let affected = openDocuments.filter {
            entry.kind == "directory" ? $0.path.hasPrefix(sourcePrefix) : $0.path == entry.path
        }
        for oldDocument in affected {
            let suffix = entry.kind == "directory"
                ? String(oldDocument.path.dropFirst(sourcePrefix.count))
                : ""
            let newPath = suffix.isEmpty ? destination : destination + "/" + suffix
            guard let refreshed = try? await server.readFile(projectID: projectID, path: newPath) else {
                closeDocument(oldDocument)
                continue
            }
            let oldDraft = documentDrafts.removeValue(forKey: oldDocument.path) ?? oldDocument.content
            if let index = openDocuments.firstIndex(where: { $0.path == oldDocument.path }) {
                openDocuments[index] = refreshed
            }
            documentDrafts[newPath] = oldDraft
            if activeDocument?.path == oldDocument.path {
                activeDocument = refreshed
                documentDraft = oldDraft
            }
        }
    }

    private func refreshConversation(_ conversationID: String) async {
        guard let projectID = selectedProjectID, let server else { return }
        do {
            conversations = try await server.conversationSummaries(projectID: projectID)
            updateSelectedProjectNavigationCatalog()
            if selectedConversationID == conversationID { await loadTranscript(conversationID) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshSelectedProjectConversationSummaries() async {
        guard let projectID = selectedProjectID, let server else { return }
        do {
            conversations = try await server.conversationSummaries(projectID: projectID)
            updateSelectedProjectNavigationCatalog()
        } catch { errorMessage = error.localizedDescription }
    }

    func handleWorkspaceEvent(_ event: WorkspaceEvent) async {
        if event.runID == directlyStreamedRunID,
           ["text_delta", "thinking_delta", "tool_started", "tool_updated", "tool_completed"]
            .contains(event.kind) {
            return
        }
        if let notificationCoordinator, let server {
            let catalog = navigationCatalogs.first { $0.project.id == event.projectID }
            let conversation = catalog?.conversations.first { $0.id == event.conversationID }
                ?? conversations.first { $0.id == event.conversationID }
            notificationCoordinator.handle(
                event,
                serverID: server.id,
                serverName: currentServerName,
                projectName: catalog?.project.name
                    ?? projects.first(where: { $0.id == event.projectID })?.name,
                conversationTitle: conversation?.title,
                agentName: conversation?.agentID.displayName,
                appIsActive: NSApp.isActive
            )
        }
        if event.kind.contains("attention") || event.kind.contains("failed") || event.kind == "error" {
            errorMessage = event.payload["message"]?.stringValue
                ?? event.payload["summary"]?.stringValue
        }
        if event.conversationID == selectedConversationID {
            if event.runID != directlyStreamedRunID {
                Self.applyStreamingDelta(event, to: &transcript)
                AgentInteractionReducer.apply(event, to: &interaction)
            }
            if event.kind == "elicitation_requested", let pending = interaction.pendingElicitation {
                elicitationAnswers = Dictionary(uniqueKeysWithValues: pending.properties.map { ($0.id, $0.defaultValue) })
            }
        }
        if WorkspaceNavigationIndex.eventChangesNavigation(event.kind) {
            if event.projectID == selectedProjectID {
                if !event.kind.hasPrefix("team_"),
                   !["run_started", "run_completed"].contains(event.kind) {
                    await refreshSelectedProjectConversationSummaries()
                }
            } else {
                scheduleNavigationCatalogRefresh()
            }
        }
        guard event.projectID == nil || event.projectID == selectedProjectID else { return }
        switch event.kind {
        case "run_completed", "run_started":
            if let conversationID = event.conversationID { await refreshConversation(conversationID) }
        case "available_commands", "current_mode", "config_options", "plan", "usage", "session_info":
            if event.conversationID == selectedConversationID,
               let conversationID = event.conversationID,
               let server {
                if let state = try? await server.sessionState(conversationID: conversationID) {
                    applySessionState(state)
                }
            }
        case "file_changed":
            publishMarkdownResourceInvalidation(event)
            await reloadFileTree()
        case "git_changed":
            if !selectedProjectNeedsFolderAccess,
               let projectID = selectedProjectID, let server {
                gitStatus = try? await server.gitStatus(projectID: projectID)
            }
        case let kind where kind.hasPrefix("terminal_"):
            if let projectID = selectedProjectID, let server {
                terminals = (try? await server.terminalSummaries(projectID: projectID)) ?? terminals
                reconcileTerminalWorkspace()
            }
        case let kind where kind.hasPrefix("team_"):
            if let projectID = selectedProjectID, let server {
                teams = (try? await server.teamSummaries(projectID: projectID)) ?? teams
                updateSelectedProjectNavigationCatalog()
            }
        default:
            break
        }
    }

    private func publishMarkdownResourceInvalidation(_ event: WorkspaceEvent) {
        guard let projectID = event.projectID,
              latestMarkdownResourceEventID.map({ event.id > $0 }) ?? true
        else { return }
        let rawPath = event.payload["path"]?.stringValue
        let projectPath = rawPath.flatMap(MarkdownResourcePolicy.projectRelativeImagePath)
        guard rawPath == nil || projectPath != nil else { return }
        latestMarkdownResourceEventID = event.id
        markdownResourceInvalidation = .init(
            eventID: event.id,
            projectID: projectID,
            projectPath: projectPath
        )
    }

    private func replaceConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        }
        updateSelectedProjectNavigationCatalog()
    }

    private func replaceProject(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        }
    }

    private func resetSessionPresentation() {
        stopRunEventStream()
        transcript = []
        applySessionState(nil)
        runs = []
        sessionEvents = []
        historyCursor = nil
        revisionState.reset()
        isChangingRevision = false
        interaction = AgentInteractionState()
        elicitationAnswers = [:]
    }

    private func switchComposer(to sessionID: String?) {
        if let selectedConversationID {
            sessionDraftStore.save(
                composer,
                windowID: windowPersistenceID,
                sessionID: selectedConversationID
            )
        }
        selectedConversationID = sessionID
        restoreSelectedSessionDraft()
    }

    private func restoreSelectedSessionDraft() {
        isRestoringSessionDraft = true
        defer { isRestoringSessionDraft = false }
        composer = selectedConversationID.map {
            sessionDraftStore.load(windowID: windowPersistenceID, sessionID: $0)
        } ?? ""
    }

    private func persistSelectedSessionDraft() {
        guard !isRestoringSessionDraft, let selectedConversationID else { return }
        sessionDraftStore.save(
            composer,
            windowID: windowPersistenceID,
            sessionID: selectedConversationID
        )
    }

    private func restoreSentDraft(_ message: String, conversationID: String) {
        guard sessionDraftStore.load(
            windowID: windowPersistenceID,
            sessionID: conversationID
        ).isEmpty else { return }
        sessionDraftStore.save(
            message,
            windowID: windowPersistenceID,
            sessionID: conversationID
        )
        if selectedConversationID == conversationID, composer.isEmpty {
            restoreSelectedSessionDraft()
        }
    }

    func applySessionState(_ state: AgentSessionState?) {
        sessionState = state
        explorerSections.synchronize(plan: AgentPlanProjection.entries(from: state?.plan))
    }

    private func startRunEventStream(runID: String, after sequence: Int) {
        guard let server else { return }
        if directlyStreamedRunID == runID, runEventsTask != nil { return }
        stopRunEventStream()
        let generation = runStreamGeneration
        let bridge = AgentEventDispatchBridge { [weak self] events in
            guard let self, self.runStreamGeneration == generation else { return }
            TranscriptReducer.applyStreamingEvents(events, to: &self.transcript)
            for event in events {
                AgentInteractionReducer.apply(event, to: &self.interaction)
            }
        }
        runEventBridge = bridge
        directlyStreamedRunID = runID
        processedRunSequence = sequence
        runEventsTask = Task { [weak self] in
            guard let self else { return }
            var policy = RunStreamReconnectPolicy(initialSequence: sequence)
            defer {
                if self.runStreamGeneration == generation {
                    self.runEventsTask = nil
                    self.runEventBridge = nil
                    self.directlyStreamedRunID = nil
                    self.processedRunSequence = 0
                    self.isRunStreamReconnecting = false
                }
            }

            while !Task.isCancelled {
                var failureDescription = String(localized: "The Agent event stream closed unexpectedly.")
                do {
                    for try await event in server.runEvents(id: runID, after: policy.lastSequence) {
                        guard !Task.isCancelled else { return }
                        guard policy.accept(sequence: event.sequence) else { continue }
                        self.processedRunSequence = policy.lastSequence
                        self.isRunStreamReconnecting = false
                        guard self.selectedConversationID != nil else { continue }
                        await bridge.enqueue(event)
                        if event.kind == "run_completed" {
                            if let conversationID = self.selectedConversationID {
                                await self.refreshConversation(conversationID)
                            }
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    failureDescription = error.localizedDescription
                }

                switch policy.recordDisconnection() {
                case let .retry(_, delayMilliseconds):
                    self.isRunStreamReconnecting = true
                    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                case .stop:
                    await bridge.flushNow()
                    if let conversationID = self.selectedConversationID {
                        await self.refreshConversation(conversationID)
                    }
                    if self.activeRun?.id == runID {
                        self.errorMessage = failureDescription
                    }
                    return
                }
            }
        }
    }

    private func stopRunEventStream() {
        runStreamGeneration &+= 1
        runEventsTask?.cancel()
        runEventsTask = nil
        if let runEventBridge {
            Task { await runEventBridge.stop(discardPending: true) }
        }
        runEventBridge = nil
        directlyStreamedRunID = nil
        processedRunSequence = 0
        isRunStreamReconnecting = false
    }

    static func transcriptItems(run: AgentRun, events: [AgentEvent]) -> [TranscriptItem] {
        TranscriptReducer.items(run: run, events: events)
    }

    static func prependingHistory(
        _ page: ConversationHistoryPage,
        to existing: [TranscriptItem]
    ) -> [TranscriptItem] {
        let earlier = page.runs.flatMap { run in
            transcriptItems(run: run, events: page.events[run.id] ?? [])
        }
        var itemIDs = Set<String>()
        return (earlier + existing).filter { itemIDs.insert($0.id).inserted }
    }

    static func prependingRuns(_ earlier: [AgentRun], to existing: [AgentRun]) -> [AgentRun] {
        var runIDs = Set<String>()
        return (earlier + existing).filter { runIDs.insert($0.id).inserted }
    }

    static func applyStreamingDelta(_ event: WorkspaceEvent, to items: inout [TranscriptItem]) {
        TranscriptReducer.applyStreamingDelta(event, to: &items)
    }

    private func startWorkspaceEvents() {
        eventsTask?.cancel()
        guard let server else { return }
        eventsTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let events = try await server.workspaceEvents()
                    for try await event in events {
                        guard let self else { return }
                        await self.handleWorkspaceEvent(event)
                        await Task.yield()
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}
