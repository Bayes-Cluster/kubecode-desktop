import Foundation
import KubecodeKit

public struct PermissionChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let kind: String
}

public struct PendingPermission: Identifiable, Hashable, Sendable {
    public var id: String { requestID }
    public let requestID: String
    public let tool: String
    public let options: [PermissionChoice]
}

public struct ElicitationOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public enum ElicitationPropertyKind: String, Hashable, Sendable {
    case boolean, integer, number, string
}

public struct ElicitationProperty: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public let kind: ElicitationPropertyKind
    public let required: Bool
    public let options: [ElicitationOption]
    public let defaultValue: JSONValue
}

public struct PendingElicitation: Identifiable, Hashable, Sendable {
    public var id: String { requestID }
    public let requestID: String
    public let message: String
    public let properties: [ElicitationProperty]
}

public enum ElicitationResponseBuilder {
    public static func isComplete(
        _ elicitation: PendingElicitation,
        answers: [String: JSONValue]
    ) -> Bool {
        content(elicitation, answers: answers) != nil
    }

    public static func content(
        _ elicitation: PendingElicitation,
        answers: [String: JSONValue]
    ) -> [String: JSONValue]? {
        var content: [String: JSONValue] = [:]
        for property in elicitation.properties {
            let answer = answers[property.id] ?? property.defaultValue
            switch response(for: property, answer: answer) {
            case let .value(value):
                content[property.id] = value
            case .omitted:
                break
            case .invalid:
                return nil
            }
        }
        return content
    }

    public static func isValid(
        _ property: ElicitationProperty,
        answer: JSONValue?
    ) -> Bool {
        switch response(for: property, answer: answer ?? property.defaultValue) {
        case .value, .omitted: true
        case .invalid: false
        }
    }

    public static func editableText(
        _ property: ElicitationProperty,
        answer: JSONValue?
    ) -> String {
        switch answer ?? property.defaultValue {
        case let .string(value):
            value
        case let .number(value):
            property.kind == .integer && value.rounded() == value
                ? String(format: "%.0f", value)
                : String(value)
        case let .bool(value):
            String(value)
        case .array, .object, .null:
            ""
        }
    }

    private enum FieldResponse {
        case value(JSONValue)
        case omitted
        case invalid
    }

    private static func response(
        for property: ElicitationProperty,
        answer: JSONValue
    ) -> FieldResponse {
        switch property.kind {
        case .boolean:
            if case .bool = answer { return .value(answer) }
            if case .bool = property.defaultValue { return .value(property.defaultValue) }
            return .value(.bool(false))

        case .string:
            guard case let .string(value) = answer else { return .invalid }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return property.required ? .invalid : .omitted
            }
            return .value(.string(value))

        case .integer:
            if case let .number(value) = answer,
               value.isFinite,
               value.rounded() == value {
                return .value(.number(value))
            }
            guard case let .string(value) = answer else { return .invalid }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return property.required ? .invalid : .omitted }
            guard let integer = Int(trimmed) else { return .invalid }
            return .value(.number(Double(integer)))

        case .number:
            if case let .number(value) = answer, value.isFinite {
                return .value(.number(value))
            }
            guard case let .string(value) = answer else { return .invalid }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return property.required ? .invalid : .omitted }
            guard let number = Double(trimmed), number.isFinite else { return .invalid }
            return .value(.number(number))
        }
    }
}

public struct ToolActivity: Identifiable, Hashable, Sendable {
    public let id: String
    public let runID: String
    public let title: String
    public let status: String
    public let input: String?
    public let output: String?
}

public struct SideQuestion: Identifiable, Hashable, Sendable {
    public let id: String
    public let runID: String
    public let question: String
    public let status: String
    public let answer: String?
    public let error: String?
}

public struct AgentInteractionState: Hashable, Sendable {
    public var pendingPermission: PendingPermission?
    public var pendingElicitation: PendingElicitation?
    public var tools: [ToolActivity]
    public var sideQuestions: [SideQuestion]

    public init(
        pendingPermission: PendingPermission? = nil,
        pendingElicitation: PendingElicitation? = nil,
        tools: [ToolActivity] = [],
        sideQuestions: [SideQuestion] = []
    ) {
        self.pendingPermission = pendingPermission
        self.pendingElicitation = pendingElicitation
        self.tools = tools
        self.sideQuestions = sideQuestions
    }
}

public enum AgentInteractionReducer {
    public static func reduce(_ events: [AgentEvent]) -> AgentInteractionState {
        events.reduce(into: AgentInteractionState()) { state, event in
            apply(kind: event.kind, payload: event.payload, runID: event.runID, sequence: event.sequence, to: &state)
        }
    }

    public static func apply(_ event: WorkspaceEvent, to state: inout AgentInteractionState) {
        apply(
            kind: event.kind,
            payload: event.payload,
            runID: event.runID ?? "",
            sequence: event.id,
            to: &state
        )
    }

    public static func apply(_ event: AgentEvent, to state: inout AgentInteractionState) {
        apply(
            kind: event.kind,
            payload: event.payload,
            runID: event.runID,
            sequence: event.sequence,
            to: &state
        )
    }

