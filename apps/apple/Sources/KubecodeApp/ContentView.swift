import AppKit
import SwiftUI
import KubecodeKit
import KubecodeMacUI
import KubecodeUI

enum WorkbenchPresentationMetrics {
    static let editorTabHeight: CGFloat = 30
    static let editorTabMaximumWidth: CGFloat = 180
    static let inspectorMinimumWidth: CGFloat = 220
    static let inspectorIdealWidth: CGFloat = 260
    static let inspectorMaximumWidth: CGFloat = 360
    static let terminalMinimumHeight: CGFloat = 140
    static let terminalIdealHeight: CGFloat = 220
    static let terminalMaximumHeight: CGFloat = 360
}

enum WorkspaceToolbarSymbolMetrics {
    static let layoutSize: CGFloat = 22
    static let buttonSize: CGFloat = 30
}

enum UserMessageBubbleMetrics {
    static let minimumWidth: CGFloat = 72
    static let maximumWidth: CGFloat = 620
    static let horizontalPadding: CGFloat = 32

    static func width(for source: String, typography: WorkspaceTypography) -> CGFloat {
        let font = typography.nsFont(for: .body)
        let longestLine = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                (String(line) as NSString).size(withAttributes: [.font: font]).width
            }
            .max() ?? 0
        return min(
            maximumWidth,
            max(minimumWidth, ceil(longestLine + horizontalPadding))
        )
    }
}

enum TranscriptSurfaceHeightAuthority {
    enum Presentation {
        case transcriptItem
        case activityStep
    }

    static func resolve(
        role: TranscriptRole,
        presentation: Presentation,
        isExpanded: Bool
    ) -> NativeTranscriptHeightAuthority {
        switch (presentation, role) {
        case (.transcriptItem, .user), (_, .agent):
            .versionedRender
        case (_, .thinking) where isExpanded:
            .versionedRender
        default:
            .synchronousHosting
        }
    }
}

private enum TranscriptSurfaceEntry: Identifiable, Hashable {
    case revisionWarning(String)
    case loadEarlier(isLoading: Bool)
    case item(TranscriptItem)
    case activityHeader(TranscriptRunActivity)
    case runOutput(TranscriptRunOutput)
    case activityStep(item: TranscriptItem, ownerID: String, isCurrent: Bool)
    case activityLimit(ownerID: String, hiddenCount: Int, showsAll: Bool)
    case sideQuestion(SideQuestion)

    var id: String {
        switch self {
        case .revisionWarning: "revision-warning"
        case .loadEarlier: "load-earlier"
        case let .item(item): item.id
        case let .activityHeader(activity): activity.id
        case let .runOutput(output): output.id
        case let .activityStep(item, ownerID, _): "\(ownerID)-step-\(item.id)"
        case let .activityLimit(ownerID, _, _): "\(ownerID)-limit"
        case let .sideQuestion(question): "side-question-\(question.id)"
        }
    }

    var resizePolicy: NativeTranscriptResizePolicy {
        guard case let .activityHeader(activity) = self,
              !activity.isActive
        else { return .immediate }
        return .animated
    }

    var contentRevision: Int {
        switch self {
        case let .runOutput(output):
            return TranscriptRunOutputContentIdentity(output: output).contentRevision
        default:
            var hasher = Hasher()
            hash(into: &hasher)
            return hasher.finalize()
        }
    }
}

private struct ComposerOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private struct TranscriptViewport: View {
    let entries: [TranscriptSurfaceEntry]
    let sessionID: String?
    let outputRevision: String
    let bottomInset: CGFloat
    let scrollController: TranscriptScrollController
    let heightAuthority: (TranscriptSurfaceEntry) -> NativeTranscriptHeightAuthority
    let layoutRevision: (String) -> Int
    let rowBuilder: (TranscriptSurfaceEntry) -> AnyView

    var body: some View {
        NativeTranscriptCollectionView(
            items: entries.map { entry in
                return NativeTranscriptItem(
                    id: entry.id,
                    contentRevision: entry.contentRevision,
                    layoutRevision: layoutRevision(entry.id),
                    resizePolicy: entry.resizePolicy,
                    heightAuthority: heightAuthority(entry)
                )
            },
            sessionID: sessionID,
            outputRevision: outputRevision,
            bottomInset: bottomInset,
            scrollController: scrollController
        ) { index in
            guard entries.indices.contains(index) else { return AnyView(EmptyView()) }
            return rowBuilder(entries[index])
        }
    }
}

private struct TurnEditRequest: Identifiable {
    var id: String { runID }
    let runID: String
    let originalMessage: String
}

private struct TurnBranchRequest: Identifiable {
    var id: String { runID }
    let runID: String
}

private enum TeamConfirmation: Identifiable {
    case pause
    case cancelTask(TeamTask)
    case removeMember(TeamMember)

    var id: String {
        switch self {
        case .pause: "pause"
        case let .cancelTask(task): "cancel-task-\(task.id)"
        case let .removeMember(member): "remove-member-\(member.id)"
        }
    }
}

private struct TurnEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: TurnEditRequest
    let onRevise: (String) -> Void
    @State private var message: String

    init(request: TurnEditRequest, onRevise: @escaping (String) -> Void) {
        self.request = request
        self.onRevise = onRevise
        _message = State(initialValue: request.originalMessage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Message").font(.headline)
            Text("Editing creates a new revision and preserves the previous timeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 150)
                .accessibilityLabel("Message")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Revise") {
                    onRevise(message)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 270)
    }
}

private struct TurnBranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: TurnBranchRequest
    let onBranch: (Bool) -> Void
    @State private var restoreFiles = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Branch from Here").font(.headline)
            Text("Create a visible Session from the conversation before this turn.")
                .foregroundStyle(.secondary)
            Toggle("Restore Project files from before this turn", isOn: $restoreFiles)
            if restoreFiles {
                Label(
                    "Kubecode will refuse the branch if restoring files could overwrite later workspace changes.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Branch") {
                    onBranch(restoreFiles)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 220)
    }
}

struct SessionRevisionNavigator: View {
    let activeIndex: Int
    let total: Int
    let isLoading: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onSelect(activeIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(activeIndex <= 0 || isLoading)
            .help("Previous Revision")
            .workspaceAccessibility(.previousRevision)

            Text(positionLabel)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 94)

            Button {
                onSelect(activeIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(activeIndex >= total - 1 || isLoading)
            .help("Next Revision")
            .workspaceAccessibility(.nextRevision)

            if isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session Revisions")
    }

    var positionLabel: String {
        String(
            format: String(localized: "Revision %lld of %lld"),
            Int64(activeIndex + 1),
            Int64(total)
        )
    }
}

private struct DocumentLifecycleAlerts: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .alert("Unsaved Changes", isPresented: closeAlertPresented) {
                Button("Save") { model.savePendingDocumentClose() }
                Button("Don't Save", role: .destructive) { model.discardPendingDocumentClose() }
                Button("Cancel", role: .cancel) { model.cancelPendingDocumentClose() }
            } message: {
                Text("Your edits to this file have not been saved. Closing it will discard them.")
            }
            .alert("File Changed on Server", isPresented: conflictAlertPresented) {
                Button("Reload", role: .destructive) { model.reloadConflictedDocument() }
                Button("Keep Editing", role: .cancel) { model.keepEditingConflictedDocument() }
            } message: {
                Text("The file changed on the server. Reloading will discard your local edits.")
            }
    }

    private var closeAlertPresented: Binding<Bool> {
        Binding(get: { model.pendingDocumentClosePath != nil }, set: { _ in })
    }

    private var conflictAlertPresented: Binding<Bool> {
        Binding(get: { model.documentRevisionConflict != nil }, set: { _ in })
    }
}

private struct GitDiscardConfirmation: ViewModifier {
    @Bindable var model: AppModel
    @Binding var change: GitFileChange?

    func body(content: Content) -> some View {
        content.alert("Discard Changes?", isPresented: isPresented) {
            Button("Cancel", role: .cancel) { change = nil }
            Button("Discard Changes", role: .destructive) {
                if let change { model.mutateGit(change, action: .discard) }
                change = nil
            }
        } message: {
            Text("All uncommitted changes to the selected file will be permanently discarded. This action cannot be undone.")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { change != nil }, set: { if !$0 { change = nil } })
    }
}

struct TerminalPaneHeaderActions {
    let onSelect: () -> Void
    let onClose: () -> Void

    func select() { onSelect() }
    func close() { onClose() }
}

struct TerminalPaneHeader: View {
    let terminalID: String
    let title: String
    let status: String
    let isSelected: Bool
    let actions: TerminalPaneHeaderActions

    init(
        terminalID: String,
        title: String,
        status: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.terminalID = terminalID
        self.title = title
        self.status = status
        self.isSelected = isSelected
        actions = TerminalPaneHeaderActions(onSelect: onSelect, onClose: onClose)
    }

