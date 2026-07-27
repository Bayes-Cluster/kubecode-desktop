import Foundation
import KubecodeKit

public enum TranscriptRole: Hashable, Sendable {
    case user
    case agent
    case thinking
    case system
    case status
    case tool
}

public struct TranscriptItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let role: TranscriptRole
    public let text: String
    public let eventKind: String?
    public let runID: String?
    public let detail: String?
    public let status: String?
    public let messageID: String?

    public init(
        id: String,
        role: TranscriptRole,
        text: String,
        eventKind: String? = nil,
        runID: String? = nil,
        detail: String? = nil,
        status: String? = nil,
        messageID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.eventKind = eventKind
        self.runID = runID
        self.detail = detail
        self.status = status
        self.messageID = messageID
    }
}

public struct TranscriptRunActivity: Identifiable, Hashable, Sendable {
    public let runID: String
    public let items: [TranscriptItem]
    public let isActive: Bool
    public let status: String?

    public var id: String { "run-\(runID)-activity" }
    public var stepCount: Int { items.count }
    public var toolCount: Int { items.filter { $0.role == .tool }.count }
    public var defaultExpanded: Bool { false }

    public init(
        runID: String,
        items: [TranscriptItem],
        isActive: Bool,
        status: String?
    ) {
        self.runID = runID
        self.items = items
        self.isActive = isActive
        self.status = status
    }

    public func recentItems(limit: Int) -> [TranscriptItem] {
        guard limit > 0, items.count > limit else { return items }
        return Array(items.suffix(limit))
    }

    public func hiddenItemCount(limit: Int) -> Int {
        max(0, items.count - max(0, limit))
    }
}

public enum TranscriptRunOutputPhase: Hashable, Sendable {
    case update
    case final
    case partial
}

public struct TranscriptRunOutput: Identifiable, Hashable, Sendable {
    public static let activePreviewLimit = 220

    public let runID: String
    public let text: String
    public let phase: TranscriptRunOutputPhase
    public let sourceItemID: String
    public let sourceMessageID: String?

    public var id: String { "run-\(runID)-output" }

    public init(
        runID: String,
        text: String,
        phase: TranscriptRunOutputPhase,
        sourceItemID: String,
        sourceMessageID: String? = nil
    ) {
        self.runID = runID
        self.text = text
        self.phase = phase
        self.sourceItemID = sourceItemID
        self.sourceMessageID = sourceMessageID
    }
}

public struct TranscriptRunPresentation: Identifiable, Hashable, Sendable {
    public let runID: String
    public let userItems: [TranscriptItem]
    public let activity: TranscriptRunActivity?
    public let output: TranscriptRunOutput?
    public let trailingItems: [TranscriptItem]

    public var id: String { "run-\(runID)-presentation" }

    public init(
        runID: String,
        userItems: [TranscriptItem],
        activity: TranscriptRunActivity?,
        output: TranscriptRunOutput?,
        trailingItems: [TranscriptItem]
    ) {
        self.runID = runID
        self.userItems = userItems
        self.activity = activity
        self.output = output
        self.trailingItems = trailingItems
    }
}

public enum TranscriptPresentationEntry: Identifiable, Hashable, Sendable {
    case item(TranscriptItem)
    case run(TranscriptRunPresentation)

    public var id: String {
        switch self {
        case let .item(item): item.id
        case let .run(run): run.id
        }
    }
}

public enum TranscriptPresentation {
    public static func entries(
        items: [TranscriptItem],
        activeRunID: String?
    ) -> [TranscriptPresentationEntry] {
        var entries: [TranscriptPresentationEntry] = []
        var index = items.startIndex

        while index < items.endIndex {
            guard let runID = items[index].runID else {
                entries.append(.item(items[index]))
                index = items.index(after: index)
                continue
            }

            var runItems: [TranscriptItem] = []
            while index < items.endIndex, items[index].runID == runID {
                runItems.append(items[index])
                index = items.index(after: index)
            }
            entries.append(.run(projectedRun(
                for: runItems,
                runID: runID,
                isActive: activeRunID == runID
            )))
        }
        return entries
    }

    private static func projectedRun(
        for items: [TranscriptItem],
        runID: String,
        isActive: Bool
    ) -> TranscriptRunPresentation {
        let status = items.last(where: { $0.role == .status })?.status
        let activityItems = items.filter { item in
            switch item.role {
            case .thinking, .tool: true
            case .agent, .user, .system, .status: false
            }
        }
        let activity = isActive || !activityItems.isEmpty
            ? TranscriptRunActivity(
                runID: runID,
                items: activityItems,
                isActive: isActive,
                status: status
            )
            : nil
        let output = items.last(where: { $0.role == .agent }).map { item in
            let phase: TranscriptRunOutputPhase
            let text: String
            if status == "completed" {
                phase = .final
                text = item.text
            } else if status != nil || !isActive {
                phase = .partial
                text = item.text
            } else {
                phase = .update
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = String(trimmed.prefix(TranscriptRunOutput.activePreviewLimit))
            }
            return TranscriptRunOutput(
                runID: runID,
                text: text,
                phase: phase,
                sourceItemID: item.id,
                sourceMessageID: item.messageID
            )
        }
        let trailingItems = items.filter { item in
            item.role == .system || (item.role == .status && item.status != "completed")
        }
        return TranscriptRunPresentation(
            runID: runID,
            userItems: items.filter { $0.role == .user },
            activity: activity,
            output: output,
            trailingItems: trailingItems
        )
    }
}

