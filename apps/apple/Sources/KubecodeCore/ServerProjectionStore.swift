import Observation
import KubecodeKit

public struct WorkspaceSummaryProjection: Equatable, Sendable {
    public let projects: [Project]
    public let agents: [AgentDescriptor]

    public init(projects: [Project], agents: [AgentDescriptor]) {
        self.projects = projects
        self.agents = agents
    }
}

@MainActor
@Observable
public final class ServerProjectionStore {
    public var projects: [Project]
    public var agents: [AgentDescriptor]
    public var conversations: [Conversation]
    public var teams: [TeamSnapshot]
    public var files: [FileEntry]
    public var gitStatus: GitStatus?
    public var terminals: [TerminalInfo]

    public init(
        projects: [Project] = [],
        agents: [AgentDescriptor] = [],
        conversations: [Conversation] = [],
        teams: [TeamSnapshot] = [],
        files: [FileEntry] = [],
        gitStatus: GitStatus? = nil,
        terminals: [TerminalInfo] = []
    ) {
        self.projects = projects
        self.agents = agents
        self.conversations = conversations
        self.teams = teams
        self.files = files
        self.gitStatus = gitStatus
        self.terminals = terminals
    }

    public func clearProjectResources() {
        conversations = []
        teams = []
        files = []
        gitStatus = nil
        terminals = []
    }
}
