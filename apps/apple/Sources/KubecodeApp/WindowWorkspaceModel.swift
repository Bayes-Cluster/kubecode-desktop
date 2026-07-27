import CoreGraphics
import Observation
import KubecodeMacRuntime
import KubecodeUI

@MainActor
@Observable
final class SessionWorkspaceModel {
    private static let maximumTranscriptExpansions = 512
    private static let maximumTranscriptLayoutOwners = 512

    var composerHeight: CGFloat = ComposerHeightCalculator.minimumHeight
    var composerIsExpanded = false
    var openComposerProviderControlID: String?
    var usageIsPresented = false
    var composerPalettePresented = false
    var composerReferencePickerPresented = false
    let transcriptScrollController = TranscriptScrollController()
    let autosaveScheduler = DocumentAutosaveScheduler()
    private var transcriptExpansionOverrides: [String: Bool] = [:]
    private var transcriptExpansionOrder: [String] = []
    private var transcriptShowsAllSteps: Set<String> = []
    private var transcriptLayoutRevisions: [String: Int] = [:]
    private var transcriptLayoutRevisionOrder: [String] = []

    func isTranscriptExpanded(sessionID: String?, itemID: String) -> Bool {
        resolvedTranscriptExpansion(
            sessionID: sessionID,
            itemID: itemID,
            defaultExpanded: false
        )
    }

    func resolvedTranscriptExpansion(
        sessionID: String?,
        itemID: String,
        defaultExpanded: Bool
    ) -> Bool {
        transcriptExpansionOverrides[
            transcriptExpansionKey(sessionID: sessionID, itemID: itemID)
        ] ?? defaultExpanded
    }

    func setTranscriptExpanded(
        _ expanded: Bool,
        sessionID: String?,
        itemID: String,
        ownerID: String? = nil
    ) {
        let key = transcriptExpansionKey(sessionID: sessionID, itemID: itemID)
        guard transcriptExpansionOverrides[key] != expanded else { return }
        transcriptExpansionOrder.removeAll { $0 == key }
        transcriptExpansionOverrides[key] = expanded
        transcriptExpansionOrder.append(key)
        while transcriptExpansionOrder.count > Self.maximumTranscriptExpansions {
            transcriptExpansionOverrides.removeValue(forKey: transcriptExpansionOrder.removeFirst())
        }
        bumpTranscriptLayoutRevision(sessionID: sessionID, ownerID: ownerID ?? itemID)
    }

    func showsAllTranscriptSteps(sessionID: String?, ownerID: String) -> Bool {
        transcriptShowsAllSteps.contains(transcriptLayoutKey(sessionID: sessionID, ownerID: ownerID))
    }

    func setShowsAllTranscriptSteps(_ showsAll: Bool, sessionID: String?, ownerID: String) {
        let key = transcriptLayoutKey(sessionID: sessionID, ownerID: ownerID)
        guard transcriptShowsAllSteps.contains(key) != showsAll else { return }
        if showsAll {
            transcriptShowsAllSteps.insert(key)
        } else {
            transcriptShowsAllSteps.remove(key)
        }
        bumpTranscriptLayoutRevision(sessionID: sessionID, ownerID: ownerID)
    }

    func transcriptLayoutRevision(sessionID: String?, ownerID: String) -> Int {
        transcriptLayoutRevisions[transcriptLayoutKey(sessionID: sessionID, ownerID: ownerID)] ?? 0
    }

    func disconnect() {
        autosaveScheduler.cancelAll()
    }

    private func transcriptExpansionKey(sessionID: String?, itemID: String) -> String {
        "\(sessionID ?? "unselected"):\(itemID)"
    }

    private func transcriptLayoutKey(sessionID: String?, ownerID: String) -> String {
        "\(sessionID ?? "unselected"):\(ownerID)"
    }

    private func bumpTranscriptLayoutRevision(sessionID: String?, ownerID: String) {
        let key = transcriptLayoutKey(sessionID: sessionID, ownerID: ownerID)
        transcriptLayoutRevisions[key, default: 0] &+= 1
        transcriptLayoutRevisionOrder.removeAll { $0 == key }
        transcriptLayoutRevisionOrder.append(key)
        while transcriptLayoutRevisionOrder.count > Self.maximumTranscriptLayoutOwners {
            let removed = transcriptLayoutRevisionOrder.removeFirst()
            transcriptLayoutRevisions.removeValue(forKey: removed)
            transcriptShowsAllSteps.remove(removed)
        }
    }
}

@MainActor
final class NavigationWorkspaceModel {
    let workspace: AppModel
    init(workspace: AppModel) { self.workspace = workspace }
}

@MainActor
final class ProjectWorkspaceModel {
    let workspace: AppModel
    init(workspace: AppModel) { self.workspace = workspace }
}

@MainActor
final class TeamWorkspaceModel {
    let workspace: AppModel
    init(workspace: AppModel) { self.workspace = workspace }
}

@MainActor
final class TerminalWorkspaceModel {
    let workspace: AppModel
    init(workspace: AppModel) { self.workspace = workspace }
}

@MainActor
final class WindowPresentationModel {
    let workspace: AppModel
    init(workspace: AppModel) { self.workspace = workspace }
}

@MainActor
@Observable
final class WindowWorkspaceModel {
    let workspace: AppModel
    let navigation: NavigationWorkspaceModel
    let session: SessionWorkspaceModel
    let project: ProjectWorkspaceModel
    let team: TeamWorkspaceModel
    let terminal: TerminalWorkspaceModel
    let presentation: WindowPresentationModel

    init(
        connections: MacConnectionManager,
        notificationCoordinator: WorkspaceNotificationCoordinator = .shared
    ) {
        let workspace = AppModel(
            connections: connections,
            notificationCoordinator: notificationCoordinator
        )
        self.workspace = workspace
        navigation = NavigationWorkspaceModel(workspace: workspace)
        session = SessionWorkspaceModel()
        project = ProjectWorkspaceModel(workspace: workspace)
        team = TeamWorkspaceModel(workspace: workspace)
        terminal = TerminalWorkspaceModel(workspace: workspace)
        presentation = WindowPresentationModel(workspace: workspace)
    }

    func disconnect() {
        session.disconnect()
        workspace.disconnectWindow()
    }
}
