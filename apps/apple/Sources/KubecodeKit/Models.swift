import Foundation

public enum ServerConnectionMode: String, Codable, Sendable {
    case localManaged = "local_managed"
    case sshManaged = "ssh_managed"
    case httpsAttached = "https_attached"
}

public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var mode: ServerConnectionMode
    public var url: URL?
    public var basePath: String
    public var sshHost: String?
    public var remoteExecutable: String?
    public var remoteWorkspaceRoot: String?
    public var credentialReference: String?
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        mode: ServerConnectionMode,
        url: URL? = nil,
        basePath: String = "",
        sshHost: String? = nil,
        remoteExecutable: String? = nil,
        remoteWorkspaceRoot: String? = nil,
        credentialReference: String? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.url = url
        self.basePath = basePath
        self.sshHost = sshHost
        self.remoteExecutable = remoteExecutable
        self.remoteWorkspaceRoot = remoteWorkspaceRoot
        self.credentialReference = credentialReference
        self.lastUsedAt = lastUsedAt
    }
}

public struct RuntimeDiscovery: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serverVersion: String
    public let apiBase: String
    public let authentication: String
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case serverVersion = "server_version"
        case apiBase = "api_base"
        case authentication
        case capabilities
    }
}

public struct RuntimeReady: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let serverVersion: String
    public let instanceID: UUID
    public let origin: URL
    public let basePath: String

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case serverVersion = "server_version"
        case instanceID = "instance_id"
        case origin
        case basePath = "base_path"
    }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let workspacesEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case workspacesEnabled = "workspaces_enabled"
    }
}

public struct DirectoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let hidden: Bool
}

public struct DirectoryListing: Codable, Hashable, Sendable {
    public let path: String
    public let parent: String?
    public let entries: [DirectoryEntry]
}

public enum WorkspaceMigrationStrategy: String, Codable, CaseIterable, Sendable {
    case merge
    case exportPatch = "export_patch"
    case discard
}

public struct WorkspaceMigrationResolution: Codable, Hashable, Sendable {
    public let conversationID: String
    public let strategy: WorkspaceMigrationStrategy

    public init(conversationID: String, strategy: WorkspaceMigrationStrategy) {
        self.conversationID = conversationID
        self.strategy = strategy
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case strategy
    }
}

public struct WorkspaceMigrationItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String { conversationID }
    public let conversationID: String
    public let title: String
    public let dirty: Bool

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case title, dirty
    }
}

public struct WorkspaceMigrationPreview: Codable, Hashable, Sendable {
    public let activeConversationIDs: [String]
    public let worktrees: [WorkspaceMigrationItem]

    enum CodingKeys: String, CodingKey {
        case activeConversationIDs = "active_conversation_ids"
        case worktrees
    }
}

public struct WorkspaceMigrationExport: Codable, Identifiable, Hashable, Sendable {
    public var id: String { conversationID }
    public let conversationID: String

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
    }
}

public struct WorkspaceMigrationResponse: Codable, Hashable, Sendable {
    public let project: Project
    public let exports: [WorkspaceMigrationExport]
}

public enum AgentID: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code"
    case codex
    case opencode

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
}

public struct AgentDescriptor: Codable, Identifiable, Hashable, Sendable {
    public let id: AgentID
    public let available: Bool
    public let version: String?
    public let executable: String
    public let error: String?
    public let readiness: String?
    public let checkedAt: UInt64?
    public let cli: AgentComponentDiagnostic?
    public let adapter: AgentAdapterDiagnostic?

    enum CodingKeys: String, CodingKey {
        case id, available, version, executable, error, readiness, cli, adapter
        case checkedAt = "checked_at"
    }
}

public struct AgentComponentDiagnostic: Codable, Hashable, Sendable {
    public let status: String
    public let executable: String?
    public let version: String?
    public let source: String?
    public let errorCode: String?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case status, executable, version, source, detail
        case errorCode = "error_code"
    }
}

