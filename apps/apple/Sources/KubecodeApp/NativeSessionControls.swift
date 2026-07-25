import Foundation
import KubecodeKit

enum NativeSessionControlKind: Hashable {
    case mode
    case config
}

struct NativeSessionControlChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let value: JSONValue
    let description: String?
}

struct NativeSessionControl: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: NativeSessionControlKind
    let currentValue: JSONValue
    let choices: [NativeSessionControlChoice]
    let isBoolean: Bool
    let category: String?

    var currentChoiceID: String? { currentValue.stringValue }
    var currentBoolValue: Bool? { currentValue.boolValue }
}

struct NativeSessionControls: Hashable {
    let mode: NativeSessionControl?
    let configs: [NativeSessionControl]

    static let empty = NativeSessionControls(mode: nil, configs: [])
}

enum NativeSessionControlProjection {
    static func controls(from state: AgentSessionState?) -> NativeSessionControls {
        guard let state else { return .empty }
        let advertisedMode = mode(from: state.currentMode)
        let configs = configs(from: state.configOptions)
        let fallbackIndex = configs.firstIndex(where: isModeConfig)
        let fallbackMode = fallbackIndex.map { configs[$0] }
        let projectedMode = advertisedMode ?? fallbackMode
        let advertisedSignature = advertisedMode.map(signature)
        var claimedIDs = Set<String>()
        if advertisedMode == nil, let projectedMode {
            claimedIDs.insert(projectedMode.id)
        }

        let projectedConfigs = configs.enumerated().compactMap { index, config -> NativeSessionControl? in
            if advertisedMode == nil, index == fallbackIndex { return nil }
            guard claimedIDs.insert(config.id).inserted else { return nil }
            if !config.isBoolean,
               let advertisedSignature,
               signature(config) == advertisedSignature {
                return nil
            }
            return config
        }
        return NativeSessionControls(mode: projectedMode, configs: projectedConfigs)
    }

    private static func mode(from value: JSONValue?) -> NativeSessionControl? {
        guard let object = value?.objectValue,
              let current = object["currentModeId"]?.stringValue
        else { return nil }
        let choices = choices(from: object["availableModes"])
        guard !choices.isEmpty else { return nil }
        return NativeSessionControl(
            id: "mode",
            name: String(localized: "Session Mode"),
            kind: .mode,
            currentValue: .string(current),
            choices: choices,
            isBoolean: false,
            category: "mode"
        )
    }

    private static func configs(from value: JSONValue?) -> [NativeSessionControl] {
        let values = value?.objectValue?["configOptions"]?.arrayValue ?? []
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let name = object["name"]?.stringValue
            else { return nil }
            if object["type"]?.stringValue == "boolean",
               let current = object["currentValue"]?.boolValue {
                return NativeSessionControl(
                    id: id,
                    name: name,
                    kind: .config,
                    currentValue: .bool(current),
                    choices: [],
                    isBoolean: true,
                    category: object["category"]?.stringValue
                )
            }
            let type = object["type"]?.stringValue
            guard type == nil || type == "select",
                  let current = object["currentValue"]?.stringValue
            else { return nil }
            let choices = choices(from: object["options"])
            guard !choices.isEmpty else { return nil }
            return NativeSessionControl(
                id: id,
                name: name,
                kind: .config,
                currentValue: .string(current),
                choices: choices,
                isBoolean: false,
                category: object["category"]?.stringValue
            )
        }
    }

    private static func choices(from value: JSONValue?) -> [NativeSessionControlChoice] {
        (value?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue,
                  let rawValue = object["value"] ?? object["id"],
                  let id = rawValue.stringValue
            else { return nil }
            return NativeSessionControlChoice(
                id: id,
                name: object["name"]?.stringValue ?? id,
                value: rawValue,
                description: object["description"]?.stringValue
            )
        }
    }

    private static func isModeConfig(_ control: NativeSessionControl) -> Bool {
        control.id.lowercased() == "mode" || control.category?.lowercased() == "mode"
    }

    private static func signature(_ control: NativeSessionControl) -> String {
        control.choices
            .map { "\($0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\u{0}\($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
            .sorted()
            .joined(separator: "\u{1}")
    }
}
