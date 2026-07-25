import Foundation
import KubecodeKit

enum SessionNavigationSort: String, CaseIterable, Identifiable {
    case activity
    case created
    case title

    var id: String { rawValue }
}

struct SessionNavigationPreferences: Equatable {
    var showArchived: Bool
    var agentID: AgentID?
    var sort: SessionNavigationSort

    init(
        showArchived: Bool = false,
        agentID: AgentID? = nil,
        sort: SessionNavigationSort = .activity
    ) {
        self.showArchived = showArchived
        self.agentID = agentID
        self.sort = sort
    }

    static let `default` = SessionNavigationPreferences()
}

struct SessionNavigationNode: Identifiable, Equatable {
    let conversation: Conversation
    let children: [SessionNavigationNode]

    var id: String { conversation.id }
    var outlineChildren: [SessionNavigationNode]? { children.isEmpty ? nil : children }
}

struct SessionNavigationSection: Identifiable, Equatable {
    enum ID: String, CaseIterable {
        case attention
        case running
        case today
        case week
        case older
        case archived

        var title: String {
            switch self {
            case .attention: String(localized: "Needs Attention")
            case .running: String(localized: "Running")
            case .today: String(localized: "Today")
            case .week: String(localized: "Previous 7 Days")
            case .older: String(localized: "Older")
            case .archived: String(localized: "Archived")
            }
        }
    }

    let id: ID
    let roots: [SessionNavigationNode]
}

enum SessionNavigationProjection {
    static func sections(
        _ conversations: [Conversation],
        preferences: SessionNavigationPreferences,
        now: Date = Date()
    ) -> [SessionNavigationSection] {
        let visible = conversations
            .filter { $0.teamID == nil }
            .filter { preferences.showArchived || $0.archived != true }
            .filter { preferences.agentID == nil || $0.agentID == preferences.agentID }
        let sorted = visible.sorted(by: comparator(preferences.sort))
        let visibleByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        var childrenByParent: [String: [Conversation]] = [:]
        var roots: [Conversation] = []

        for conversation in sorted {
            guard let parentID = conversation.parentConversationID,
                  let parent = visibleByID[parentID],
                  parent.archived == conversation.archived
            else {
                roots.append(conversation)
                continue
            }
            childrenByParent[parentID, default: []].append(conversation)
        }

        let nodes = roots.map {
            node(
                for: $0,
                childrenByParent: childrenByParent,
                sort: preferences.sort,
                ancestors: []
            )
        }
        let grouped = Dictionary(grouping: nodes) { section(for: $0, now: now) }
        return SessionNavigationSection.ID.allCases.compactMap { id in
            guard let roots = grouped[id], !roots.isEmpty else { return nil }
            return SessionNavigationSection(id: id, roots: roots)
        }
    }

    static func ancestorIDs(of conversationID: String, in conversations: [Conversation]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        var result: [String] = []
        var visited: Set<String> = [conversationID]
        var current = byID[conversationID]
        while let parentID = current?.parentConversationID,
              visited.insert(parentID).inserted,
              let parent = byID[parentID] {
            result.append(parent.id)
            current = parent
        }
        return result
    }

    private static func node(
        for conversation: Conversation,
        childrenByParent: [String: [Conversation]],
        sort: SessionNavigationSort,
        ancestors: Set<String>
    ) -> SessionNavigationNode {
        guard !ancestors.contains(conversation.id) else {
            return SessionNavigationNode(conversation: conversation, children: [])
        }
        let ancestors = ancestors.union([conversation.id])
        let children = (childrenByParent[conversation.id] ?? [])
            .sorted(by: comparator(sort))
            .map {
                node(
                    for: $0,
                    childrenByParent: childrenByParent,
                    sort: sort,
                    ancestors: ancestors
                )
            }
        return SessionNavigationNode(conversation: conversation, children: children)
    }

    private static func section(for node: SessionNavigationNode, now: Date) -> SessionNavigationSection.ID {
        if node.conversation.archived == true { return .archived }
        let statuses = flatten(node).compactMap(\.latestRunStatus)
        if statuses.contains("waiting_permission") { return .attention }
        if statuses.contains("running") { return .running }

        let activity = date(node.conversation.updatedAt ?? node.conversation.createdAt) ?? .distantPast
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = Locale.autoupdatingCurrent
        let age = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: activity),
            to: calendar.startOfDay(for: now)
        ).day ?? Int.max
        if age <= 0 { return .today }
        if age < 7 { return .week }
        return .older
    }

    private static func flatten(_ node: SessionNavigationNode) -> [Conversation] {
        [node.conversation] + node.children.flatMap(flatten)
    }

    private static func comparator(
        _ sort: SessionNavigationSort
    ) -> (Conversation, Conversation) -> Bool {
        switch sort {
        case .title:
            return {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .created:
            return { timestamp($0.createdAt) > timestamp($1.createdAt) }
        case .activity:
            return { timestamp($0.updatedAt ?? $0.createdAt) > timestamp($1.updatedAt ?? $1.createdAt) }
        }
    }

    private static func timestamp(_ value: String?) -> TimeInterval {
        date(value)?.timeIntervalSince1970 ?? 0
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }

        let sqlite = DateFormatter()
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        sqlite.calendar = Calendar(identifier: .gregorian)
        sqlite.timeZone = TimeZone(secondsFromGMT: 0)
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sqlite.date(from: value)
    }
}