public struct AgentAdapterDiagnostic: Codable, Hashable, Sendable {
    public let kind: String
    public let status: String
    public let executable: String?
    public let version: String?
    public let source: String?
    public let errorCode: String?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case kind, status, executable, version, source, detail
        case errorCode = "error_code"
    }
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let agentSessionID: String?
    public let projectID: String
    public let agentID: AgentID
    public let providerSessionID: String?
    public let title: String
    public let manualTitle: String?
    public let agentTitle: String?
    public let archived: Bool?
    public let latestRunStatus: String?
    public let executionMode: String
    public let readOnly: Bool?
    public let teamID: String?
    public let teamRole: String?
    public let teamTitle: String?
    public let teamStatus: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let parentConversationID: String?
    public let relationship: String?
    public let workspacePath: String?
    public let recreatedContext: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, archived
        case agentSessionID = "agent_session_id"
        case projectID = "project_id"
        case agentID = "agent_id"
        case providerSessionID = "provider_session_id"
        case manualTitle = "manual_title"
        case agentTitle = "agent_title"
        case latestRunStatus = "latest_run_status"
        case executionMode = "execution_mode"
        case readOnly = "read_only"
        case teamID = "team_id"
        case teamRole = "team_role"
        case teamTitle = "team_title"
        case teamStatus = "team_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case parentConversationID = "parent_conversation_id"
        case relationship, recreatedContext = "recreated_context"
        case workspacePath = "workspace_path"
    }
}

public struct AgentRun: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let projectID: String
    public let message: String
    public let status: String
    public let error: String?
    public let permissionMode: String?
    public let internalRun: Bool?

    enum CodingKeys: String, CodingKey {
        case id, message, status, error
        case permissionMode = "permission_mode"
        case internalRun = "internal"
        case conversationID = "conversation_id"
        case projectID = "project_id"
    }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }
}

public struct SessionModeAccess: Codable, Hashable, Sendable {
    public let canChange: Bool
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case canChange = "can_change"
        case reason
    }
}

public struct AgentSessionState: Codable, Hashable, Sendable {
    public let capabilities: JSONValue?
    public let availableCommands: JSONValue?
    public let currentMode: JSONValue?
    public let configOptions: JSONValue?
    public let plan: JSONValue?
    public let usage: JSONValue?
    public let modeAccess: SessionModeAccess

    enum CodingKeys: String, CodingKey {
        case capabilities, plan, usage
        case availableCommands = "available_commands"
        case currentMode = "current_mode"
        case configOptions = "config_options"
        case modeAccess = "mode_access"
    }
}

public struct AgentEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(runID):\(sequence)" }
    public let runID: String
    public let sequence: Int
    public let kind: String
    public let payload: [String: JSONValue]
    public let createdAt: String

    public init(
        runID: String,
        sequence: Int,
        kind: String,
        payload: [String: JSONValue],
        createdAt: String
    ) {
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case kind, payload
        case runID = "run_id"
        case sequence = "seq"
        case createdAt = "created_at"
    }
}

public struct ConversationHistoryPage: Codable, Sendable {
    public let runs: [AgentRun]
    public let events: [String: [AgentEvent]]
    public let nextCursor: String?
    public let sessionEvents: [SessionEvent]

    enum CodingKeys: String, CodingKey {
        case runs, events
        case nextCursor = "next_cursor"
        case sessionEvents = "session_events"
    }
}

public struct SessionEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(conversationID):\(sequence)" }
    public let conversationID: String
    public let sequence: Int
    public let kind: String
    public let payload: [String: JSONValue]
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case kind, payload
        case conversationID = "conversation_id"
        case sequence = "seq"
        case createdAt = "created_at"
    }
}

public struct ConversationRevision: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let snapshotConversationID: String
    public let forkedAtRunID: String
    public let createdAt: String
    public let workspaceRestore: String?
    public let workspaceRestoreReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case snapshotConversationID = "snapshot_conversation_id"
        case forkedAtRunID = "forked_at_run_id"
        case createdAt = "created_at"
        case workspaceRestore = "workspace_restore"
        case workspaceRestoreReason = "workspace_restore_reason"
    }
}

public struct ProviderSessionInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String { sessionID }
    public let sessionID: String
    public let cwd: String
    public let title: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case cwd, title
        case sessionID = "session_id"
        case updatedAt = "updated_at"
    }
}

public struct SideQuestionAccepted: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let status: String
}

public struct WorkspaceEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let kind: String
    public let projectID: String?
    public let conversationID: String?
    public let runID: String?
    public let payload: [String: JSONValue]
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, payload
        case projectID = "project_id"
        case conversationID = "conversation_id"
        case runID = "run_id"
        case createdAt = "created_at"
    }
}

public struct FileEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: String
    public let size: Int?
    public let hidden: Bool?
    public let ignored: Bool?
    public let generated: Bool?

    public init(
        name: String,
        path: String,
        kind: String,
        size: Int?,
        hidden: Bool?,
        ignored: Bool?,
        generated: Bool? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.hidden = hidden
        self.ignored = ignored
        self.generated = generated
    }
}

public struct TextDocument: Codable, Hashable, Sendable {
    public let path: String
    public var content: String
    public var revision: String
    public let size: Int?
}