public enum TranscriptReducer {
    public static func items(run: AgentRun, events: [AgentEvent]) -> [TranscriptItem] {
        var items = [TranscriptItem(
            id: "run-\(run.id)-user",
            role: .user,
            text: run.message,
            runID: run.id
        )]
        for event in events { apply(event: event, runID: run.id, to: &items) }
        if let error = run.error {
            items.append(TranscriptItem(
                id: "run-\(run.id)-error",
                role: .system,
                text: error,
                eventKind: "error"
                , runID: run.id
            ))
        }
        appendRunStatus(run.status, runID: run.id, to: &items, moveToEnd: true)
        return items
    }

    public static func applyStreamingDelta(
        _ event: WorkspaceEvent,
        to items: inout [TranscriptItem]
    ) {
        guard let runID = event.runID else { return }
        apply(kind: event.kind, payload: event.payload, runID: runID, fallbackID: "workspace-\(event.id)", to: &items)
    }

    public static func applyStreamingEvent(_ event: AgentEvent, to items: inout [TranscriptItem]) {
        apply(event: event, runID: event.runID, to: &items)
    }

    public static func applyStreamingEvents(
        _ events: [AgentEvent],
        to items: inout [TranscriptItem]
    ) {
        for event in events {
            apply(event: event, runID: event.runID, to: &items)
        }
    }

    private static func apply(event: AgentEvent, runID: String, to items: inout [TranscriptItem]) {
        apply(kind: event.kind, payload: event.payload, runID: runID, fallbackID: event.id, to: &items)
    }

    private static func apply(
        kind: String,
        payload: [String: JSONValue],
        runID: String,
        fallbackID: String,
        to items: inout [TranscriptItem]
    ) {
        if kind == "run_completed" {
            if let status = payload["status"]?.stringValue {
                appendRunStatus(status, runID: runID, to: &items)
            }
            return
        }
        let ignored = [
            "run_started", "usage", "available_commands",
            "current_mode", "config_options", "session_info",
        ]
        guard !ignored.contains(kind) else { return }
        if ["tool_started", "tool_updated", "tool_completed"].contains(kind) {
            let toolID = payload["tool_id"]?.stringValue ?? fallbackID
            let id = "run-\(runID)-tool-\(toolID)"
            let old = items.first { $0.id == id }
            let title = payload["tool"]?.stringValue ?? old?.text ?? "Tool"
            let input = display(payload["input"])
            let output = display(payload["output"])
            let detail = [
                input.map { "Input\n\($0)" },
                output.map { "Output\n\($0)" },
            ].compactMap { $0 }.joined(separator: "\n\n")
            let item = TranscriptItem(
                id: id,
                role: .tool,
                text: title,
                eventKind: kind,
                runID: runID,
                detail: detail.isEmpty ? old?.detail : detail,
                status: payload["status"]?.stringValue ?? old?.status
            )
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = item }
            else { items.append(item) }
            return
        }
        guard let text = eventText(payload), !text.isEmpty else { return }
        if kind == "text_delta" || kind == "thinking_delta" {
            let messageID = payload["messageId"]?.stringValue
                ?? payload["message_id"]?.stringValue
                ?? "default"
            let id = "run-\(runID)-\(kind)-\(messageID)"
            if let index = items.firstIndex(where: { $0.id == id }) {
                let current = items[index]
                items[index] = TranscriptItem(
                    id: id,
                    role: current.role,
                    text: current.text + text,
                    eventKind: kind
                    , runID: runID,
                    messageID: messageID
                )
            } else if let last = items.last,
                      last.runID == runID,
                      last.role == (kind == "thinking_delta" ? .thinking : .agent) {
                let separator = last.messageID == messageID ? "" : "\n\n"
                items[items.count - 1] = TranscriptItem(
                    id: last.id,
                    role: last.role,
                    text: last.text + separator + text,
                    eventKind: kind,
                    runID: runID,
                    messageID: messageID
                )
            } else {
                items.append(TranscriptItem(
                    id: id,
                    role: kind == "thinking_delta" ? .thinking : .agent,
                    text: text,
                    eventKind: kind
                    , runID: runID,
                    messageID: messageID
                ))
            }
            return
        }
        items.append(TranscriptItem(
            id: fallbackID,
            role: kind.contains("user") ? .user : kind == "error" ? .system : .agent,
            text: text,
            eventKind: kind
            , runID: runID
        ))
    }

    private static func appendRunStatus(
        _ status: String,
        runID: String,
        to items: inout [TranscriptItem],
        moveToEnd: Bool = false
    ) {
        guard ["completed", "failed", "cancelled", "timed_out", "interrupted"].contains(status)
        else { return }
        let id = "run-\(runID)-status"
        let item = TranscriptItem(
            id: id,
            role: .status,
            text: status,
            eventKind: "run_completed",
            runID: runID,
            status: status
        )
        if let index = items.firstIndex(where: { $0.id == id }) {
            if moveToEnd {
                items.remove(at: index)
                items.append(item)
            } else {
                items[index] = item
            }
        } else {
            items.append(item)
        }
    }

    private static func eventText(_ payload: [String: JSONValue]) -> String? {
        let keys = ["text", "content", "message", "title", "description"]
        return keys.lazy.compactMap { payload[$0]?.stringValue }.first
    }

    private static func display(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(value): return value
        case let .number(value): return String(value)
        case let .bool(value): return String(value)
        case .null: return nil
        case .object, .array:
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