    static func selectionIdentifier(terminalID: String) -> String { "terminal.select.\(terminalID)" }
    static func closeIdentifier(terminalID: String) -> String { "terminal.close.\(terminalID)" }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: actions.select) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    Text(verbatim: title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    statusDot
                }
                .contentShape(Rectangle())
                .padding(.trailing, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityIdentifier(Self.selectionIdentifier(terminalID: terminalID))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(action: actions.close) {
                Label("Close Terminal", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            .help("Close Terminal")
            .accessibilityIdentifier(Self.closeIdentifier(terminalID: terminalID))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
    }

    private var statusDot: some View {
        Circle()
            .fill(status == "running" ? Color.green : .secondary)
            .frame(width: 7, height: 7)
            .help(status == "running" ? String(localized: "Running") : String(localized: "Exited"))
    }
}

private struct TerminalWorkbenchPane: View {
    @Bindable var model: AppModel
    let terminal: TerminalInfo
    @State private var connectionPhase: TerminalConnectionPhase = .connecting
    @State private var connectionGeneration = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                TerminalPaneHeader(
                    terminalID: terminal.id,
                    title: terminal.title,
                    status: terminal.status,
                    isSelected: model.activeTerminalID == terminal.id,
                    onSelect: { model.selectTerminal(terminal) },
                    onClose: { model.closeTerminal(terminal) }
                )
                Divider()
                ZStack {
                    TerminalEmulatorView(
                        makeConnection: { cursor in
                            try model.makeTerminalConnection(terminal, cursor: cursor)
                        },
                        onStatus: { status, exitCode, signal in
                            model.updateTerminalStatus(
                                id: terminal.id,
                                status: status,
                                exitCode: exitCode,
                                signal: signal
                            )
                        },
                        onPhaseChange: { connectionPhase = $0 },
                        onFocus: { model.selectTerminal(terminal) },
                        onError: { model.errorMessage = $0 }
                    )
                    .id("\(terminal.id)-\(connectionGeneration)")

                    if terminal.status == "exited" || connectionPhase == .exited {
                        VStack(spacing: 10) {
                            Image(systemName: "terminal.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Terminal Exited")
                                .font(.headline)
                            Text(exitDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Restart Terminal", systemImage: "arrow.clockwise") {
                                model.restartTerminal(terminal)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.restartingTerminalIDs.contains(terminal.id))
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    } else if connectionPhase == .connecting || connectionPhase == .reconnecting {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(connectionPhase == .reconnecting ? "Reconnecting…" : "Connecting…")
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                    } else if case let .failed(message) = connectionPhase {
                        VStack(spacing: 10) {
                            Image(systemName: "network.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Terminal Connection Failed")
                                .font(.headline)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.center)
                            Button("Retry Connection", systemImage: "arrow.clockwise") {
                                connectionPhase = .connecting
                                connectionGeneration += 1
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(20)
                        .frame(maxWidth: 420)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var exitDescription: String {
        if let signal = terminal.signal {
            return String(
                format: String(localized: "Terminal exited after signal %@."),
                signal
            )
        }
        if let exitCode = terminal.exitCode {
            return String(
                format: String(localized: "Terminal exited with code %lld."),
                Int64(exitCode)
            )
        }
        return String(localized: "The terminal process has exited.")
    }
}

private struct TerminalLayoutNodeView: View {
    @Bindable var model: AppModel
    let layout: TerminalLayoutState

    var body: some View { content }

    private var content: AnyView {
        switch layout {
        case let .leaf(terminalID):
            guard let terminal = model.terminals.first(where: { $0.id == terminalID }) else {
                return AnyView(EmptyView())
            }
            return AnyView(
                TerminalWorkbenchPane(model: model, terminal: terminal)
                    .frame(minWidth: 160, minHeight: 100)
            )
        case let .split(split):
            return AnyView(
                NativeTerminalSplitView(
                    axis: split.axis,
                    ratio: split.ratio,
                    first: AnyView(TerminalLayoutNodeView(model: model, layout: split.first)),
                    second: AnyView(TerminalLayoutNodeView(model: model, layout: split.second)),
                    onRatioChange: { ratio in
                        model.updateTerminalSplitRatio(splitID: split.id, ratio: ratio)
                    }
                )
            )
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Bindable var sessionWorkspace: SessionWorkspaceModel
    @Environment(\.workspaceTypography) private var typography
    @State private var renamingConversation: Conversation?
    @State private var renameDraft = ""
    @State private var deletingConversation: Conversation?
    @State private var entryPromptKind: String?
    @State private var entryDraft = ""
    @State private var renamingEntry: FileEntry?
    @State private var deletingEntry: FileEntry?
    @State private var discardingChange: GitFileChange?
    @State private var renamingTerminal: TerminalInfo?
    @State private var terminalTitleDraft = ""
    @State private var workspaceMigrationProject: Project?
    @State private var unregisteringProject: Project?
    @State private var promotingConversation: Conversation?
    @State private var configuringTeam: TeamSnapshot?
    @State private var completingTeam = false
    @State private var teamSummaryDraft = ""
    @State private var selectedTeamTask: TeamTask?
    @State private var teamSettingsSnapshot: TeamSnapshot?
    @State private var teamConfirmation: TeamConfirmation?
    @State private var editingTurn: TurnEditRequest?
    @State private var branchingTurn: TurnBranchRequest?
    @State private var teamInputAnswers: [String: String] = [:]
    @State private var composerOverlayHeight: CGFloat = 0
    @SceneStorage("navigation.showArchivedSessions") private var showArchivedSessions = false
    @SceneStorage("navigation.sessionAgentFilter") private var sessionAgentFilter = "all"
    @SceneStorage("navigation.sessionSort") private var sessionSort = SessionNavigationSort.activity.rawValue
    @AppStorage("editor.autosave") private var autosave = false
    @AppStorage("editor.showHidden") private var showHidden = false
    @AppStorage("editor.showIgnored") private var showIgnored = false
    @AppStorage("editor.showGenerated") private var showGenerated = false

    init(model: AppModel, sessionWorkspace: SessionWorkspaceModel = SessionWorkspaceModel()) {
        self.model = model
        self.sessionWorkspace = sessionWorkspace
    }

    var body: some View {
        onboardingLayout
        .environment(\.markdownProjectResourceContext, model.markdownProjectResourceContext)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                errorBanner(error)
            }
        }
        .alert("Rename Session", isPresented: renameAlertPresented) {
            TextField("Session name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingConversation = nil }
            Button("Save") {
                if let conversation = renamingConversation {
                    model.renameConversation(conversation, title: renameDraft)
                }
                renamingConversation = nil
            }
        } message: {
            Text("Set a custom title, or leave it empty to use the Agent title.")
        }
        .alert(deleteConfirmationTitle, isPresented: deleteAlertPresented) {
            Button("Cancel", role: .cancel) { deletingConversation = nil }
            Button("Delete", role: .destructive) {
                if let conversation = deletingConversation { model.deleteConversation(conversation) }
                deletingConversation = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert("Remove Project?", isPresented: unregisterProjectAlertPresented) {
            Button("Cancel", role: .cancel) { unregisteringProject = nil }
            Button("Remove", role: .destructive) {
                if let project = unregisteringProject { model.unregisterProject(project) }
                unregisteringProject = nil
            }
        } message: {
            Text("This unregisters the Project from Kubecode. Its directory is never deleted.")
        }
        .alert(entryPromptKind == "directory" ? "New Folder" : renamingEntry == nil ? "New File" : "Rename Entry", isPresented: entryAlertPresented) {
            TextField("Relative path", text: $entryDraft)
            Button("Cancel", role: .cancel) { entryPromptKind = nil; renamingEntry = nil }
            Button("Save") {
                if let entry = renamingEntry { model.renameEntry(entry, to: entryDraft) }
                else if let kind = entryPromptKind { model.createEntry(path: entryDraft, kind: kind) }
                entryPromptKind = nil
                renamingEntry = nil
            }
            .disabled(entryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete Entry?", isPresented: deleteEntryAlertPresented) {
            Button("Cancel", role: .cancel) { deletingEntry = nil }
            Button("Delete", role: .destructive) {
                if let entry = deletingEntry { model.deleteEntry(entry) }
                deletingEntry = nil
            }
        } message: {
            Text("This deletes the selected file or folder from the Project.")
        }
        .modifier(GitDiscardConfirmation(model: model, change: $discardingChange))
        .alert("Rename Terminal", isPresented: renameTerminalAlertPresented) {
            TextField("Terminal name", text: $terminalTitleDraft)
            Button("Cancel", role: .cancel) { renamingTerminal = nil }
            Button("Rename") {
                if let terminal = renamingTerminal { model.renameTerminal(terminal, title: terminalTitleDraft) }
                renamingTerminal = nil
            }
        }
        .modifier(DocumentLifecycleAlerts(model: model))
        .alert("Complete Team", isPresented: $completingTeam) {
            TextField("Final summary", text: $teamSummaryDraft, axis: .vertical)
            Button("Cancel", role: .cancel) {}
            Button("Complete") { model.completeSelectedTeam(summary: teamSummaryDraft) }
        }
        .alert(item: $teamConfirmation) { confirmation in
            teamConfirmationAlert(confirmation)
        }
        .sheet(isPresented: $model.isTeamSetupPresented) {
            TeamSetupSheet(model: model)
        }
        .sheet(item: $promotingConversation) { conversation in
            TeamSetupSheet(model: model, conversation: conversation)
        }
        .sheet(item: $configuringTeam) { draft in
            TeamSetupSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $model.isProjectBrowserPresented) {
            ProjectBrowserSheet(model: model)
        }
        .sheet(item: $model.sessionSetupRequest) { request in
            SessionSetupSheet(model: model, initialAgentID: request.agentID)
        }
        .sheet(isPresented: $model.isQuickOpenPresented) {
            QuickOpenSheet(model: model)
        }
        .sheet(isPresented: $sessionWorkspace.composerReferencePickerPresented) {
            QuickOpenSheet(model: model) { entry in
                model.insertComposerReference(entry)
                sessionWorkspace.composerReferencePickerPresented = false
            }
        }
        .sheet(item: $selectedTeamTask) { task in
            if let snapshot = model.selectedTeam {
                TeamTaskDetailSheet(
                    snapshot: snapshot,
                    task: task,
                    onAssign: { model.assignTeamTask(task, to: $0) },
                    onRetry: { model.retryTeamTask(task) },
                    onCancel: { presentTeamConfirmation(.cancelTask(task)) },
                    onRemoveMember: { member in presentTeamConfirmation(.removeMember(member)) },
                    onOpenMember: { model.openTeamMember($0) }
                )
            }
        }
        .sheet(item: $teamSettingsSnapshot) { snapshot in
            TeamSettingsSheet(snapshot: snapshot) { policy, maxParallelRuns in
                model.updateSelectedTeamSettings(
                    memberManagementPolicy: policy,
                    maxParallelRuns: maxParallelRuns
                )
            }
        }
        .sheet(item: $workspaceMigrationProject) { project in
            WorkspaceMigrationSheet(model: model, project: project)
        }
        .sheet(item: $editingTurn) { request in
            TurnEditSheet(request: request) { replacement in
                model.reviseTurn(runID: request.runID, replacement: replacement)
            }
        }
        .sheet(item: $branchingTurn) { request in
            TurnBranchSheet(request: request) { restoreFiles in
                model.branchTurn(request.runID, restoreFiles: restoreFiles)
            }
        }
        .onChange(of: model.documentDraft) {
            guard autosave,
                  model.canSaveActiveDocument,
                  let path = model.activeDocument?.path
            else { return }
            sessionWorkspace.autosaveScheduler.schedule(key: path) {
                model.autosaveDocument(path: path)
            }
        }
        .onChange(of: autosave) { _, enabled in
            if !enabled { sessionWorkspace.autosaveScheduler.cancelAll() }
        }
        .onChange(of: model.selectedProjectNeedsFolderAccess) { _, requiresAccess in
            if requiresAccess { sessionWorkspace.autosaveScheduler.cancelAll() }
        }
        .onChange(of: model.markdownResourceInvalidation) { _, invalidation in
            guard let invalidation,
                  invalidation.projectID == model.selectedProjectID,
                  let resourceContext = model.markdownProjectResourceContext
            else { return }
            sessionWorkspace.invalidateMarkdownResources(
                identity: resourceContext.identity,
                projectPath: invalidation.projectPath
            )
        }
        .onDisappear {
            sessionWorkspace.autosaveScheduler.cancelAll()
        }
    }

    private var onboardingLayout: some View {
        NavigationSplitView {
            Group {
                if model.projects.isEmpty {
                    projectSidebar
                } else {
                    workspaceSidebar
                }
            }
            .navigationSplitViewColumnWidth(
                min: WorkspaceNavigationSidebarMetrics.columnMinimumWidth,
                ideal: WorkspaceNavigationSidebarMetrics.columnIdealWidth,
                max: WorkspaceNavigationSidebarMetrics.columnMaximumWidth
            )
            .toolbar { navigatorToolbar }
        } detail: {
            Group {
                if model.projects.isEmpty {
                    projectOnboarding
                } else {
                    workbench
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(WorkspaceLayoutAnchor(identifier: "workspace.navigation-shell.layout"))
    }

    @ToolbarContentBuilder
    private var navigatorToolbar: some ToolbarContent {
        if model.projects.isEmpty {
            ToolbarItem {
                Button { model.presentProjectRegistration() } label: {
                    Image(systemName: "plus")
                }
                .help("Add Project")
                .disabled(!model.isReady)
            }
        } else {
            ToolbarItem {
                HStack(spacing: WorkspaceNavigationSidebarMetrics.toolbarSpacing) {
                    navigatorSessionFilterMenu
                        .buttonStyle(NavigatorToolbarControlStyle())
                    Button {
                        model.isQuickOpenPresented = true
                    } label: {
                        navigatorToolbarIcon("magnifyingglass")
                    }
                    .buttonStyle(NavigatorToolbarControlStyle())
                    .help(Text(WorkspaceAccessibilityAction.quickOpen.label))
                    .workspaceAccessibility(.quickOpen)
                    .disabled(!model.canUseSelectedProjectFiles)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var navigatorSessionFilterMenu: some View {
        Menu {
            Picker("Agent", selection: sessionAgentFilterBinding) {
                Text("All Agents").tag("all")
                ForEach(AgentID.allCases, id: \.rawValue) { agentID in
                    AgentIdentityLabel(agentID: agentID).tag(agentID.rawValue)
                }
            }
            Picker("Sort Sessions", selection: sessionSortBinding) {
                Text("By Activity").tag(SessionNavigationSort.activity.rawValue)
                Text("By Created").tag(SessionNavigationSort.created.rawValue)
                Text("By Title").tag(SessionNavigationSort.title.rawValue)
            }
            Divider()
            Toggle("Show Archived Sessions", isOn: $showArchivedSessions)
        } label: {
            navigatorToolbarIcon(
                isFilteringSessions
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .menuIndicator(.hidden)
        .help("Sort and Filter Sessions")
        .workspaceAccessibility(.filterSessions)
    }

    private func navigatorToolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .frame(
                width: WorkspaceNavigationSidebarMetrics.toolbarSymbolLayoutSize,
                height: WorkspaceNavigationSidebarMetrics.toolbarSymbolLayoutSize
            )
    }

    private var isFilteringSessions: Bool {
        showArchivedSessions
            || sessionAgentFilter != "all"
            || sessionSort != SessionNavigationSort.activity.rawValue
    }

    private var sessionAgentFilterBinding: Binding<String> {
        Binding(
            get: { sessionAgentFilter },
            set: { sessionAgentFilter = AgentID(rawValue: $0) == nil ? "all" : $0 }
        )
    }

    private var sessionSortBinding: Binding<String> {
        Binding(
            get: { sessionSort },
            set: {
                sessionSort = SessionNavigationSort(rawValue: $0)?.rawValue
                    ?? SessionNavigationSort.activity.rawValue
            }
        )
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            Group {
                if model.projects.isEmpty {
                    ContentUnavailableView {
                        Image(systemName: "folder")
                        Text("No Projects")
                    } actions: {
                        Button("Choose Folder…") { model.presentProjectRegistration() }
                            .disabled(!model.isReady)
                    }
                } else {
                    List(model.projects, selection: projectSelection) { project in
                        HStack(spacing: 8) {
                            Label(project.name, systemImage: "folder")
                            Spacer(minLength: 4)
                            let attentionCount = model.navigationAttentionCount(projectID: project.id)
                            if attentionCount > 0 {
                                Text(verbatim: "\(attentionCount)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .help("Needs Attention")
                            }
                            if model.projectNeedsFolderAccess(project) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Folder Access Required")
                            }
                        }
                            .tag(project.id)
                            .contextMenu {
                                if model.isLocalManagedConnection {
                                    Button("Restore Folder Access…", systemImage: "folder.badge.questionmark") {
                                        model.reauthorizeProject(project)
                                    }
                                    Divider()
                                }
                                Button(project.workspacesEnabled ? "Disable Workspaces..." : "Enable Workspaces") {
                                    if project.workspacesEnabled {
                                        workspaceMigrationProject = project
                                    } else {
                                        model.setWorkspacesEnabled(project, enabled: true)
                                    }
                                }
                                Divider()
                                Button("Remove Project", systemImage: "minus.circle", role: .destructive) {
                                    unregisteringProject = project
                                }
                            }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WorkspaceRuntimeFooter(model: model)
        }
        .navigationTitle("Projects")
    }

    private var projectOnboarding: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                VStack(spacing: 7) {
                    Text("Open a local project to start an Agent session.")
                        .foregroundStyle(.secondary)
                }
                Button("Open Project…", systemImage: "folder.badge.plus") {
                    model.presentProjectRegistration()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.isReady)
                if !model.isReady {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Starting local Runtime…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Projects remain in their original folders. Removing one from Kubecode never deletes it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
    }

    private var activitySidebar: some View {
        WorkspaceNavigationSidebar(
            model: model,
            onRename: { conversation in
                beginRenaming(conversation)
            },
            onDelete: { deletingConversation = $0 },
            onPromote: { promotingConversation = $0 },
            onDisableWorkspaces: { workspaceMigrationProject = $0 },
            onRemoveProject: { unregisteringProject = $0 },
            showArchivedSessions: $showArchivedSessions,
            sessionAgentFilter: $sessionAgentFilter,
            sessionSort: $sessionSort
        )
    }

    private var workspaceSidebar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                activitySidebar
                    .frame(minHeight: 260, maxHeight: .infinity)
                    .background(WorkspaceLayoutAnchor(identifier: "navigator.sessions-area.layout"))
                workspaceExplorer
                    .frame(
                        height: explorerHeight(availableHeight: geometry.size.height),
                        alignment: .bottom
                    )
                    .clipped()
                WorkspaceRuntimeFooter(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WorkspaceLayoutAnchor(identifier: "navigator.column.layout"))
    }

    private func beginRenaming(_ conversation: Conversation) {
        renameDraft = conversation.manualTitle ?? conversation.title
        renamingConversation = conversation
    }

    private var deleteConfirmationTitle: String {
        guard let conversation = deletingConversation else {
            return String(localized: "Delete Session?")
        }
        if conversation.teamRole == "leader" {
            let title = conversation.teamTitle ?? conversation.title
            return String.localizedStringWithFormat(
                String(localized: "Delete %@?"),
                title
            )
        }
        return String(localized: "Delete Session?")
    }

    private var deleteConfirmationMessage: String {
        guard let conversation = deletingConversation else { return "" }
        if conversation.teamRole == "leader" {
            let count = max(
                0,
                SessionLifecyclePolicy.removedConversationIDs(
                    deleting: conversation,
                    conversations: model.conversations
                ).count - 1
            )
            return String.localizedStringWithFormat(
                String(localized: "This removes the Leader and %lld teammate Session records from Kubecode. Project files and provider-native history are preserved."),
                count
            )
        }
        return String(localized: "This removes only Kubecode's record. Provider-native history is preserved.")
    }

    private var projectSelection: Binding<String?> {
        Binding(
            get: { model.selectedProjectID },
            set: { selection in
                guard let selection,
                      selection != model.selectedProjectID,
                      let project = model.projects.first(where: { $0.id == selection })
                else { return }
                model.selectProject(project)
            }
        )
    }

    private var workbench: some View {
        GeometryReader { geometry in
            Group {
                if model.isTerminalPanelPresented, !model.activeTerminalPanes.isEmpty {
                    VSplitView {
                        workbenchMain
                        terminalGroupWorkbench
                            .frame(
                                minHeight: WorkbenchPresentationMetrics.terminalMinimumHeight,
                                idealHeight: WorkbenchPresentationMetrics.terminalIdealHeight,
                                maxHeight: WorkbenchPresentationMetrics.terminalMaximumHeight
                            )
                    }
                } else {
                    VStack(spacing: 0) {
                        workbenchMain
                        Divider()
                        collapsedTerminalBar
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var workbenchMain: some View {
        workbenchMainContent
        .frame(minHeight: 300)
    }

    @ViewBuilder
    private var workbenchMainContent: some View {
        Group {
            if let diff = model.activeDiff {
                diffViewer(diff)
            } else if let document = model.activeDocument {
                documentEditor(document)
            } else if let team = model.selectedTeam {
                teamMonitor(team)
            } else if model.selectedConversation != nil {
                conversationView
            } else {
                newSessionView
            }
        }
        .frame(minWidth: 480)
    }

    private var collapsedTerminalBar: some View {
        Button {
            model.toggleTerminalPanel()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.bottomhalf.inset.filled")
                Text("Terminal")
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
        .workspaceAccessibility(.showTerminal)
        .help("Show Terminal Panel")
        .disabled(!model.canToggleTerminalPanel)
    }

    private func teamMonitor(_ snapshot: TeamSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.team.title).font(.headline)
                    Text(snapshot.team.goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Label(
                    snapshot.team.status.replacingOccurrences(of: "_", with: " ").capitalized,
                    systemImage: "circle.fill"
                )
                .font(.caption)
                .foregroundStyle(statusColor(snapshot.team.status))
                if TeamActionPolicy.canReconfigure(status: snapshot.team.status) {
                    Button {
                        configuringTeam = snapshot
                    } label: {
                        Label("Reconfigure Team", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Reconfigure Team")
                    .workspaceAccessibility(.teamReconfigure)
                }
                if TeamActionPolicy.canResume(status: snapshot.team.status) {
                    Button("Resume", systemImage: "play.fill") {
                        model.updateTeamLifecycle()
                    }
                } else if TeamActionPolicy.canPause(status: snapshot.team.status) {
                    Button("Pause", systemImage: "pause.fill") {
                        teamConfirmation = .pause
                    }
                }
                if ["active", "verifying", "needs_attention", "paused"].contains(snapshot.team.status) {
                    Button("Complete") {
                        teamSummaryDraft = ""
                        completingTeam = true
                    }
                    .disabled(!TeamActionPolicy.canComplete(
                        status: snapshot.team.status,
                        counters: snapshot.summary
                    ))
                }
                if snapshot.team.status == "draft" {
                    Button("Configure Team", systemImage: "slider.horizontal.3") {
                        configuringTeam = snapshot
                    }
                    .buttonStyle(.borderedProminent)
                }
                Menu {
                    Button("Team Settings…", systemImage: "gearshape") {
                        teamSettingsSnapshot = snapshot
                    }
                    if let leader = teamLeaderConversation(snapshot) {
                        Divider()
                        Button("Delete Team…", systemImage: "trash", role: .destructive) {
                            deletingConversation = leader
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Team Actions")
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Divider()

            HStack(spacing: 0) {
                teamMetric("Running", value: snapshot.summary.running)
                Divider().frame(height: 30)
                teamMetric("Queued", value: snapshot.summary.queued)
                Divider().frame(height: 30)
                teamMetric("Attention", value: snapshot.summary.needsAttention)
                Divider().frame(height: 30)
                teamMetric("Done", value: snapshot.summary.done)
            }
            .frame(height: 58)
            .background(.quaternary.opacity(0.35))
            Divider()

            if let fallback = snapshot.team.modeFallback {
                VStack(alignment: .leading, spacing: 6) {
                    Label("YOLO fallback", systemImage: "exclamationmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(fallback.reason)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                Divider()
            }

            if !snapshot.attention.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(snapshot.attention) { item in
                        if let member = TeamActionPolicy.attentionOwner(
                            item,
                            members: snapshot.members
                        ) {
                            Button {
                                model.openTeamMember(member)
                            } label: {
                                HStack {
                                    Text(item.summary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.summary)
                            .help("Open Member Session")
                        } else {
                            Text(item.summary).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                Divider()
            }

            List {
                if let rounds = snapshot.discriminationRounds, !rounds.isEmpty {
                    Section("Verification") {
                        ForEach(rounds) { round in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Verification Round \(round.round)")
                                        .font(.headline)
                                    Spacer()
                                    Text(verbatim: round.status
                                        .replacingOccurrences(of: "_", with: " ")
                                        .capitalized)
                                        .font(.caption)
                                        .foregroundStyle(statusColor(round.status))
                                }
                                if let verdict = round.verdict, !verdict.isEmpty {
                                    Text(verdict).textSelection(.enabled)
                                }
                                if let evidence = round.evidence, !evidence.isEmpty {
                                    LabeledContent("Evidence") {
                                        Text(evidence)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    .font(.caption)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if let proposal = snapshot.proposal, proposal.status == "pending" {
                    Section("Teammate Proposal") {
                        Text(proposal.summary).textSelection(.enabled)
                        if !proposal.proposedMemberNames.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(
                                    Array(proposal.proposedMemberNames.enumerated()),
                                    id: \.offset
                                ) { _, name in
                                    Label(name, systemImage: "person")
                                        .font(.callout)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        HStack {
                            Spacer()
                            Button("Reject", role: .destructive) {
                                model.resolveTeamProposal(proposal, decision: "rejected")
                            }
                            Button("Approve") {
                                model.resolveTeamProposal(proposal, decision: "approved")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                if let requests = snapshot.userInputRequests, !requests.isEmpty {
                    Section("User Input") {
                        ForEach(requests) { request in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(request.title).font(.headline)
                                Text(request.prompt).textSelection(.enabled)
                                HStack {
                                    TextField("Reply", text: teamInputBinding(request.id))
                                    Button("Send") {
                                        model.resolveTeamUserInput(
                                            request,
                                            answer: teamInputAnswers[request.id] ?? ""
                                        )
                                        teamInputAnswers[request.id] = ""
                                    }
                                    .disabled((teamInputAnswers[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                    }
                }
                Section("Members") {
                    ForEach(snapshot.members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Button(member.name) { model.openTeamMember(member) }
                                    .buttonStyle(.plain)
                                Text(member.role.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusDot(member.status)
                            if TeamActionPolicy.canRemove(member) {
                                Menu {
                                    Button("Remove Member…", systemImage: "person.badge.minus", role: .destructive) {
                                        teamConfirmation = .removeMember(member)
                                    }
                                } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton)
                            }
                        }
                    }
                }
                Section("Tasks") {
                    ForEach(snapshot.tasks) { task in
                        Button {
                            selectedTeamTask = task
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(task.title)
                                    Spacer()
                                    Text(task.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !task.description.isEmpty {
                                    Text(task.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if let dependencies = task.dependencies, !dependencies.isEmpty {
                                    Text("Depends on: \(dependencies.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                let attempts = (snapshot.taskAttempts ?? []).filter { $0.taskID == task.id }
                                if !attempts.isEmpty {
                                    Text("\(attempts.count) attempt(s), latest: \(attempts.last?.status ?? "unknown")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
                if let permissions = snapshot.permissions, !permissions.isEmpty {
                    Section("Permissions") {
                        ForEach(permissions) { permission in
                            if let member = TeamActionPolicy.permissionOwner(
                                permission,
                                members: snapshot.members
                            ) {
                                Button {
                                    model.openTeamMember(member)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(permission.tool).font(.headline)
                                            Text(permission.reason ?? permission.status)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Label("Resolve in \(member.name)", systemImage: "arrow.right.circle")
                                            .font(.caption)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(permission.tool).font(.headline)
                                    Text(permission.reason ?? permission.status)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                if let operations = snapshot.lifecycleOperations,
                   operations.contains(where: { $0.status == "failed" || $0.lastError != nil }) {
                    Section("Lifecycle") {
                        ForEach(operations.filter { $0.status == "failed" || $0.lastError != nil }) { operation in
                            Text(verbatim: "\(operation.kind): \(operation.lastError ?? operation.status)")
                                .textSelection(.enabled)
                        }
                    }
                }
                if let activity = snapshot.activity, !activity.isEmpty {
                    Section("Activity") {
                        ForEach(activity.prefix(50)) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.summary).textSelection(.enabled)
                                Text(item.createdAt).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func teamMetric(_ label: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(value)").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func teamInputBinding(_ id: String) -> Binding<String> {
        Binding(get: { teamInputAnswers[id] ?? "" }, set: { teamInputAnswers[id] = $0 })
    }

    private func teamLeaderConversation(_ snapshot: TeamSnapshot) -> Conversation? {
        snapshot.leaderConversation
            ?? snapshot.conversations?.first { $0.teamRole == "leader" }
            ?? model.conversations.first { $0.teamID == snapshot.id && $0.teamRole == "leader" }
    }

    private func presentTeamConfirmation(_ confirmation: TeamConfirmation) {
        selectedTeamTask = nil
        Task { @MainActor in
            await Task.yield()
            teamConfirmation = confirmation
        }
    }

    private func teamConfirmationAlert(_ confirmation: TeamConfirmation) -> Alert {
        switch confirmation {
        case .pause:
            Alert(
                title: Text("Pause Team?"),
                message: Text("Active Agent runs will be interrupted. You can resume the Team and retry interrupted tasks later."),
                primaryButton: .destructive(Text("Pause Team")) {
                    model.updateTeamLifecycle()
                },
                secondaryButton: .cancel()
            )
        case let .cancelTask(task):
            Alert(
                title: Text("Cancel Task?"),
                message: Text("The active attempt for “\(task.title)” will be stopped. Completed Project changes are not deleted."),
                primaryButton: .destructive(Text("Cancel Task")) {
                    model.cancelTeamTask(task)
                },
                secondaryButton: .cancel()
            )
        case let .removeMember(member):
            Alert(
                title: Text("Remove Member?"),
                message: Text("\(member.name)'s active work will stop and unfinished tasks may need reassignment. Provider-native history is preserved."),
                primaryButton: .destructive(Text("Remove Member")) {
                    model.removeTeamMember(member)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var newSessionView: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Start an Agent Session")
                    .font(.title2.weight(.semibold))
                Text("Choose an available Agent for \(model.selectedProject?.name ?? "this Project").")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(model.availableAgents) { agent in
                    Button {
                        model.presentSessionSetup(preferredAgent: agent.id)
                    } label: {
                        AgentIdentityLabel(agentID: agent.id, iconSize: 18)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            Button("Create Team", systemImage: "person.3") { model.isTeamSetupPresented = true }
                .buttonStyle(.bordered)
                .disabled(!model.canCreateTeam)
            if model.availableAgents.isEmpty {
                Text("No supported Agent is ready. Check the Runtime log for CLI and adapter diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
    }

    private var conversationView: some View {
        VStack(spacing: 0) {
            if let conversation = model.selectedConversation {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title).font(.headline)
                    }
                    Spacer()
                    if !model.revisions.isEmpty {
                        revisionNavigator
                    }
                    if model.selectedConversationIsReadOnly {
                        Label(
                            model.revisionState.isViewingRevision
                                ? String(localized: "Historical Revision")
                                : String(localized: "Read Only"),
                            systemImage: "lock"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(
                                model.revisionState.isViewingRevision
                                    ? String(localized: "Historical revisions are read-only.")
                                    : String(localized: "Team member transcripts are read-only.")
                            )
                    }
                    if model.isRunStreamReconnecting {
                        Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let usage = model.agentUsage {
                        agentUsageControl(usage)
                    }
                    if let status = conversation.latestRunStatus { statusDot(status) }
                    sessionActionMenu(conversation)
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                Divider()
            }

            ZStack(alignment: .bottom) {
                TranscriptViewport(
                    entries: transcriptSurfaceEntries,
                    sessionID: model.selectedConversationID,
                    outputRevision: transcriptScrollMarker,
                    bottomInset: transcriptBottomClearance,
                    scrollController: sessionWorkspace.transcriptScrollController,
                    heightAuthority: transcriptSurfaceHeightAuthority,
                    layoutRevision: { ownerID in
                        sessionWorkspace.transcriptLayoutRevision(
                            sessionID: model.selectedConversationID,
                            ownerID: ownerID
                        )
                    }
                ) { entry in
                    AnyView(
                        transcriptSurfaceRow(entry)
                            .environment(
                                \.agentMarkdownRenderStore,
                                sessionWorkspace.markdownRenderStore
                            )
                    )
                }

                TranscriptJumpToLatestButton(
                    controller: sessionWorkspace.transcriptScrollController,
                    action: {
                        sessionWorkspace.transcriptScrollController.resumeFollowing()
                    }
                )
                    .padding(.bottom, transcriptJumpButtonBottomPadding)

                if !model.selectedConversationIsReadOnly {
                    VStack(spacing: 0) {
                        if let run = model.runs.last, model.canUndoTurn(run.id) {
                            Button("Undo Turn", systemImage: "arrow.uturn.backward") {
                                model.undoTurn(run.id)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isChangingRevision)
                            .frame(maxWidth: 1100, alignment: .leading)
                            .padding(.bottom, 6)
                        }
                        interactionPrompt
                        composerControls
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ComposerOverlayHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                    .onPreferenceChange(ComposerOverlayHeightKey.self) { height in
                        guard abs(composerOverlayHeight - height) >= 0.5 else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            composerOverlayHeight = height
                        }
                    }
                }
            }
        }
    }

    private func sessionActionMenu(_ conversation: Conversation) -> some View {
        Menu {
            Button("Rename Session…", systemImage: "pencil") {
                beginRenaming(conversation)
            }
            if conversation.manualTitle != nil, conversation.agentTitle != nil {
                Button("Use Agent Title", systemImage: "textformat") {
                    model.renameConversation(conversation, title: nil)
                }
            }
            Button(
                conversation.archived == true ? "Unarchive Session" : "Archive Session",
                systemImage: "archivebox"
            ) {
                model.archiveConversation(conversation)
            }
            if SessionLifecyclePolicy.canFork(conversation) {
                Button("Fork Session", systemImage: "arrow.triangle.branch") {
                    model.forkConversation(conversation)
                }
            }
            Button("Promote to Team", systemImage: "person.3") {
                promotingConversation = conversation
            }
            if SessionLifecyclePolicy.canDelete(conversation) {
                Divider()
                Button("Delete Session", systemImage: "trash", role: .destructive) {
                    deletingConversation = conversation
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .help("Session Actions")
        .workspaceAccessibility(.sessionActions)
    }

    private var revisionNavigator: some View {
        SessionRevisionNavigator(
            activeIndex: model.revisionState.activeIndex,
            total: model.revisionState.totalPositions,
            isLoading: model.isChangingRevision,
            onSelect: model.selectRevision(at:)
        )
    }

    private var revisionWorkspaceWarning: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(revisionWorkspaceWarningMessage)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
            Button {
                model.dismissRevisionWorkspaceWarning()
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var revisionWorkspaceWarningMessage: String {
        switch model.revisionState.workspaceWarning {
        case .workspaceChanged:
            String(localized: "The Session was revised, but Project files were kept because the workspace changed.")
        case .checkpointUnavailable:
            String(localized: "The Session was revised, but Project files were kept because no safe checkpoint was available.")
        case .filesKept:
            String(localized: "The Session was revised, but Project files could not be restored.")
        case nil:
            ""
        }
    }

    private func turnActionMenu(runID: String, message: String) -> some View {
        Menu {
            turnActionCommands(runID: runID, message: message)
        } label: {
            Label("Turn Actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 18)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Turn Actions")
    }

    @ViewBuilder
    private func turnActionCommands(runID: String, message: String) -> some View {
        Button("Edit Message…", systemImage: "pencil") {
            editingTurn = TurnEditRequest(runID: runID, originalMessage: message)
        }
        Button("Regenerate Response", systemImage: "arrow.clockwise") {
            model.regenerateTurn(runID)
        }
        if model.canUndoTurn(runID) {
            Button("Undo Turn", systemImage: "arrow.uturn.backward") {
                model.undoTurn(runID)
            }
        }
        Divider()
        Button("Branch from Here…", systemImage: "arrow.triangle.branch") {
            branchingTurn = TurnBranchRequest(runID: runID)
        }
    }

    private var composerControls: some View {
        NativeComposerLayout(expanded: composerUsesExpandedLayout) {
            composerContextMenu
            composerTextInput
            composerTrailingControls
        }
        .frame(maxWidth: 1100)
        .kubecodeComposerGlass(
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .animation(
            .easeInOut(duration: ComposerPresentationMetrics.transitionDuration),
            value: sessionWorkspace.composerHeight
        )
        .animation(
            .easeInOut(duration: ComposerPresentationMetrics.transitionDuration),
            value: composerUsesExpandedLayout
        )
        .onChange(of: sessionWorkspace.composerHeight) { _, height in
            let shouldExpand = height > ComposerHeightCalculator.minimumHeight + 0.5
            guard shouldExpand != sessionWorkspace.composerIsExpanded else { return }
            withAnimation(.easeInOut(duration: ComposerPresentationMetrics.transitionDuration)) {
                sessionWorkspace.composerIsExpanded = shouldExpand
            }
        }
        .onChange(of: model.composer) { _, value in
            guard value.isEmpty, sessionWorkspace.composerIsExpanded else { return }
            withAnimation(.easeInOut(duration: ComposerPresentationMetrics.transitionDuration)) {
                sessionWorkspace.composerIsExpanded = false
            }
        }
    }

    private var composerBarHeight: CGFloat {
        composerUsesExpandedLayout
            ? ComposerPresentationMetrics.expandedBarHeight(contentHeight: sessionWorkspace.composerHeight)
            : ComposerPresentationMetrics.barHeight(contentHeight: sessionWorkspace.composerHeight)
    }

    private var composerUsesExpandedLayout: Bool {
        ComposerPresentationMetrics.shouldUseExpandedLayout(
            measuredHeight: sessionWorkspace.composerHeight,
            stateRequested: sessionWorkspace.composerIsExpanded
        )
    }

    private var composerContextMenu: some View {
        Button {
            sessionWorkspace.composerPalettePresented.toggle()
        } label: {
            Text(Image(systemName: "plus"))
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add Context")
        .workspaceAccessibility(.addContext)
        .popover(isPresented: $sessionWorkspace.composerPalettePresented, arrowEdge: .bottom) {
            ComposerCapabilityPalette(
                commands: model.nativeCommands,
                onChooseCommand: { command in
                    model.insertNativeCommand(command)
                    sessionWorkspace.composerPalettePresented = false
                },
                onChooseFile: {
                    sessionWorkspace.composerPalettePresented = false
                    Task { @MainActor in
                        await Task.yield()
                        sessionWorkspace.composerReferencePickerPresented = true
                    }
                },
                onDismiss: { sessionWorkspace.composerPalettePresented = false }
            )
        }
    }

    private var composerTextInput: some View {
        ZStack(alignment: .topLeading) {
            if model.composer.isEmpty {
                Text("Ask the Agent…")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
#if os(macOS)
            NativeComposerTextView(
                text: $model.composer,
                height: $sessionWorkspace.composerHeight,
                commands: model.nativeCommands,
                onSubmit: { model.sendMessage() }
            )
            .frame(height: sessionWorkspace.composerHeight)
#else
            TextField("Ask the Agent…", text: $model.composer, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
#endif
        }
        .font(typography.swiftUIFont(for: .body))
        .frame(height: sessionWorkspace.composerHeight)
    }

    private var composerProviderControls: some View {
        ZStack {
            if let conversation = model.selectedConversation {
                providerControls(conversation)
            }
        }
        .fixedSize()
    }

    private var composerTrailingControls: some View {
        HStack(spacing: ComposerPresentationMetrics.controlSpacing) {
            composerProviderControls
            composerPrimaryAction
        }
        .fixedSize()
    }

    private var composerPrimaryAction: some View {
        let hasSendableText = !model.composer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let isProminent = ComposerPresentationMetrics.primaryActionIsProminent(
            hasActiveRun: model.activeRun != nil,
            hasSendableText: hasSendableText
        )
        return composerActionButton
            .buttonStyle(.plain)
            .foregroundStyle(
                isProminent
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color(nsColor: .labelColor)
            )
            .background(
                isProminent
                    ? Color(nsColor: .labelColor)
                    : Color(nsColor: .labelColor).opacity(0.055),
                in: Circle()
            )
            .buttonBorderShape(.circle)
            .frame(width: 40, height: 40)
            .disabled(!isProminent)
    }

    private var composerActionButton: some View {
        Button {
            if model.activeRun == nil { model.sendMessage() }
            else { model.cancelActiveRun() }
        } label: {
            Image(systemName: model.activeRun == nil ? "arrow.up" : "stop.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .help(model.activeRun == nil ? "Send" : "Stop Run")
        .workspaceAccessibility(model.activeRun == nil ? .send : .stopRun)
    }

    @ViewBuilder
    private var interactionPrompt: some View {
        if let permission = model.interaction.pendingPermission {
            VStack(alignment: .leading, spacing: 10) {
                Label("Permission required by \(permission.tool)", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    ForEach(permission.options) { choice in
                        if choice.kind.contains("allow") {
                            Button(choice.label) { model.resolvePermission(choice) }
                                .buttonStyle(.borderedProminent)
                                .help(choice.label)
                        } else {
                            Button(choice.label) { model.resolvePermission(choice) }
                                .buttonStyle(.bordered)
                                .help(choice.label)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.1))
            Divider()
        } else if let elicitation = model.interaction.pendingElicitation {
            VStack(alignment: .leading, spacing: 10) {
                Label(elicitation.message, systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                ForEach(elicitation.properties) { property in
                    elicitationControl(property)
                }
                HStack {
                    Spacer()
                    Button("Decline") { model.resolveElicitation(accepted: false) }
                    Button("Continue") { model.resolveElicitation(accepted: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ElicitationResponseBuilder.isComplete(
                            elicitation,
                            answers: model.elicitationAnswers
                        ))
                }
            }
            .padding(12)
            Divider()
        }
    }

    @ViewBuilder
    private func elicitationControl(_ property: ElicitationProperty) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Text(property.label)
                    .font(.caption.weight(.medium))
                if property.required {
                    Text(verbatim: "*")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Required")
                }
                Spacer()
                if property.kind == .boolean {
                    Toggle(isOn: Binding(
                        get: { model.elicitationAnswers[property.id]?.boolValue ?? false },
                        set: {
                            model.setElicitationAnswer(propertyID: property.id, value: .bool($0))
                        }
                    )) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .accessibilityLabel(property.label)
                }
            }

            if !property.description.isEmpty {
                Text(property.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if property.kind != .boolean {
                if !property.options.isEmpty {
                    Picker(selection: elicitationTextBinding(property)) {
                        ForEach(property.options) { Text($0.name).tag($0.id) }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel(property.label)
                } else {
                    TextField(property.label, text: elicitationTextBinding(property))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(property.label)
                }
            }

            if elicitationAnswerHasInvalidContent(property) {
                Text(property.kind == .integer ? "Enter a valid integer." : "Enter a valid number.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func elicitationTextBinding(_ property: ElicitationProperty) -> Binding<String> {
        Binding(
            get: {
                ElicitationResponseBuilder.editableText(
                    property,
                    answer: model.elicitationAnswers[property.id]
                )
            },
            set: {
                model.setElicitationAnswer(propertyID: property.id, value: .string($0))
            }
        )
    }

    private func elicitationAnswerHasInvalidContent(_ property: ElicitationProperty) -> Bool {
        guard property.kind == .integer || property.kind == .number else { return false }
        let answer = model.elicitationAnswers[property.id]
        let text = ElicitationResponseBuilder.editableText(property, answer: answer)
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ElicitationResponseBuilder.isValid(property, answer: answer)
    }

    private func sideQuestionCard(_ question: SideQuestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Side question", systemImage: "bubble.left.and.bubble.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question.question).textSelection(.enabled)
            if let answer = question.answer { Text(answer).textSelection(.enabled) }
            if let error = question.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private var transcriptScrollMarker: String {
        let last = model.transcript.last
        let sideQuestion = model.interaction.sideQuestions.last
        var parts: [String] = []
        parts.append(String(model.transcript.count))
        parts.append(last?.id ?? "")
        parts.append(String(last?.text.utf8.count ?? 0))
        parts.append(String(last?.detail?.utf8.count ?? 0))
        parts.append(last?.status ?? "")
        parts.append(String(model.interaction.sideQuestions.count))
        parts.append(sideQuestion?.id ?? "")
        parts.append(String(sideQuestion?.answer?.utf8.count ?? 0))
        parts.append(String(sideQuestion?.error?.utf8.count ?? 0))
        return parts.joined(separator: ":")
    }

    private var transcriptBottomClearance: CGFloat {
        guard !model.selectedConversationIsReadOnly else { return 24 }
        return max(max(composerOverlayHeight + 8, composerBarHeight + 32), 84)
    }

    private var transcriptJumpButtonBottomPadding: CGFloat {
        model.selectedConversationIsReadOnly ? 16 : transcriptBottomClearance - 4
    }

    private var transcriptSurfaceEntries: [TranscriptSurfaceEntry] {
        var entries: [TranscriptSurfaceEntry] = []
        if model.revisionState.workspaceWarning != nil {
            entries.append(.revisionWarning(revisionWorkspaceWarningMessage))
        }
        if model.historyCursor != nil {
            entries.append(.loadEarlier(isLoading: model.isLoadingEarlierHistory))
        }
        for entry in TranscriptPresentation.entries(
            items: model.transcript,
            activeRunID: model.activeRun?.id
        ) {
            switch entry {
            case let .item(item):
                entries.append(.item(item))
            case let .run(run):
                entries.append(contentsOf: run.userItems.map(TranscriptSurfaceEntry.item))
                if let activity = run.activity {
                    entries.append(.activityHeader(activity))
                }
                if let output = run.output {
                    entries.append(.runOutput(output))
                }
                if let activity = run.activity {
                    entries.append(contentsOf: activityDetailSurfaceEntries(activity))
                }
                entries.append(contentsOf: run.trailingItems.map(TranscriptSurfaceEntry.item))
            }
        }
        entries.append(contentsOf: model.interaction.sideQuestions.map(
            TranscriptSurfaceEntry.sideQuestion
        ))
        return entries
    }

    @ViewBuilder
    private func transcriptSurfaceRow(_ entry: TranscriptSurfaceEntry) -> some View {
        switch entry {
        case .revisionWarning:
            revisionWorkspaceWarning
        case let .loadEarlier(isLoading):
            Button {
                Task { await model.loadEarlierHistory() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Load Earlier", systemImage: "arrow.up.circle")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .frame(maxWidth: .infinity)
        case let .item(item):
            transcriptRow(item)
        case let .activityHeader(activity):
            RunActivityHeaderRow(
                activity: activity,
                isExpanded: transcriptExpansionBinding(
                    for: activity.id,
                    ownerID: activity.id,
                    defaultExpanded: activity.defaultExpanded
                )
            )
        case let .runOutput(output):
            TranscriptRunOutputRow(output: output)
        case let .activityStep(item, ownerID, isCurrent):
            activityStepRow(item, ownerID: ownerID, isCurrent: isCurrent)
                .padding(.leading, 2)
        case let .activityLimit(ownerID, hiddenCount, showsAll):
            Button {
                sessionWorkspace.setShowsAllTranscriptSteps(
                    !showsAll,
                    sessionID: model.selectedConversationID,
                    ownerID: ownerID
                )
            } label: {
                Text(showsAll
                    ? String(localized: "Show recent only")
                    : String(
                        format: String(localized: "Show %lld earlier steps"),
                        Int64(hiddenCount)
                    ))
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .sideQuestion(question):
            sideQuestionCard(question)
        }
    }

    private func activityDetailSurfaceEntries(
        _ activity: TranscriptRunActivity
    ) -> [TranscriptSurfaceEntry] {
        let ownerID = activity.id
        var entries: [TranscriptSurfaceEntry] = []
        guard sessionWorkspace.resolvedTranscriptExpansion(
            sessionID: model.selectedConversationID,
            itemID: ownerID,
            defaultExpanded: activity.defaultExpanded
        ) else { return entries }

        let recentLimit = 8
        let showsAll = sessionWorkspace.showsAllTranscriptSteps(
            sessionID: model.selectedConversationID,
            ownerID: ownerID
        )
        let hiddenCount = activity.hiddenItemCount(limit: recentLimit)
        if hiddenCount > 0 {
            entries.append(.activityLimit(
                ownerID: ownerID,
                hiddenCount: hiddenCount,
                showsAll: showsAll
            ))
        }
        let visible = showsAll ? activity.items : activity.recentItems(limit: recentLimit)
        entries.append(contentsOf: visible.map { item in
            .activityStep(
                item: item,
                ownerID: ownerID,
                isCurrent: activity.isActive && item.id == activity.items.last?.id
            )
        })
        return entries
    }

    private func transcriptSurfaceHeightAuthority(
        _ entry: TranscriptSurfaceEntry
    ) -> NativeTranscriptHeightAuthority {
        switch entry {
        case .runOutput:
            return .versionedRender
        case let .item(item):
            let expanded = item.role == .thinking
                && sessionWorkspace.resolvedTranscriptExpansion(
                    sessionID: model.selectedConversationID,
                    itemID: item.id,
                    defaultExpanded: false
                )
            return TranscriptSurfaceHeightAuthority.resolve(
                role: item.role,
                presentation: .transcriptItem,
                isExpanded: expanded
            )
        case let .activityStep(item, _, _):
            let expanded = item.role == .thinking
                && sessionWorkspace.resolvedTranscriptExpansion(
                    sessionID: model.selectedConversationID,
                    itemID: item.id,
                    defaultExpanded: false
                )
            return TranscriptSurfaceHeightAuthority.resolve(
                role: item.role,
                presentation: .activityStep,
                isExpanded: expanded
            )
        default:
            return .synchronousHosting
        }
    }

    private func transcriptTitle(_ item: TranscriptItem) -> String {
        switch item.role {
        case .user: String(localized: "You")
        case .agent:
            item.eventKind?.replacingOccurrences(of: "_", with: " ").capitalized
                ?? String(localized: "Agent")
        case .thinking: String(localized: "Thinking")
        case .system: String(localized: "Error")
        case .status: localizedRunStatus(item.status ?? item.text)
        case .tool: String(localized: "Tool")
        }
    }

    @ViewBuilder
    private func activityStepRow(
        _ item: TranscriptItem,
        ownerID: String,
        isCurrent: Bool
    ) -> some View {
        switch item.role {
        case .thinking:
            ThinkingTranscriptRow(
                item: item,
                isCurrent: isCurrent,
                isExpanded: transcriptExpansionBinding(for: item.id, ownerID: ownerID)
            )
        case .tool:
            ToolUseTranscriptRow(
                item: item,
                isCurrent: isCurrent,
                isExpanded: transcriptExpansionBinding(for: item.id, ownerID: ownerID)
            )
        case .agent:
            VStack(alignment: .leading, spacing: 5) {
                Label("Update", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                AgentMarkdownView(
                    source: item.text,
                    tone: .secondary,
                    isStreaming: isCurrent
                )
                    .frame(maxWidth: 720, alignment: .leading)
            }
        case .user, .system, .status:
            EmptyView()
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: TranscriptItem) -> some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 5) {
                    UserMessageBubble(source: item.text)
                    if let runID = item.runID, model.canReviseTurn(runID) {
                        turnActionMenu(runID: runID, message: item.text)
                    }
                }
                .contextMenu {
                    if let runID = item.runID, model.canReviseTurn(runID) {
                        turnActionCommands(runID: runID, message: item.text)
                    }
                }
            }
        case .agent:
            AgentMarkdownView(
                source: item.text,
                copyResponseSource: item.text
            )
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            ThinkingTranscriptRow(
                item: item,
                isCurrent: model.activeRun?.id == item.runID,
                isExpanded: transcriptExpansionBinding(for: item.id, ownerID: item.id)
            )
        case .tool:
            ToolUseTranscriptRow(
                item: item,
                isCurrent: model.activeRun?.id == item.runID,
                isExpanded: transcriptExpansionBinding(for: item.id, ownerID: item.id)
            )
        case .system:
            VStack(alignment: .leading, spacing: 5) {
                Label("Error", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text(item.text).textSelection(.enabled)
            }
            .frame(maxWidth: 760, alignment: .leading)
        case .status:
            HStack(spacing: 8) {
                Image(systemName: runStatusSymbol(item.status ?? item.text))
                    .foregroundStyle(runStatusColor(item.status ?? item.text))
                Text(localizedRunStatus(item.status ?? item.text))
                    .textSelection(.enabled)
                Divider()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func localizedRunStatus(_ status: String) -> String {
        switch status {
        case "completed": String(localized: "Completed")
        case "failed": String(localized: "Failed")
        case "cancelled": String(localized: "Cancelled")
        case "timed_out": String(localized: "Timed Out")
        case "interrupted": String(localized: "Interrupted")
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func runStatusSymbol(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle"
        case "timed_out": "clock"
        case "interrupted": "bolt.slash"
        default: "info.circle"
        }
    }

    private func runStatusColor(_ status: String) -> Color {
        switch status {
        case "completed": .green
        case "failed": .red
        case "timed_out", "interrupted": .orange
        default: .secondary
        }
    }

    private func transcriptExpansionBinding(
        for itemID: String,
        ownerID: String,
        defaultExpanded: Bool = false
    ) -> Binding<Bool> {
        Binding(
            get: {
                sessionWorkspace.resolvedTranscriptExpansion(
                    sessionID: model.selectedConversationID,
                    itemID: itemID,
                    defaultExpanded: defaultExpanded
                )
            },
            set: { expanded in
                sessionWorkspace.setTranscriptExpanded(
                    expanded,
                    sessionID: model.selectedConversationID,
                    itemID: itemID,
                    ownerID: ownerID
                )
            }
        )
    }

    private func transcriptShowsAllStepsBinding(ownerID: String) -> Binding<Bool> {
        Binding(
            get: {
                sessionWorkspace.showsAllTranscriptSteps(
                    sessionID: model.selectedConversationID,
                    ownerID: ownerID
                )
            },
            set: { showsAll in
                sessionWorkspace.setShowsAllTranscriptSteps(
                    showsAll,
                    sessionID: model.selectedConversationID,
                    ownerID: ownerID
                )
            }
        )
    }

    private func documentEditor(_ document: TextDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(model.openDocuments, id: \.path) { item in
                            HStack(spacing: 6) {
                                Image(systemName: syntaxIcon(for: item.path))
                                    .font(.caption)
                                    .foregroundStyle(item.path == document.path ? Color.accentColor : .secondary)
                                Button(item.path.split(separator: "/").last.map(String.init) ?? item.path) {
                                    model.selectDocument(item)
                                }
                                .buttonStyle(.plain)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 118, alignment: .leading)
                                if model.isDocumentDirty(item) {
                                    Circle().fill(.secondary).frame(width: 5, height: 5)
                                }
                                Button { model.requestCloseDocument(item) } label: {
                                    Label("Close Document", systemImage: "xmark")
                                        .labelStyle(.iconOnly)
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                .help("Close Document")
                            }
                            .padding(.horizontal, 9)
                            .frame(
                                maxWidth: WorkbenchPresentationMetrics.editorTabMaximumWidth,
                                minHeight: WorkbenchPresentationMetrics.editorTabHeight,
                                maxHeight: WorkbenchPresentationMetrics.editorTabHeight
                            )
                            .background(item.path == document.path ? Color.primary.opacity(0.06) : .clear)
                            .overlay(alignment: .bottom) {
                                if item.path == document.path {
                                    Rectangle().fill(Color.accentColor).frame(height: 2)
                                }
                            }
                            .help(item.path)
                            Divider().frame(height: 18)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: WorkbenchPresentationMetrics.editorTabHeight)
                .clipped()
                if model.isSavingDocument { ProgressView().controlSize(.small) }
                Menu {
                    Button("Find") {
                        model.requestFind()
                    }
                    Button("Find and Replace") {
                        model.requestFindAndReplace()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .help("Find and Replace")
                .workspaceAccessibility(.findAndReplace)
                Button { model.saveDocument() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
                    .help("Save")
                    .workspaceAccessibility(.save)
                    .disabled(!model.canSaveActiveDocument)
                    .keyboardShortcut(
                        WorkspaceKeyboardShortcuts.save.keyEquivalent,
                        modifiers: WorkspaceKeyboardShortcuts.save.modifiers
                    )
            }
            .frame(height: WorkbenchPresentationMetrics.editorTabHeight)
            Divider()
            CodeEditorView(
                text: $model.documentDraft,
                path: document.path,
                findRequest: model.nativeFindRequest
            )
                .clipped()
        }
    }

    private func syntaxIcon(for path: String) -> String {
        switch CodeSyntaxLanguage.detect(path: path) {
        case .swift: "swift"
        case .json, .yaml, .toml: "curlybraces"
        case .markdown: "text.document"
        case .html, .css: "chevron.left.forwardslash.chevron.right"
        case .plainText: "doc.text"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    private func diffViewer(_ diff: GitDiffDocument) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                Text(diff.path).lineLimit(1)
                Text(diff.staged ? "Staged" : "Working Tree")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(diff.content.isEmpty ? "No textual diff." : diff.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var terminalGroupWorkbench: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Terminal", systemImage: "rectangle.bottomhalf.inset.filled")
                    .font(.caption.weight(.semibold))
                if model.terminalWorkspace.groups.count > 1 {
                    Picker("Terminal Group", selection: terminalGroupSelection) {
                        ForEach(model.terminalWorkspace.groups) { group in
                            Text(terminalGroupLabel(group)).tag(group.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 190)
                }
                Spacer()
                terminalCreationMenu
                    .buttonStyle(.borderless)
                    .help("New Terminal")
                    .workspaceAccessibility(.newTerminal)
                    .disabled(model.isCreatingTerminal)
                Button { model.splitActiveTerminal(axis: .horizontal) } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .help("Split Right")
                .workspaceAccessibility(.splitRight)
                .disabled(model.activeTerminal == nil || model.isCreatingTerminal)
                Button { model.splitActiveTerminal(axis: .vertical) } label: {
                    Image(systemName: "rectangle.split.1x2")
                }
                .buttonStyle(.borderless)
                .help("Split Down")
                .workspaceAccessibility(.splitDown)
                .disabled(model.activeTerminal == nil || model.isCreatingTerminal)
                if model.terminalWorkspace.groups.count > 1 {
                    Button { model.moveActiveTerminalGroup(by: -1) } label: {
                        Image(systemName: "arrow.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Move Terminal Group Left")
                    .workspaceAccessibility(.moveGroupLeft)
                    .disabled(!canMoveActiveTerminalGroup(by: -1))
                    Button { model.moveActiveTerminalGroup(by: 1) } label: {
                        Image(systemName: "arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Move Terminal Group Right")
                    .workspaceAccessibility(.moveGroupRight)
                    .disabled(!canMoveActiveTerminalGroup(by: 1))
                }
                Button { model.isTerminalPanelPresented = false } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Hide Terminal Panel")
                .workspaceAccessibility(.hideTerminal)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.bar)
            Divider()
            if let layout = model.terminalWorkspace.activeGroup?.layout {
                TerminalLayoutNodeView(model: model, layout: layout)
            }
        }
    }

    private var terminalGroupSelection: Binding<String> {
        Binding(
            get: { model.terminalWorkspace.activeGroupID ?? "" },
            set: { model.activateTerminalGroup($0) }
        )
    }

    private func terminalGroupLabel(_ group: TerminalGroupState) -> String {
        let title = model.terminals.first { $0.id == group.activeTerminalID }?.title
            ?? String(localized: "Terminal")
        let count = group.layout.terminalIDs.count
        return count > 1 ? "\(title) (\(count))" : title
    }

    private func canMoveActiveTerminalGroup(by offset: Int) -> Bool {
        guard let activeGroupID = model.terminalWorkspace.activeGroupID,
              let index = model.terminalWorkspace.groups.firstIndex(where: { $0.id == activeGroupID })
        else { return false }
        return model.terminalWorkspace.groups.indices.contains(index + offset)
    }

    private var inspector: some View {
        workspaceExplorer
    }

    private var workspaceExplorer: some View {
        VStack(spacing: 0) {
            if model.selectedProjectNeedsFolderAccess, let project = model.selectedProject {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        folderAccessRequiredLabel
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        restoreFolderAccessButton(project)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        folderAccessRequiredLabel
                        restoreFolderAccessButton(project)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.bar)
            }

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                if !model.agentPlanEntries.isEmpty {
                    if model.explorerSections.planExpanded {
                        List {
                            ForEach(Array(model.agentPlanEntries.enumerated()), id: \.offset) { _, entry in
                                agentPlanRow(entry)
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 24)
                        .frame(minHeight: 0, idealHeight: explorerPlanHeight, maxHeight: 180)
                    }
                    explorerDisclosureHeader(
                        "Agent Plan",
                        systemImage: "checklist",
                        detail: "\(completedPlanEntries)/\(model.agentPlanEntries.count)",
                        isExpanded: explorerPlanExpanded
                    )
                    .background(WorkspaceLayoutAnchor(identifier: "navigator.plan-header.layout"))
                }

                if model.explorerSections.changesExpanded {
                    List { explorerChangesContent }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 24)
                        .frame(minHeight: 0, idealHeight: explorerChangesHeight, maxHeight: 260)
                }
                explorerDisclosureHeader(
                    "Changes",
                    systemImage: "arrow.triangle.branch",
                    detail: model.gitStatus.map { String($0.files.count) },
                    isExpanded: explorerChangesExpanded
                )
                .background(WorkspaceLayoutAnchor(identifier: "navigator.changes-header.layout"))

                if model.explorerSections.filesExpanded {
                    List { explorerFilesContent }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 24)
                        .frame(minHeight: 120, maxHeight: .infinity)
                        .layoutPriority(1)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("explorer.files-list")
                        .background(WorkspaceLayoutAnchor(identifier: "explorer.files-list.layout"))
                }
                explorerDisclosureHeader(
                    "Files",
                    systemImage: "folder",
                    detail: nil,
                    isExpanded: explorerFilesExpanded
                )
                .background(WorkspaceLayoutAnchor(identifier: "navigator.files-header.layout"))
            }
            .frame(
                maxWidth: .infinity,
                idealHeight: 360,
                maxHeight: .infinity,
                alignment: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func explorerDisclosureHeader(
        _ title: LocalizedStringKey,
        systemImage: String,
        detail: String?,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: ComposerPresentationMetrics.transitionDuration)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 12)
                explorerSectionLabel(title, systemImage: systemImage, detail: detail)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var folderAccessRequiredLabel: some View {
        Label("Folder Access Required", systemImage: "folder.badge.questionmark")
            .foregroundStyle(.secondary)
    }

    private func restoreFolderAccessButton(_ project: Project) -> some View {
        Button("Restore Folder Access…") {
            model.reauthorizeProject(project)
        }
    }

    @ViewBuilder
    private var explorerChangesContent: some View {
        if model.selectedProjectNeedsFolderAccess {
            EmptyView()
        } else if let status = model.gitStatus, status.isRepository {
            HStack {
                Label(status.branch ?? String(localized: "Repository"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .lineLimit(1)
                Spacer()
                Button { model.refreshGitStatus() } label: {
                    Label("Refresh Changes", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                    .buttonStyle(.borderless)
                    .help("Refresh Changes")
                    .workspaceAccessibility(.refreshChanges)
            }
            if status.files.isEmpty {
                Label("No Changes", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                if !stagedChanges.isEmpty {
                    gitSectionHeader(
                        title: "Staged Changes",
                        count: stagedChanges.count,
                        actionIcon: "minus",
                        actionHelp: "Unstage All"
                    ) { model.mutateGit(stagedChanges, action: .unstage) }
                    ForEach(stagedChanges) { file in gitChangeRow(file, staged: true) }
                }
                if !worktreeChanges.isEmpty {
                    gitSectionHeader(
                        title: "Changes",
                        count: worktreeChanges.count,
                        actionIcon: "plus",
                        actionHelp: "Stage All"
                    ) { model.mutateGit(worktreeChanges, action: .stage) }
                    ForEach(worktreeChanges) { file in gitChangeRow(file, staged: false) }
                }
                if !stagedChanges.isEmpty {
                    HStack {
                        TextField("Commit message", text: $model.commitMessage)
                            .textFieldStyle(.roundedBorder)
                        Button { model.commitGit() } label: {
                            Label("Commit", systemImage: "arrow.triangle.branch")
                                .labelStyle(.iconOnly)
                        }
                            .buttonStyle(.borderless)
                            .help("Commit")
                            .workspaceAccessibility(.commitChanges)
                            .disabled(model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        } else {
            Label("No Git Repository", systemImage: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Button("Initialize Repository") { model.initializeGit() }
        }
    }

    @ViewBuilder
    private var explorerFilesContent: some View {
        let hiddenFilesLabel = showHidden
            ? String(localized: "Hide hidden files")
            : String(localized: "Show hidden files")
        HStack {
            Text(model.selectedProject?.name ?? String(localized: "Project"))
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button { model.refreshFileTree() } label: {
                Label("Refresh Files", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
                .buttonStyle(.borderless)
                .help("Refresh Files")
                .workspaceAccessibility(.refreshFiles)
                .disabled(!model.canUseSelectedProjectFiles)
            Button {
                showHidden.toggle()
            } label: {
                Label(
                    hiddenFilesLabel,
                    systemImage: ExplorerFilterPresentation.hiddenFilesSymbol(showHidden: showHidden)
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(hiddenFilesLabel)
            .workspaceAccessibility(.toggleHiddenFiles)
            .accessibilityLabel(hiddenFilesLabel)
            Menu {
                Toggle("Show ignored files", isOn: $showIgnored)
                Toggle("Show generated files", isOn: $showGenerated)
            } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton)
                .help("File Visibility")
                .workspaceAccessibility(.fileVisibility)
            Menu {
                Button("New File", systemImage: "doc.badge.plus") {
                    prepareEntry(kind: "file", parent: "")
                }
                Button("New Folder", systemImage: "folder.badge.plus") {
                    prepareEntry(kind: "directory", parent: "")
                }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .workspaceAccessibility(.newFileOrFolder)
                .disabled(!model.canUseSelectedProjectFiles)
        }

        if model.selectedProjectNeedsFolderAccess {
            EmptyView()
        } else if model.fileTreeLoadingPaths.contains("")
                    && model.fileTree.visibleRows(
                        showHidden: showHidden,
                        showIgnored: showIgnored,
                        showGenerated: showGenerated
                    ).isEmpty {
            ProgressView()
        } else {
            ForEach(model.fileTree.visibleRows(
                showHidden: showHidden,
                showIgnored: showIgnored,
                showGenerated: showGenerated
            )) { row in
                fileTreeRow(row)
                    .contextMenu { fileTreeContextMenu(for: row.entry) }
            }
        }
    }

    private func explorerSectionLabel(
        _ title: LocalizedStringKey,
        systemImage: String,
        detail: String?
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let detail, detail != "0" {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func agentPlanRow(_ entry: AgentPlanEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: planStatusSymbol(entry.status))
                .foregroundStyle(planStatusColor(entry.status))
                .frame(width: 14)
            Text(entry.content)
                .strikethrough(entry.status == .completed)
                .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if entry.priority != "medium" {
                Text(entry.priority.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption2)
                    .foregroundStyle(entry.priority == "high" ? Color.orange : .secondary)
            }
        }
    }

    @ViewBuilder
    private func fileTreeContextMenu(for entry: FileEntry) -> some View {
        if entry.kind == "directory" {
            Button("New File", systemImage: "doc.badge.plus") {
                prepareEntry(kind: "file", parent: entry.path)
            }
            Button("New Folder", systemImage: "folder.badge.plus") {
                prepareEntry(kind: "directory", parent: entry.path)
            }
            Divider()
        }
        Button("Rename…", systemImage: "pencil") {
            entryDraft = entry.path
            renamingEntry = entry
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            deletingEntry = entry
        }
    }

    private var explorerChangesExpanded: Binding<Bool> {
        Binding(
            get: { model.explorerSections.changesExpanded },
            set: { model.explorerSections.changesExpanded = $0 }
        )
    }

    private var explorerPlanExpanded: Binding<Bool> {
        Binding(
            get: { model.explorerSections.planExpanded },
            set: { model.explorerSections.planExpanded = $0 }
        )
    }

    private var explorerFilesExpanded: Binding<Bool> {
        Binding(
            get: { model.explorerSections.filesExpanded },
            set: { model.explorerSections.filesExpanded = $0 }
        )
    }

    private var completedPlanEntries: Int {
        model.agentPlanEntries.count { $0.status == .completed }
    }

    private var explorerChangesHeight: CGFloat {
        guard model.explorerSections.changesExpanded else { return 0 }
        let stagedRows = stagedChanges.isEmpty ? 0 : stagedChanges.count + 1
        let worktreeRows = worktreeChanges.isEmpty ? 0 : worktreeChanges.count + 1
        let commitRows = stagedChanges.isEmpty ? 0 : 1
        return min(max(CGFloat(1 + stagedRows + worktreeRows + commitRows) * 28 + 8, 64), 260)
    }

    private var explorerPlanHeight: CGFloat {
        guard model.explorerSections.planExpanded else { return 0 }
        return min(max(CGFloat(model.agentPlanEntries.count) * 30 + 8, 44), 180)
    }

    private var explorerPreferredHeight: CGFloat {
        let visibleHeaderCount = model.agentPlanEntries.isEmpty ? 2 : 3
        let planHeight = model.agentPlanEntries.isEmpty ? 0 : explorerPlanHeight
        let filesHeight: CGFloat = model.explorerSections.filesExpanded ? 120 : 0
        let folderAccessHeight: CGFloat = model.selectedProjectNeedsFolderAccess ? 52 : 0
        return CGFloat(visibleHeaderCount) * 30
            + planHeight
            + explorerChangesHeight
            + filesHeight
            + folderAccessHeight
    }

    private func explorerHeight(availableHeight: CGFloat) -> CGFloat {
        let visibleHeaderCount = model.agentPlanEntries.isEmpty ? 2 : 3
        let minimum = CGFloat(visibleHeaderCount) * 30
            + (model.explorerSections.filesExpanded ? 120 : 0)
        let maximum = max(minimum, availableHeight - 290)
        return min(max(explorerPreferredHeight, minimum), maximum)
    }

    private func planStatusSymbol(_ status: AgentPlanEntryStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .pending: "circle"
        }
    }

    private func planStatusColor(_ status: AgentPlanEntryStatus) -> Color {
        switch status {
        case .completed: .green
        case .inProgress: .accentColor
        case .pending: .secondary
        }
    }

    private var stagedChanges: [GitFileChange] {
        GitChangeGroups(files: model.gitStatus?.files ?? []).staged
    }

    private var worktreeChanges: [GitFileChange] {
        GitChangeGroups(files: model.gitStatus?.files ?? []).worktree
    }

    private func fileTreeRow(_ row: ProjectFileTreeRow) -> some View {
        Button { model.openFile(row.entry) } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                if row.entry.kind == "directory" {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: row.isExpanded ? "folder.fill" : "folder")
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                    Image(systemName: syntaxIcon(for: row.entry.path))
                        .foregroundStyle(.secondary)
                }
                Text(row.entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if model.fileTreeLoadingPaths.contains(row.entry.path) {
                    ProgressView().controlSize(.mini)
                }
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(row.entry.path)
    }

    private func gitChangeRow(_ file: GitFileChange, staged: Bool) -> some View {
        HStack(spacing: 7) {
            Button { model.openChange(file, staged: staged) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(staged ? file.indexStatus ?? "" : file.worktreeStatus ?? "")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if staged {
                Button { model.mutateGit(file, action: .unstage) } label: {
                    Label("Unstage", systemImage: "minus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Unstage")
            } else {
                Button { model.mutateGit(file, action: .stage) } label: {
                    Label("Stage", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Stage")
                Button(role: .destructive) { discardingChange = file } label: {
                    Label("Discard Changes", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Discard Changes")
            }
        }
    }

    private func gitSectionHeader(
        title: LocalizedStringKey,
        count: Int,
        actionIcon: String,
        actionHelp: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Text(verbatim: "\(count)").foregroundStyle(.tertiary)
            Spacer()
            Button(action: action) {
                Label(actionHelp, systemImage: actionIcon)
                    .labelStyle(.iconOnly)
            }
                .buttonStyle(.borderless)
                .help(actionHelp)
        }
    }

    private func prepareEntry(kind: String, parent: String) {
        entryDraft = parent.isEmpty ? "" : parent + "/"
        entryPromptKind = kind
    }

    private var terminalCreationMenu: some View {
        Menu {
            Button("Regular Terminal", systemImage: "terminal") {
                model.createTerminal(kind: .regular)
            }
            if model.selectedConversation != nil, !model.availableAgents.isEmpty {
                Section("Agent TUI") {
                    ForEach(model.availableAgents) { agent in
                        Button {
                            model.createTerminal(kind: TerminalKind(agentID: agent.id))
                        } label: {
                            AgentIdentityLabel(agentID: agent.id)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "terminal")
        }
        .menuIndicator(.hidden)
    }

    private func providerControls(_ conversation: Conversation) -> some View {
        HStack(spacing: 9) {
            AgentIdentityLabel(agentID: conversation.agentID, iconSize: 13)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if !model.nativeModes.isEmpty {
                composerModeControl
            }

            ForEach(model.nativeConfigs) { config in
                if config.isBoolean {
                    composerBooleanConfigControl(config)
                } else {
                    composerConfigControl(config)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var composerModeControl: some View {
        let controlID = "mode"
        let canChange = model.sessionState?.modeAccess.canChange != false
        return Button {
            toggleComposerProviderControl(controlID)
        } label: {
            composerProviderControlLabel(
                currentModeLabel,
                isPresented: sessionWorkspace.openComposerProviderControlID == controlID
            )
        }
        .buttonStyle(.plain)
        .disabled(!canChange)
        .help(model.sessionState?.modeAccess.reason ?? "Session Mode")
        .popover(isPresented: composerProviderControlBinding(controlID), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                composerProviderSectionTitle("Session Mode")
                ForEach(model.nativeModes) { mode in
                    composerProviderChoice(
                        title: mode.name,
                        isSelected: mode.id == model.currentNativeModeID
                    ) {
                        model.setNativeMode(mode)
                        sessionWorkspace.openComposerProviderControlID = nil
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 190, alignment: .leading)
        }
    }

    private func composerConfigControl(_ config: NativeConfig) -> some View {
        let controlID = "config:\(config.id)"
        return Button {
            toggleComposerProviderControl(controlID)
        } label: {
            composerProviderControlLabel(
                currentConfigLabel(config),
                isPresented: sessionWorkspace.openComposerProviderControlID == controlID
            )
        }
        .buttonStyle(.plain)
        .help(config.name)
        .popover(isPresented: composerProviderControlBinding(controlID), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                composerProviderSectionTitle(config.name)
                ForEach(config.choices) { choice in
                    composerProviderChoice(
                        title: choice.name,
                        isSelected: config.currentValue == choice.value
                    ) {
                        model.setNativeConfig(config, choice: choice)
                        sessionWorkspace.openComposerProviderControlID = nil
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 190, alignment: .leading)
        }
    }

    private func composerBooleanConfigControl(_ config: NativeConfig) -> some View {
        Toggle(
            config.name,
            isOn: Binding(
                get: { config.currentValue?.boolValue ?? false },
                set: { model.setNativeConfig(config, value: .bool($0)) }
            )
        )
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
        .help(config.name)
    }

    private func composerProviderControlLabel(
        _ title: String,
        isPresented: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .rotationEffect(.degrees(
                    ComposerPresentationMetrics.agentDisclosureRotation(
                        isPresented: isPresented
                    )
                ))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(height: 30)
        .contentShape(Rectangle())
        .animation(
            .easeInOut(duration: ComposerPresentationMetrics.transitionDuration),
            value: isPresented
        )
    }

    private func composerProviderSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func composerProviderChoice(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                Spacer(minLength: 24)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var currentModeLabel: String {
        guard let current = model.currentNativeModeID,
              let mode = model.nativeModes.first(where: { $0.id == current })
        else { return "Mode" }
        return mode.name
    }

    private func currentConfigLabel(_ config: NativeConfig) -> String {
        guard let choice = config.choices.first(where: { $0.value == config.currentValue }) else {
            return config.name
        }
        return choice.name
    }

    private func toggleComposerProviderControl(_ id: String) {
        withAnimation(.easeInOut(duration: ComposerPresentationMetrics.transitionDuration)) {
            sessionWorkspace.openComposerProviderControlID = sessionWorkspace.openComposerProviderControlID == id ? nil : id
        }
    }

    private func composerProviderControlBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { sessionWorkspace.openComposerProviderControlID == id },
            set: { isPresented in
                if isPresented { sessionWorkspace.openComposerProviderControlID = id }
                else if sessionWorkspace.openComposerProviderControlID == id { sessionWorkspace.openComposerProviderControlID = nil }
            }
        )
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { deletingConversation != nil },
            set: { if !$0 { deletingConversation = nil } }
        )
    }

    private var unregisterProjectAlertPresented: Binding<Bool> {
        Binding(
            get: { unregisteringProject != nil },
            set: { if !$0 { unregisteringProject = nil } }
        )
    }

    private var entryAlertPresented: Binding<Bool> {
        Binding(
            get: { entryPromptKind != nil || renamingEntry != nil },
            set: { if !$0 { entryPromptKind = nil; renamingEntry = nil } }
        )
    }

    private var deleteEntryAlertPresented: Binding<Bool> {
        Binding(get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } })
    }

    private var renameTerminalAlertPresented: Binding<Bool> {
        Binding(get: { renamingTerminal != nil }, set: { if !$0 { renamingTerminal = nil } })
    }

    private func statusDot(_ status: String) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
            .help(status.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    private func agentUsageControl(_ usage: AgentUsage) -> some View {
        Button {
            sessionWorkspace.usageIsPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.medium")
                Text(verbatim: "\(usage.percentage)%")
                    .monospacedDigit()
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Context Usage")
        .workspaceAccessibility(.contextUsage)
        .accessibilityValue(Text(verbatim: "\(usage.percentage)%"))
        .popover(isPresented: $sessionWorkspace.usageIsPresented, arrowEdge: .top) {
            agentUsagePopover(usage)
        }
    }

    private func agentUsagePopover(_ usage: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Context Usage", systemImage: "gauge.medium")
                .font(.headline)
            ProgressView(value: usage.fraction)
                .progressViewStyle(.linear)
                .accessibilityLabel("Context Usage")
                .accessibilityValue(Text(verbatim: "\(usage.percentage)%"))
            LabeledContent("Tokens") {
                Text(verbatim: "\(usage.used.formatted()) / \(usage.size.formatted())")
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            if let cost = usage.cost {
                LabeledContent("Session Cost") {
                    Text(verbatim: "\(formattedUsageCost(cost.amount)) \(cost.currency)")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 280)
    }

    private func formattedUsageCost(_ amount: Double) -> String {
        amount.formatted(.number.precision(.fractionLength(0 ... 6)))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running", "active", "starting": .green
        case "waiting_permission", "needs_attention", "queued", "paused": .orange
        case "failed", "cancelled", "timed_out": .red
        default: .secondary
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).textSelection(.enabled).lineLimit(3)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error, forType: .string) } label: {
                Label("Copy Error", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Copy Error")
            .workspaceAccessibility(.copyError)
            Button { model.dismissError() } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .workspaceAccessibility(.dismissError)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var runtimeLabel: String {
        switch model.runtime.state {
        case .stopped: "Runtime stopped"
        case .starting: "Starting Runtime…"
        case let .ready(ready): "Local · \(ready.serverVersion)"
        case .failed: "Runtime unavailable"
        }
    }
}

private struct TranscriptJumpToLatestButton: View {
    @Bindable var controller: TranscriptScrollController
    let action: () -> Void

    var body: some View {
        if !controller.followsOutput {
            Button(action: action) {
                Image(systemName: controller.hasUnseenOutput
                    ? "arrow.down.circle.fill"
                    : "arrow.down")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Scroll to Latest Output")
            .workspaceAccessibility(.scrollLatestOutput)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

private struct UserMessageBubble: View {
    @Environment(\.workspaceTypography) private var typography
    let source: String

    var body: some View {
        AgentMarkdownView(source: source)
            .padding(.horizontal, UserMessageBubbleMetrics.horizontalPadding / 2)
            .padding(.vertical, 11)
            .frame(width: UserMessageBubbleMetrics.width(for: source, typography: typography), alignment: .leading)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TranscriptDisclosureGroup<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    private let content: () -> Content
    private let label: () -> Label

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        _isExpanded = isExpanded
        self.content = content
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10, height: 12)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.12), value: isExpanded)
                    label()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .transition(.identity)
                    .transaction { $0.animation = nil }
            }
        }
    }
}

private struct ThinkingTranscriptRow: View {
    let item: TranscriptItem
    let isCurrent: Bool
    @Binding var isExpanded: Bool

    init(item: TranscriptItem, isCurrent: Bool, isExpanded: Binding<Bool>) {
        self.item = item
        self.isCurrent = isCurrent
        _isExpanded = isExpanded
    }

    var body: some View {
        TranscriptDisclosureGroup(isExpanded: $isExpanded) {
            AgentMarkdownView(
                source: item.text,
                tone: .secondary,
                isStreaming: isCurrent
            )
                .font(.callout)
                .frame(maxWidth: 720, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 7) {
                if isCurrent { ProgressView().controlSize(.mini) }
                else { Image(systemName: "brain") }
                Text(thoughtSummary)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var thoughtSummary: String {
        let firstLine = item.text
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else { return String(localized: "Thought") }
        return firstLine
    }
}

private struct RunActivityHeaderRow: View {
    let activity: TranscriptRunActivity
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 10)
                activitySymbol
                Text(activityLabel)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(activity.status == "failed" ? .red : .secondary)
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private var activitySymbol: some View {
        if activity.isActive {
            ProgressView().controlSize(.mini)
        } else if activity.status == "completed" {
            Image(systemName: "checkmark.circle")
        } else if activity.status != nil {
            Image(systemName: "exclamationmark.circle")
        } else {
            Image(systemName: "sparkles")
        }
    }

    private var activityLabel: String {
        let title: String
        if activity.isActive {
            title = String(localized: "Working")
        } else if activity.status == "completed" {
            title = String(localized: "Worked")
        } else if activity.status != nil {
            title = String(localized: "Stopped")
        } else {
            title = String(localized: "Activity")
        }
        let stepUnit = activity.stepCount == 1
            ? String(localized: "step")
            : String(localized: "steps")
        let steps = "\(activity.stepCount) \(stepUnit)"
        guard activity.toolCount > 0 else { return "\(title) · \(steps)" }
        let toolUnit = activity.toolCount == 1
            ? String(localized: "tool")
            : String(localized: "tools")
        return "\(title) · \(steps) · \(activity.toolCount) \(toolUnit)"
    }
}

private struct RunActivityTranscriptRow: View {
    private static let recentStepLimit = 8

    let activity: TranscriptRunActivity
    @Binding var isExpanded: Bool
    @Binding var showsAllSteps: Bool
    let expansionBindingForItem: (String) -> Binding<Bool>

    var body: some View {
        TranscriptDisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                if hiddenStepCount > 0, !showsAllSteps {
                    Button {
                        showsAllSteps = true
                    } label: {
                        Text(String(
                            format: String(localized: "Show %lld earlier steps"),
                            Int64(hiddenStepCount)
                        ))
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if activity.items.count > Self.recentStepLimit, showsAllSteps {
                    Button("Show recent only") {
                        showsAllSteps = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                ForEach(visibleItems) { item in
                    activityStep(item, isCurrent: activity.isActive && item.id == activity.items.last?.id)
                }
            }
            .padding(.top, 7)
            .padding(.leading, 2)
        } label: {
            HStack(spacing: 7) {
                activitySymbol
                Text(activityLabel)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(activity.status == "failed" ? .red : .secondary)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private func activityStep(_ item: TranscriptItem, isCurrent: Bool) -> some View {
        switch item.role {
        case .thinking:
            ThinkingTranscriptRow(
                item: item,
                isCurrent: isCurrent,
                isExpanded: expansionBindingForItem(item.id)
            )
        case .tool:
            ToolUseTranscriptRow(
                item: item,
                isCurrent: isCurrent,
                isExpanded: expansionBindingForItem(item.id)
            )
        case .agent:
            VStack(alignment: .leading, spacing: 5) {
                Label("Update", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                AgentMarkdownView(source: item.text, tone: .secondary)
                    .frame(maxWidth: 720, alignment: .leading)
            }
        case .user, .system, .status:
            EmptyView()
        }
    }

    @ViewBuilder
    private var activitySymbol: some View {
        if activity.isActive {
            ProgressView().controlSize(.mini)
        } else if activity.status == "completed" {
            Image(systemName: "checkmark.circle")
        } else if activity.status != nil {
            Image(systemName: "exclamationmark.circle")
        } else {
            Image(systemName: "sparkles")
        }
    }

    private var visibleItems: [TranscriptItem] {
        showsAllSteps ? activity.items : activity.recentItems(limit: Self.recentStepLimit)
    }

    private var hiddenStepCount: Int {
        activity.hiddenItemCount(limit: Self.recentStepLimit)
    }

    private var activityLabel: String {
        let title: String
        if activity.isActive {
            title = String(localized: "Working")
        } else if activity.status == "completed" {
            title = String(localized: "Worked")
        } else if activity.status != nil {
            title = String(localized: "Stopped")
        } else {
            title = String(localized: "Activity")
        }
        let steps = stepCountLabel
        guard activity.toolCount > 0 else { return "\(title) · \(steps)" }
        return "\(title) · \(steps) · \(toolCountLabel)"
    }

    private var stepCountLabel: String {
        let unit = activity.stepCount == 1
            ? String(localized: "step")
            : String(localized: "steps")
        return "\(activity.stepCount) \(unit)"
    }

    private var toolCountLabel: String {
        let unit = activity.toolCount == 1
            ? String(localized: "tool")
            : String(localized: "tools")
        return "\(activity.toolCount) \(unit)"
    }
}

struct TranscriptActivityDisclosureState: Equatable {
    private(set) var userValue: Bool?

    func resolved(defaultExpanded: Bool) -> Bool {
        userValue ?? defaultExpanded
    }

    mutating func userSet(_ value: Bool) {
        userValue = value
    }
}

private struct ToolUseTranscriptRow: View {
    let item: TranscriptItem
    let isCurrent: Bool
    @Binding var isExpanded: Bool

    init(
        item: TranscriptItem,
        isCurrent: Bool = false,
        isExpanded: Binding<Bool>
    ) {
        self.item = item
        self.isCurrent = isCurrent
        _isExpanded = isExpanded
    }

    var body: some View {
        TranscriptDisclosureGroup(isExpanded: $isExpanded) {
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                Text(item.text)
                    .lineLimit(1)
                Spacer()
                Text((item.status ?? "pending").replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 720, alignment: .leading)
    }

}
