import Foundation
import KubecodeKit

enum WorkspaceNavigationKind: String, Equatable, Hashable, Sendable {
    case project
    case conversation
    case team
}

struct WorkspaceNavigationItem: Identifiable, Equatable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(projectID):\(resourceID)" }
    let kind: WorkspaceNavigationKind
    let projectID: String
    let resourceID: String
    let projectName: String
    let title: String
    let detail: String
    let status: String?
    let attentionCount: Int
    let archived: Bool
}

struct WorkspaceNavigationCatalog: Equatable, Sendable {
    let project: Project
    let conversations: [Conversation]
    let teams: [TeamSnapshot]
}

enum WorkspaceNavigationIndex {
    static let maximumResults = 100

    static func search(
        _ query: String,
        catalogs: [WorkspaceNavigationCatalog],
        limit: Int = maximumResults
    ) -> [WorkspaceNavigationItem] {
        let terms = normalized(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return [] }
        let boundedLimit = min(maximumResults, max(1, limit))
        return allItems(catalogs: catalogs)
            .compactMap { item -> (WorkspaceNavigationItem, Int)? in
                guard let score = score(item, terms: terms) else { return nil }
                return (item, score)
            }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 < right.1 }
                if left.0.kind != right.0.kind {
                    return kindRank(left.0.kind) < kindRank(right.0.kind)
                }
                let titleOrder = left.0.title.localizedStandardCompare(right.0.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return left.0.id < right.0.id
            }
            .prefix(boundedLimit)
            .map(\.0)
    }

    static func attentionItems(
        catalogs: [WorkspaceNavigationCatalog]
    ) -> [WorkspaceNavigationItem] {
        allItems(catalogs: catalogs)
            .filter { item in
                guard !item.archived else { return false }
                return switch item.kind {
                case .conversation:
                    item.status == "waiting_permission"
                case .team:
                    item.attentionCount > 0 || item.status == "needs_attention"
                case .project:
                    false
                }
            }
            .sorted { left, right in
                if left.kind != right.kind { return kindRank(left.kind) < kindRank(right.kind) }
                let projectOrder = left.projectName.localizedStandardCompare(right.projectName)
                if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }

    static func attentionCountsByProject(
        catalogs: [WorkspaceNavigationCatalog]
    ) -> [String: Int] {
        attentionItems(catalogs: catalogs).reduce(into: [:]) { counts, item in
            counts[item.projectID, default: 0] += max(1, item.attentionCount)
        }
    }

    static func eventChangesNavigation(_ kind: String) -> Bool {
        if kind.hasPrefix("team_") { return true }
        return [
            "run_started", "run_completed", "permission_requested", "permission_resolved",
            "elicitation_requested", "elicitation_resolved", "session_info",
            "conversation_updated", "conversation_archived", "conversation_deleted",
        ].contains(kind)
    }

    private static func allItems(
        catalogs: [WorkspaceNavigationCatalog]
    ) -> [WorkspaceNavigationItem] {
        catalogs.flatMap { catalog in
            let project = catalog.project
            let projectItem = WorkspaceNavigationItem(
                kind: .project,
                projectID: project.id,
                resourceID: project.id,
                projectName: project.name,
                title: project.name,
                detail: String(localized: "Project"),
                status: nil,
                attentionCount: 0,
                archived: false
            )
            let conversations = catalog.conversations
                .filter { $0.teamID == nil }
                .map { conversation in
                    WorkspaceNavigationItem(
                        kind: .conversation,
                        projectID: project.id,
                        resourceID: conversation.id,
                        projectName: project.name,
                        title: conversation.title,
                        detail: conversation.agentID.displayName,
                        status: conversation.latestRunStatus,
                        attentionCount: conversation.latestRunStatus == "waiting_permission" ? 1 : 0,
                        archived: conversation.archived == true
                    )
                }
            let teams = catalog.teams.map { snapshot in
                WorkspaceNavigationItem(
                    kind: .team,
                    projectID: project.id,
                    resourceID: snapshot.id,
                    projectName: project.name,
                    title: snapshot.team.title,
                    detail: snapshot.team.goal,
                    status: snapshot.team.status,
                    attentionCount: snapshot.team.status == "needs_attention"
                        ? max(1, snapshot.summary.needsAttention)
                        : snapshot.summary.needsAttention,
                    archived: false
                )
            }
            return [projectItem] + conversations + teams
        }
    }

    private static func score(
        _ item: WorkspaceNavigationItem,
        terms: [String]
    ) -> Int? {
        let title = normalized(item.title)
        let project = normalized(item.projectName)
        let detail = normalized(item.detail)
        let status = normalized(item.status ?? "")
        let combined = [title, project, detail, status].joined(separator: " ")
        guard terms.allSatisfy(combined.contains) else { return nil }

        let query = terms.joined(separator: " ")
        let base: Int
        if title == query {
            base = 0
        } else if title.hasPrefix(query) {
            base = 10
        } else if title.contains(query) {
            base = 20
        } else if project == query || project.hasPrefix(query) {
            base = 30
        } else if project.contains(query) {
            base = 40
        } else if detail.contains(query) {
            base = 50
        } else {
            base = 60
        }
        return max(0, base - min(item.attentionCount, 2))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ).lowercased()
    }

    private static func kindRank(_ kind: WorkspaceNavigationKind) -> Int {
        switch kind {
        case .project: 0
        case .conversation: 1
        case .team: 2
        }
    }
}
