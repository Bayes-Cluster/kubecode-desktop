import Foundation
import KubecodeKit

struct ProjectFileTreeRow: Identifiable, Hashable {
    var id: String { entry.path }
    let entry: FileEntry
    let depth: Int
    let isExpanded: Bool
    let hasLoadedChildren: Bool
}

struct ProjectFileTreeState: Equatable {
    private(set) var childrenByDirectory: [String: [FileEntry]] = [:]
    private(set) var expandedPaths: Set<String> = []

    mutating func replaceChildren(_ children: [FileEntry], of directory: String) {
        childrenByDirectory[directory] = children.sorted(by: Self.entryPrecedes)
    }

    mutating func expand(_ path: String) {
        expandedPaths.insert(path)
    }

    mutating func collapse(_ path: String) {
        expandedPaths.remove(path)
    }

    mutating func reset() {
        childrenByDirectory.removeAll()
        expandedPaths.removeAll()
    }

    mutating func invalidateLoadedChildren() {
        childrenByDirectory.removeAll()
    }

    mutating func discardSubtree(at path: String) {
        let prefix = path + "/"
        expandedPaths = Set(expandedPaths.filter { $0 != path && !$0.hasPrefix(prefix) })
        childrenByDirectory = Dictionary(uniqueKeysWithValues: childrenByDirectory.filter { key, _ in
            key != path && !key.hasPrefix(prefix)
        })
    }

    func hasLoadedChildren(of directory: String) -> Bool {
        childrenByDirectory[directory] != nil
    }

    func containsEntry(at path: String) -> Bool {
        childrenByDirectory.values.contains { entries in entries.contains { $0.path == path } }
    }

    func visibleRows(
        showHidden: Bool,
        showIgnored: Bool,
        showGenerated: Bool
    ) -> [ProjectFileTreeRow] {
        rows(
            in: "",
            depth: 0,
            showHidden: showHidden,
            showIgnored: showIgnored,
            showGenerated: showGenerated
        )
    }

    private func rows(
        in directory: String,
        depth: Int,
        showHidden: Bool,
        showIgnored: Bool,
        showGenerated: Bool
    ) -> [ProjectFileTreeRow] {
        (childrenByDirectory[directory] ?? []).flatMap { entry -> [ProjectFileTreeRow] in
            let isDirectory = entry.kind == "directory"
            let isVisible = (showHidden || entry.hidden != true)
                && (showIgnored || entry.ignored != true)
                && (showGenerated || entry.generated != true)
            guard isVisible else { return [] }

            let isExpanded = isDirectory && expandedPaths.contains(entry.path)
            let row = ProjectFileTreeRow(
                entry: entry,
                depth: depth,
                isExpanded: isExpanded,
                hasLoadedChildren: hasLoadedChildren(of: entry.path)
            )
            guard isExpanded else { return [row] }
            return [row] + rows(
                in: entry.path,
                depth: depth + 1,
                showHidden: showHidden,
                showIgnored: showIgnored,
                showGenerated: showGenerated
            )
        }
    }

    private static func entryPrecedes(_ left: FileEntry, _ right: FileEntry) -> Bool {
        if left.kind != right.kind { return left.kind == "directory" }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
}
