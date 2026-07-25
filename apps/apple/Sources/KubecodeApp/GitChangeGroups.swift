import Foundation
import KubecodeKit

struct GitChangeGroups: Equatable {
    let staged: [GitFileChange]
    let worktree: [GitFileChange]

    var canCommit: Bool { !staged.isEmpty }

    init(files: [GitFileChange]) {
        staged = files
            .filter { $0.indexStatus != nil && $0.indexStatus != "?" }
            .sorted(by: Self.pathPrecedes)
        worktree = files
            .filter { $0.worktreeStatus != nil }
            .sorted(by: Self.pathPrecedes)
    }

    private static func pathPrecedes(_ left: GitFileChange, _ right: GitFileChange) -> Bool {
        left.path.localizedStandardCompare(right.path) == .orderedAscending
    }
}