public struct GitFileChange: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let indexStatus: String?
    public let worktreeStatus: String?

    enum CodingKeys: String, CodingKey {
        case path
        case indexStatus = "index_status"
        case worktreeStatus = "worktree_status"
    }
}

public struct GitStatus: Codable, Hashable, Sendable {
    public let isRepository: Bool
    public let branch: String?
    public let files: [GitFileChange]

    enum CodingKeys: String, CodingKey {
        case branch, files
        case isRepository = "is_repository"
    }
}

public enum GitMutation: String, Codable, Sendable {
    case stage
    case unstage
    case discard
}

public enum TerminalKind: String, Codable, CaseIterable, Sendable {
    case regular
    case claudeCode = "claude_code"
    case codex
    case openCode = "opencode"

    public init(agentID: AgentID) {
        switch agentID {
        case .claudeCode: self = .claudeCode
        case .codex: self = .codex
        case .opencode: self = .openCode
        }
    }

    public var agentID: AgentID? {
        switch self {
        case .regular: nil
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .openCode: .opencode
        }
    }
}

public struct TerminalInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let conversationID: String?
    public let title: String
    public let kind: TerminalKind
    public let cols: Int
    public let rows: Int
    public let status: String
    public let exitCode: Int?
    public let signal: String?

    enum CodingKeys: String, CodingKey {
        case id, title, kind, cols, rows, status, signal
        case projectID = "project_id"
        case conversationID = "conversation_id"
        case exitCode = "exit_code"
    }

    public func updatingStatus(
        _ status: String,
        exitCode: Int?,
        signal: String?
    ) -> TerminalInfo {
        TerminalInfo(
            id: id,
            projectID: projectID,
            conversationID: conversationID,
            title: title,
            kind: kind,
            cols: cols,
            rows: rows,
            status: status,
            exitCode: exitCode,
            signal: signal
        )
    }
}

public struct Team: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let title: String
    public let status: String
    public let goal: String
    public let memberManagementPolicy: String?
    public let maxParallelRuns: Int?
    public let requestedMode: String?
    public let mode: String?
    public let acceptanceCriteria: [String]?
    public let allowedAgentIDs: [AgentID]?
    public let maxTeammates: Int?
    public let maxReviewRounds: Int?
    public let finalSummary: String?
    public let leaderMemberID: String?
    public let workspace: String?
    public let currentReviewRound: Int?
    public let modeFallback: TeamModeFallback?

    enum CodingKeys: String, CodingKey {
        case id, title, status, goal
        case projectID = "project_id"
        case memberManagementPolicy = "member_management_policy"
        case maxParallelRuns = "max_parallel_runs"
        case requestedMode = "requested_mode"
        case mode
        case acceptanceCriteria = "acceptance_criteria"
        case allowedAgentIDs = "allowed_agent_ids"
        case maxTeammates = "max_teammates"
        case maxReviewRounds = "max_review_rounds"
        case finalSummary = "final_summary"
        case leaderMemberID = "leader_member_id"
        case workspace
        case currentReviewRound = "current_review_round"
        case modeFallback = "mode_fallback"
    }
}

public struct TeamModeFallback: Codable, Hashable, Sendable {
    public let agentID: String
    public let reasonCode: String
    public let reason: String
    public let occurredAt: String

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case reasonCode = "reason_code"
        case reason
        case occurredAt = "occurred_at"
    }
}

public struct StartTeamInput: Codable, Hashable, Sendable {
    public let goal: String
    public let acceptanceCriteria: [String]
    public let allowedAgentIDs: [AgentID]
    public let mode: String
    public let maxTeammates: Int
    public let maxParallelRuns: Int
    public let maxReviewRounds: Int

    public init(
        goal: String,
        acceptanceCriteria: [String],
        allowedAgentIDs: [AgentID],
        mode: String = "standard",
        maxTeammates: Int = 3,
        maxParallelRuns: Int = 3,
        maxReviewRounds: Int = 2
    ) {
        self.goal = goal
        self.acceptanceCriteria = acceptanceCriteria
        self.allowedAgentIDs = allowedAgentIDs
        self.mode = mode
        self.maxTeammates = maxTeammates
        self.maxParallelRuns = maxParallelRuns
        self.maxReviewRounds = maxReviewRounds
    }

    enum CodingKeys: String, CodingKey {
        case goal, mode
        case acceptanceCriteria = "acceptance_criteria"
        case allowedAgentIDs = "allowed_agent_ids"
        case maxTeammates = "max_teammates"
        case maxParallelRuns = "max_parallel_runs"
        case maxReviewRounds = "max_review_rounds"
    }
}

public struct TeamCounters: Codable, Hashable, Sendable {
    public let running: Int
    public let queued: Int
    public let needsAttention: Int
    public let done: Int
    public let totalTasks: Int

