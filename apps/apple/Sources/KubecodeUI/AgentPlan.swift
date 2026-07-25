import KubecodeKit

public enum AgentPlanEntryStatus: String, Hashable, Sendable {
    case completed
    case inProgress = "in_progress"
    case pending
}

public struct AgentPlanEntry: Identifiable, Hashable, Sendable {
    public var id: String { "\(status.rawValue):\(priority):\(content)" }
    public let content: String
    public let priority: String
    public let status: AgentPlanEntryStatus

    public init(content: String, priority: String, status: AgentPlanEntryStatus) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

public enum AgentPlanProjection {
    public static func entries(from value: JSONValue?) -> [AgentPlanEntry] {
        guard let plan = value?.objectValue else { return [] }
        let nestedPlan = plan["plan"]?.objectValue
        let wrappedItems = plan["items"]?.objectValue
        let values = plan["entries"]?.arrayValue
            ?? nestedPlan?["entries"]?.arrayValue
            ?? wrappedItems?["entries"]?.arrayValue
            ?? []
        return values.compactMap { value in
            guard let entry = value.objectValue,
                  let rawContent = entry["content"]?.stringValue
            else { return nil }
            let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return AgentPlanEntry(
                content: content,
                priority: entry["priority"]?.stringValue ?? "medium",
                status: status(entry["status"]?.stringValue)
            )
        }
    }

    private static func status(_ value: String?) -> AgentPlanEntryStatus {
        switch value {
        case "completed": .completed
        case "in_progress", "inProgress": .inProgress
        default: .pending
        }
    }
}
