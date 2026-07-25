import Foundation

enum TerminalSplitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

indirect enum TerminalLayoutState: Codable, Equatable, Sendable {
    case leaf(terminalID: String)
    case split(TerminalSplitState)

    var terminalIDs: [String] {
        switch self {
        case let .leaf(terminalID):
            [terminalID]
        case let .split(split):
            split.first.terminalIDs + split.second.terminalIDs
        }
    }

    var firstTerminalID: String {
        switch self {
        case let .leaf(terminalID): terminalID
        case let .split(split): split.first.firstTerminalID
        }
    }

    func contains(_ terminalID: String) -> Bool {
        switch self {
        case let .leaf(candidate): candidate == terminalID
        case let .split(split):
            split.first.contains(terminalID) || split.second.contains(terminalID)
        }
    }

    func replacingLeaf(_ terminalID: String, with replacement: TerminalLayoutState) -> Self {
        switch self {
        case let .leaf(candidate):
            candidate == terminalID ? replacement : self
        case let .split(split):
            .split(split.replacingLeaf(terminalID, with: replacement))
        }
    }

    func replacingTerminal(_ terminalID: String, with replacementID: String) -> Self {
        replacingLeaf(terminalID, with: .leaf(terminalID: replacementID))
    }

    func removing(_ terminalID: String) -> Self? {
        switch self {
        case let .leaf(candidate):
            return candidate == terminalID ? nil : self
        case let .split(split):
            let first = split.first.removing(terminalID)
            let second = split.second.removing(terminalID)
            return switch (first, second) {
            case (nil, nil): nil
            case let (first?, nil): first
            case let (nil, second?): second
            case let (first?, second?):
                .split(TerminalSplitState(
                    id: split.id,
                    axis: split.axis,
                    ratio: split.ratio,
                    first: first,
                    second: second
                ))
            }
        }
    }

    func updatingRatio(splitID: String, ratio: Double) -> Self {
        switch self {
        case .leaf:
            self
        case let .split(split):
            .split(split.updatingRatio(splitID: splitID, ratio: ratio))
        }
    }

    fileprivate func reconciled(
        validTerminalIDs: Set<String>,
        assignedTerminalIDs: inout Set<String>
    ) -> Self? {
        switch self {
        case let .leaf(terminalID):
            guard validTerminalIDs.contains(terminalID),
                  assignedTerminalIDs.insert(terminalID).inserted
            else { return nil }
            return self
        case let .split(split):
            let first = split.first.reconciled(
                validTerminalIDs: validTerminalIDs,
                assignedTerminalIDs: &assignedTerminalIDs
            )
            let second = split.second.reconciled(
                validTerminalIDs: validTerminalIDs,
                assignedTerminalIDs: &assignedTerminalIDs
            )
            return switch (first, second) {
            case (nil, nil): nil
            case let (first?, nil): first
            case let (nil, second?): second
            case let (first?, second?):
                .split(TerminalSplitState(
                    id: split.id,
                    axis: split.axis,
                    ratio: Self.clampedRatio(split.ratio),
                    first: first,
                    second: second
                ))
            }
        }
    }

    static func clampedRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(0.95, max(0.05, ratio))
    }
}

struct TerminalSplitState: Codable, Equatable, Sendable {
    let id: String
    let axis: TerminalSplitAxis
    let ratio: Double
    let first: TerminalLayoutState
    let second: TerminalLayoutState

    func replacingLeaf(
        _ terminalID: String,
        with replacement: TerminalLayoutState
    ) -> Self {
        Self(
            id: id,
            axis: axis,
            ratio: ratio,
            first: first.replacingLeaf(terminalID, with: replacement),
            second: second.replacingLeaf(terminalID, with: replacement)
        )
    }

    func updatingRatio(splitID: String, ratio nextRatio: Double) -> Self {
        if id == splitID {
            return Self(
                id: id,
                axis: axis,
                ratio: TerminalLayoutState.clampedRatio(nextRatio),
                first: first,
                second: second
            )
        }
        return Self(
            id: id,
            axis: axis,
            ratio: ratio,
            first: first.updatingRatio(splitID: splitID, ratio: nextRatio),
            second: second.updatingRatio(splitID: splitID, ratio: nextRatio)
        )
    }
}

struct TerminalGroupState: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var activeTerminalID: String
    var layout: TerminalLayoutState
}

struct TerminalWorkspaceState: Codable, Equatable, Sendable {
    let version: Int
    var activeGroupID: String?
    var groups: [TerminalGroupState]

    init(version: Int = 1, activeGroupID: String?, groups: [TerminalGroupState]) {
        self.version = version
        self.activeGroupID = activeGroupID
        self.groups = groups
    }

    static let empty = Self(activeGroupID: nil, groups: [])

    var activeGroup: TerminalGroupState? {
        groups.first { $0.id == activeGroupID }
    }

    var activeTerminalID: String? { activeGroup?.activeTerminalID }

    var terminalIDs: [String] { groups.flatMap { $0.layout.terminalIDs } }