    private static func apply(
        kind: String,
        payload: [String: JSONValue],
        runID: String,
        sequence: Int,
        to state: inout AgentInteractionState
    ) {
        switch kind {
        case "permission_requested":
            state.pendingPermission = permission(payload)
        case "permission_resolved":
            if resolves(payload, currentID: state.pendingPermission?.requestID) { state.pendingPermission = nil }
        case "elicitation_requested":
            state.pendingElicitation = elicitation(payload)
        case "elicitation_resolved":
            if resolves(payload, currentID: state.pendingElicitation?.requestID) { state.pendingElicitation = nil }
        case "tool_started", "tool_updated", "tool_completed":
            upsertTool(payload, runID: runID, sequence: sequence, in: &state)
        case "side_question_started", "side_question_completed", "side_question_failed":
            upsertSideQuestion(kind: kind, payload: payload, runID: runID, in: &state)
        default:
            break
        }
    }

    private static func permission(_ payload: [String: JSONValue]) -> PendingPermission? {
        guard payload["reviewer"]?.stringValue != "leader",
              let requestID = payload["request_id"]?.stringValue,
              let values = payload["options"]?.arrayValue
        else { return nil }
        let options = values.compactMap { value -> PermissionChoice? in
            guard let option = value.objectValue,
                  let id = option["id"]?.stringValue,
                  let label = option["label"]?.stringValue
            else { return nil }
            return PermissionChoice(id: id, label: label, kind: option["kind"]?.stringValue ?? "")
        }
        return PendingPermission(
            requestID: requestID,
            tool: payload["tool"]?.stringValue ?? "Tool",
            options: options
        )
    }

    private static func elicitation(_ payload: [String: JSONValue]) -> PendingElicitation? {
        guard let requestID = payload["request_id"]?.stringValue,
              let message = payload["message"]?.stringValue,
              let schema = payload["requestedSchema"]?.objectValue,
              let definitions = schema["properties"]?.objectValue
        else { return nil }
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let properties = definitions.keys.sorted().compactMap { id -> ElicitationProperty? in
            guard let property = definitions[id]?.objectValue,
                  let rawKind = property["type"]?.stringValue,
                  let kind = ElicitationPropertyKind(rawValue: rawKind)
            else { return nil }
            let options: [ElicitationOption]
            if let oneOf = property["oneOf"]?.arrayValue {
                options = oneOf.compactMap { item in
                    guard let value = item.objectValue,
                          let id = value["const"]?.stringValue
                    else { return nil }
                    return ElicitationOption(id: id, name: value["title"]?.stringValue ?? id)
                }
            } else {
                options = property["enum"]?.arrayValue?.compactMap(\.stringValue).map {
                    ElicitationOption(id: $0, name: $0)
                } ?? []
            }
            let defaultValue = property["default"]
                ?? (kind == .boolean ? .bool(false) : options.first.map { .string($0.id) } ?? .string(""))
            return ElicitationProperty(
                id: id,
                label: property["title"]?.stringValue ?? id,
                description: property["description"]?.stringValue ?? "",
                kind: kind,
                required: required.contains(id),
                options: options,
                defaultValue: defaultValue
            )
        }
        return PendingElicitation(requestID: requestID, message: message, properties: properties)
    }

    private static func resolves(_ payload: [String: JSONValue], currentID: String?) -> Bool {
        guard let eventID = payload["request_id"]?.stringValue else { return true }
        return eventID == currentID
    }

    private static func upsertTool(
        _ payload: [String: JSONValue],
        runID: String,
        sequence: Int,
        in state: inout AgentInteractionState
    ) {
        let id = payload["tool_id"]?.stringValue ?? "tool-\(sequence)"
        let old = state.tools.first { $0.id == id }
        let item = ToolActivity(
            id: id,
            runID: runID,
            title: payload["tool"]?.stringValue ?? old?.title ?? "Tool",
            status: payload["status"]?.stringValue ?? old?.status ?? "pending",
            input: display(payload["input"]) ?? old?.input,
            output: display(payload["output"]) ?? old?.output
        )
        if let index = state.tools.firstIndex(where: { $0.id == id }) { state.tools[index] = item }
        else { state.tools.append(item) }
    }

    private static func upsertSideQuestion(
        kind: String,
        payload: [String: JSONValue],
        runID: String,
        in state: inout AgentInteractionState
    ) {
        guard let id = payload["id"]?.stringValue else { return }
        let old = state.sideQuestions.first { $0.id == id }
        let status = kind == "side_question_completed" ? "completed"
            : kind == "side_question_failed" ? "failed" : "pending"
        let item = SideQuestion(
            id: id,
            runID: payload["run_id"]?.stringValue ?? old?.runID ?? runID,
            question: payload["question"]?.stringValue ?? old?.question ?? "",
            status: status,
            answer: payload["answer"]?.stringValue ?? old?.answer,
            error: payload["message"]?.stringValue ?? old?.error
        )
        if let index = state.sideQuestions.firstIndex(where: { $0.id == id }) { state.sideQuestions[index] = item }
        else { state.sideQuestions.append(item) }
    }

    private static func display(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(value): return value
        case let .number(value): return String(value)
        case let .bool(value): return String(value)
        case .null: return nil
        case .object, .array:
            return (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? nil
        }
    }
}