    enum CodingKeys: String, CodingKey {
        case running, queued, done
        case needsAttention = "needs_attention"
        case totalTasks = "total_tasks"
    }
}

public struct TeamMember: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let role: String
    public let status: String
    public let conversationID: String
    public let workspaceMode: String?
    public let permissionProfileApplied: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, role, status
        case conversationID = "conversation_id"
        case workspaceMode = "workspace_mode"
        case permissionProfileApplied = "permission_profile_applied"
    }
}

public struct TeamTask: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let status: String
    public let completionRequired: Bool
    public let assigneeMemberID: String?
    public let result: String?
    public let requiresPlanApproval: Bool?
    public let plan: String?
    public let mutatesFiles: Bool?
    public let verification: String?
    public let dependencies: [String]?
    public let ownedPaths: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, result
        case completionRequired = "completion_required"
        case assigneeMemberID = "assignee_member_id"
        case requiresPlanApproval = "requires_plan_approval"
        case plan
        case mutatesFiles = "mutates_files"
        case verification, dependencies
        case ownedPaths = "owned_paths"
    }
}

public struct TeamAttention: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let memberID: String?
    public let taskID: String?
    public let summary: String

    enum CodingKeys: String, CodingKey {
        case id, kind, summary
        case memberID = "member_id"
        case taskID = "task_id"
    }
}

public struct TeamTaskAttempt: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let taskID: String
    public let memberID: String
    public let runID: String?
    public let status: String
    public let failureKind: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id, status, error
        case taskID = "task_id"
        case memberID = "member_id"
        case runID = "run_id"
        case failureKind = "failure_kind"
    }
}

public struct TeamProposal: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let summary: String
    public let status: String
    public let membersJSON: String?

    public var proposedMemberNames: [String] {
        guard let membersJSON,
              membersJSON.utf8.count <= 32 * 1_024,
              let values = try? JSONDecoder().decode(
                  [JSONValue].self,
                  from: Data(membersJSON.utf8)
              )
        else { return [] }

        let names = values.prefix(64).compactMap { value -> String? in
            let candidate: String?
            switch value {
            case let .string(name):
                candidate = name
            case let .object(member):
                candidate = member["name"]?.stringValue ?? member["role"]?.stringValue
            default:
                candidate = nil
            }
            guard let candidate else { return nil }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Array(names.prefix(16))
    }

    enum CodingKeys: String, CodingKey {
        case id, summary, status
        case membersJSON = "members_json"
    }
}

public struct TeamActivity: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let memberID: String?
    public let taskID: String?
    public let kind: String
    public let summary: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, summary
        case memberID = "member_id"
        case taskID = "task_id"
        case createdAt = "created_at"
    }
}

public struct TeamUserInputRequest: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let requesterMemberID: String
    public let title: String
    public let prompt: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, status
        case requesterMemberID = "requester_member_id"
    }
}

public struct TeamPermissionRequest: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let memberID: String
    public let runID: String
    public let tool: String
    public let status: String
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, tool, status, reason
        case memberID = "member_id"
        case runID = "run_id"
    }
}

public struct TeamLifecycleOperation: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let status: String
    public let memberID: String?
    public let attemptCount: Int
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, status
        case memberID = "member_id"
        case attemptCount = "attempt_count"
        case lastError = "last_error"
    }
}

public struct TeamDiscriminationRound: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let round: Int
    public let status: String
    public let verdict: String?
    public let evidence: String?
}

public struct TeamNextAction: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let label: String
}

public struct TeamSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: String { team.id }
    public let team: Team
    public let summary: TeamCounters
    public let members: [TeamMember]
    public let tasks: [TeamTask]
    public let attention: [TeamAttention]
    public let leaderConversation: Conversation?
    public let conversations: [Conversation]?
    public let taskAttempts: [TeamTaskAttempt]?
    public let proposal: TeamProposal?
    public let permissions: [TeamPermissionRequest]?
    public let activity: [TeamActivity]?
    public let nextActions: [TeamNextAction]?
    public let userInputRequests: [TeamUserInputRequest]?
    public let lifecycleOperations: [TeamLifecycleOperation]?
    public let discriminationRounds: [TeamDiscriminationRound]?

    enum CodingKeys: String, CodingKey {
        case team, summary, members, tasks, attention, conversations, proposal, permissions, activity
        case leaderConversation = "leader_conversation"
        case taskAttempts = "task_attempts"
        case nextActions = "next_actions"
        case userInputRequests = "user_input_requests"
        case lifecycleOperations = "lifecycle_operations"
        case discriminationRounds = "discrimination_rounds"
    }
}