    mutating func addGroup(terminalID: String, id: String = UUID().uuidString) {
        if terminalIDs.contains(terminalID) {
            activateTerminal(terminalID)
            return
        }
        groups.append(TerminalGroupState(
            id: id,
            activeTerminalID: terminalID,
            layout: .leaf(terminalID: terminalID)
        ))
        activeGroupID = id
    }

    @discardableResult
    mutating func split(
        terminalID: String,
        with createdTerminalID: String,
        axis: TerminalSplitAxis,
        splitID: String = UUID().uuidString
    ) -> Bool {
        guard terminalID != createdTerminalID,
              let groupIndex = groups.firstIndex(where: { $0.layout.contains(terminalID) }),
              !terminalIDs.contains(createdTerminalID)
        else { return false }
        let replacement = TerminalLayoutState.split(TerminalSplitState(
            id: splitID,
            axis: axis,
            ratio: 0.5,
            first: .leaf(terminalID: terminalID),
            second: .leaf(terminalID: createdTerminalID)
        ))
        groups[groupIndex].layout = groups[groupIndex].layout.replacingLeaf(
            terminalID,
            with: replacement
        )
        groups[groupIndex].activeTerminalID = createdTerminalID
        activeGroupID = groups[groupIndex].id
        return true
    }

    mutating func activateTerminal(_ terminalID: String) {
        guard let index = groups.firstIndex(where: { $0.layout.contains(terminalID) }) else { return }
        groups[index].activeTerminalID = terminalID
        activeGroupID = groups[index].id
    }

    mutating func activateGroup(_ groupID: String) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        activeGroupID = groupID
    }

    mutating func removeTerminal(_ terminalID: String) {
        groups = groups.compactMap { group in
            guard let layout = group.layout.removing(terminalID) else { return nil }
            return TerminalGroupState(
                id: group.id,
                activeTerminalID: layout.contains(group.activeTerminalID)
                    ? group.activeTerminalID
                    : layout.firstTerminalID,
                layout: layout
            )
        }
        if !groups.contains(where: { $0.id == activeGroupID }) {
            activeGroupID = groups.first?.id
        }
    }

    mutating func replaceTerminal(_ terminalID: String, with replacementID: String) {
        guard terminalID != replacementID else { return }
        groups = groups.map { group in
            TerminalGroupState(
                id: group.id,
                activeTerminalID: group.activeTerminalID == terminalID
                    ? replacementID
                    : group.activeTerminalID,
                layout: group.layout.replacingTerminal(terminalID, with: replacementID)
            )
        }
    }

    mutating func updateRatio(splitID: String, ratio: Double) {
        groups = groups.map { group in
            var updated = group
            updated.layout = group.layout.updatingRatio(splitID: splitID, ratio: ratio)
            return updated
        }
    }

    mutating func moveActiveGroup(by offset: Int) {
        guard let activeGroupID,
              let index = groups.firstIndex(where: { $0.id == activeGroupID })
        else { return }
        let destination = min(groups.count - 1, max(0, index + offset))
        guard destination != index else { return }
        let group = groups.remove(at: index)
        groups.insert(group, at: destination)
    }

    func reconciled(with terminalIDs: [String]) -> Self {
        let validTerminalIDs = Set(terminalIDs)
        var assignedTerminalIDs = Set<String>()
        var reconciledGroups = groups.compactMap { group -> TerminalGroupState? in
            guard let layout = group.layout.reconciled(
                validTerminalIDs: validTerminalIDs,
                assignedTerminalIDs: &assignedTerminalIDs
            ) else { return nil }
            return TerminalGroupState(
                id: group.id,
                activeTerminalID: layout.contains(group.activeTerminalID)
                    ? group.activeTerminalID
                    : layout.firstTerminalID,
                layout: layout
            )
        }
        for terminalID in terminalIDs where assignedTerminalIDs.insert(terminalID).inserted {
            reconciledGroups.append(TerminalGroupState(
                id: "terminal-group-\(terminalID)",
                activeTerminalID: terminalID,
                layout: .leaf(terminalID: terminalID)
            ))
        }
        let nextActiveGroupID = reconciledGroups.contains(where: { $0.id == activeGroupID })
            ? activeGroupID
            : reconciledGroups.first?.id
        return Self(activeGroupID: nextActiveGroupID, groups: reconciledGroups)
    }
}

struct TerminalWorkspaceStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(
        windowID: String,
        projectID: String,
        terminalIDs: [String]
    ) -> TerminalWorkspaceState {
        let stored = encodedWorkspace(windowID: windowID, projectID: projectID)
            .flatMap { try? decoder.decode(TerminalWorkspaceState.self, from: $0) }
            ?? .empty
        return stored.reconciled(with: terminalIDs)
    }

    func save(_ workspace: TerminalWorkspaceState, windowID: String, projectID: String) {
        guard let data = try? encoder.encode(workspace) else { return }
        defaults.set(data, forKey: storageKey(windowID: windowID, projectID: projectID))
    }

    func encodedWorkspace(windowID: String, projectID: String) -> Data? {
        defaults.data(forKey: storageKey(windowID: windowID, projectID: projectID))
    }

    private func storageKey(windowID: String, projectID: String) -> String {
        "terminal.workspace.v1.\(encodedKeyPart(windowID)).\(encodedKeyPart(projectID))"
    }

    private func encodedKeyPart(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
