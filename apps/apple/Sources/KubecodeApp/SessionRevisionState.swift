import Foundation
import KubecodeKit

enum RevisionWorkspaceWarning: Equatable, Sendable {
    case workspaceChanged
    case checkpointUnavailable
    case filesKept
}

struct SessionRevisionState: Equatable, Sendable {
    private(set) var revisions: [ConversationRevision]
    private(set) var viewedSnapshotConversationID: String?
    private(set) var workspaceWarning: RevisionWorkspaceWarning?

    init(
        revisions: [ConversationRevision] = [],
        viewedSnapshotConversationID: String? = nil,
        workspaceWarning: RevisionWorkspaceWarning? = nil
    ) {
        self.revisions = revisions
        self.viewedSnapshotConversationID = viewedSnapshotConversationID
        self.workspaceWarning = workspaceWarning
    }

    var isViewingRevision: Bool { viewedSnapshotConversationID != nil }
    var totalPositions: Int { revisions.count + 1 }

    var activeIndex: Int {
        guard let viewedSnapshotConversationID,
              let index = revisions.firstIndex(where: {
                  $0.snapshotConversationID == viewedSnapshotConversationID
              })
        else { return revisions.count }
        return index
    }

    @discardableResult
    mutating func select(index: Int) -> String? {
        guard (0..<totalPositions).contains(index) else {
            return viewedSnapshotConversationID
        }
        viewedSnapshotConversationID = index == revisions.count
            ? nil
            : revisions[index].snapshotConversationID
        return viewedSnapshotConversationID
    }

    mutating func replaceRevisions(_ revisions: [ConversationRevision]) {
        self.revisions = revisions
        if let viewedSnapshotConversationID,
           !revisions.contains(where: {
               $0.snapshotConversationID == viewedSnapshotConversationID
           }) {
            self.viewedSnapshotConversationID = nil
        }
    }

    mutating func recordCreated(_ revision: ConversationRevision) {
        if let index = revisions.firstIndex(where: { $0.id == revision.id }) {
            revisions[index] = revision
        } else {
            revisions.append(revision)
        }
        viewedSnapshotConversationID = nil
        workspaceWarning = switch (revision.workspaceRestore, revision.workspaceRestoreReason) {
        case ("kept", "workspace_changed"): .workspaceChanged
        case ("kept", "checkpoint_unavailable"): .checkpointUnavailable
        case ("kept", _): .filesKept
        default: nil
        }
    }

    mutating func clearWarning() {
        workspaceWarning = nil
    }

    mutating func reset() {
        revisions = []
        viewedSnapshotConversationID = nil
        workspaceWarning = nil
    }
}

enum SessionRevisionPolicy {
    static func canRevise(
        isReadOnly: Bool,
        isViewingRevision: Bool,
        hasActiveRun: Bool
    ) -> Bool {
        !isReadOnly && !isViewingRevision && !hasActiveRun
    }

    static func canUndo(
        runStatus: String,
        isLatest: Bool,
        canRevise: Bool
    ) -> Bool {
        canRevise
            && isLatest
            && ["cancelled", "failed", "interrupted"].contains(runStatus)
    }
}
