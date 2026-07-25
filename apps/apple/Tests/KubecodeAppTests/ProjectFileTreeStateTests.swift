import Foundation
import Testing
import KubecodeKit
@testable import KubecodeApp

@Suite
struct ProjectFileTreeStateTests {
    @Test func expanded_directories_reveal_sorted_children_at_the_correct_depth() throws {
        var state = ProjectFileTreeState()
        state.replaceChildren([
            try entry(name: "README.md", path: "README.md", kind: "file"),
            try entry(name: "Sources", path: "Sources", kind: "directory"),
        ], of: "")
        state.replaceChildren([
            try entry(name: "App.swift", path: "Sources/App.swift", kind: "file"),
            try entry(name: "Core", path: "Sources/Core", kind: "directory"),
        ], of: "Sources")

        state.expand("Sources")

        let rows = state.visibleRows(showHidden: false, showIgnored: false, showGenerated: false)
        #expect(rows.map(\.entry.path) == ["Sources", "Sources/Core", "Sources/App.swift", "README.md"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0])
        #expect(rows.first?.isExpanded == true)

        state.collapse("Sources")
        #expect(state.visibleRows(showHidden: false, showIgnored: false, showGenerated: false).map(\.entry.path) == [
            "Sources", "README.md",
        ])
    }

    @Test func filters_apply_to_files_and_directories_at_every_loaded_level() throws {
        var state = ProjectFileTreeState()
        state.replaceChildren([
            try entry(name: ".config", path: ".config", kind: "directory", hidden: true),
            try entry(name: ".env", path: ".env", kind: "file", hidden: true),
            try entry(name: "Build.swift", path: "Build.swift", kind: "file", ignored: true),
            try entry(name: "node_modules", path: "node_modules", kind: "directory", generated: true),
        ], of: "")

        #expect(state.visibleRows(showHidden: false, showIgnored: false, showGenerated: false).isEmpty)
        #expect(state.visibleRows(showHidden: true, showIgnored: false, showGenerated: false).map(\.entry.path) == [
            ".config", ".env",
        ])
        #expect(state.visibleRows(showHidden: true, showIgnored: true, showGenerated: false).map(\.entry.path) == [
            ".config", ".env", "Build.swift",
        ])
        #expect(state.visibleRows(showHidden: true, showIgnored: true, showGenerated: true).map(\.entry.path) == [
            ".config", "node_modules", ".env", "Build.swift",
        ])
    }

    @Test func invalidation_preserves_expansion_but_removes_stale_children() throws {
        var state = ProjectFileTreeState()
        state.replaceChildren([
            try entry(name: "Sources", path: "Sources", kind: "directory"),
        ], of: "")
        state.replaceChildren([
            try entry(name: "Old.swift", path: "Sources/Old.swift", kind: "file"),
        ], of: "Sources")
        state.expand("Sources")

        state.invalidateLoadedChildren()

        #expect(state.expandedPaths == ["Sources"])
        #expect(!state.hasLoadedChildren(of: "Sources"))
        #expect(state.visibleRows(showHidden: false, showIgnored: false, showGenerated: false).isEmpty)
    }

    @Test func discarding_a_subtree_removes_nested_expansion_and_cached_children() throws {
        var state = ProjectFileTreeState()
        state.replaceChildren([
            try entry(name: "Sources", path: "Sources", kind: "directory"),
        ], of: "")
        state.replaceChildren([
            try entry(name: "Core", path: "Sources/Core", kind: "directory"),
        ], of: "Sources")
        state.replaceChildren([
            try entry(name: "Model.swift", path: "Sources/Core/Model.swift", kind: "file"),
        ], of: "Sources/Core")
        state.expand("Sources")
        state.expand("Sources/Core")

        state.discardSubtree(at: "Sources")

        #expect(state.expandedPaths.isEmpty)
        #expect(!state.hasLoadedChildren(of: "Sources"))
        #expect(!state.hasLoadedChildren(of: "Sources/Core"))
    }

    private func entry(
        name: String,
        path: String,
        kind: String,
        hidden: Bool = false,
        ignored: Bool = false,
        generated: Bool = false
    ) throws -> FileEntry {
        let data = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "path": path,
            "kind": kind,
            "hidden": hidden,
            "ignored": ignored,
            "generated": generated,
        ])
        return try JSONDecoder().decode(FileEntry.self, from: data)
    }
}
