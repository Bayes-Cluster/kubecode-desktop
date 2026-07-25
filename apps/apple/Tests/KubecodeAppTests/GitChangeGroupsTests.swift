import Foundation
import Testing
import KubecodeKit
@testable import KubecodeApp

@Suite
struct GitChangeGroupsTests {
    @Test func files_with_index_and_worktree_changes_appear_in_both_native_sections() throws {
        let status = try JSONDecoder().decode(GitStatus.self, from: Data("""
        {
          "is_repository": true,
          "branch": "main",
          "files": [
            {"path":"Both.swift","index_status":"M","worktree_status":"M"},
            {"path":"Staged.swift","index_status":"A","worktree_status":null},
            {"path":"New.swift","index_status":"?","worktree_status":"?"}
          ]
        }
        """.utf8))

        let groups = GitChangeGroups(files: status.files)

        #expect(groups.staged.map(\.path) == ["Both.swift", "Staged.swift"])
        #expect(groups.worktree.map(\.path) == ["Both.swift", "New.swift"])
        #expect(groups.canCommit)
    }

    @Test func an_untracked_file_is_not_treated_as_staged() throws {
        let file = try JSONDecoder().decode(GitFileChange.self, from: Data("""
        {"path":"New.swift","index_status":"?","worktree_status":"?"}
        """.utf8))

        let groups = GitChangeGroups(files: [file])

        #expect(groups.staged.isEmpty)
        #expect(groups.worktree == [file])
        #expect(!groups.canCommit)
    }
}
