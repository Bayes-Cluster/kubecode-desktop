import AppKit
import SwiftUI
import KubecodeKit

struct WorkspaceLayoutAnchor: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier(identifier)
    }
}

struct NavigatorSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(frame: .zero)
        searchField.delegate = context.coordinator
        searchField.placeholderString = String(localized: "Search Sessions")
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityIdentifier("navigator.search")
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isPresented = $isPresented
        if nsView.stringValue != text { nsView.stringValue = text }
        guard isPresented, nsView.window?.firstResponder !== nsView.currentEditor() else { return }
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, nsView.window != nil else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var isPresented: Binding<Bool>

        init(text: Binding<String>, isPresented: Binding<Bool>) {
            self.text = text
            self.isPresented = isPresented
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isPresented.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isPresented.wrappedValue = false
        }
    }
}

enum WorkspaceNavigationSidebarMetrics {
    static let columnMinimumWidth: CGFloat = 210
    static let columnIdealWidth: CGFloat = 250
    static let columnMaximumWidth: CGFloat = 310
    static let serverSwitcherHeight: CGFloat = 30
    static let serverSwitcherWidth: CGFloat = 140
    static let toolbarControlSize = WorkspaceToolbarSymbolMetrics.buttonSize
    static let toolbarSymbolLayoutSize = WorkspaceToolbarSymbolMetrics.layoutSize
    static let toolbarSpacing: CGFloat = 14
}

struct NavigatorToolbarControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(
                width: WorkspaceNavigationSidebarMetrics.toolbarControlSize,
                height: WorkspaceNavigationSidebarMetrics.toolbarControlSize
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

private enum WorkspaceActivitySelection: Hashable {
    case conversation(String)
    case team(String)
}

struct WorkspaceRuntimeFooter: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isReady ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Menu {
                Button("Local Runtime") { model.connect(to: nil) }
                if !model.serverProfiles.isEmpty {
                    Divider()
                    ForEach(model.serverProfiles) { profile in
                        Button(profile.name) { model.connect(to: profile) }
                    }
                }
                Divider()
                SettingsLink { Label("Server Settings…", systemImage: "gear") }
            } label: {
                Text(model.currentServerName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .controlSize(.small)
            .frame(
                width: WorkspaceNavigationSidebarMetrics.serverSwitcherWidth,
                height: WorkspaceNavigationSidebarMetrics.serverSwitcherHeight,
                alignment: .leading
            )
            .clipped()
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(
            minHeight: WorkspaceNavigationSidebarMetrics.serverSwitcherHeight,
            idealHeight: WorkspaceNavigationSidebarMetrics.serverSwitcherHeight,
            maxHeight: WorkspaceNavigationSidebarMetrics.serverSwitcherHeight
        )
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .clipped()
        .accessibilityIdentifier("navigator.runtime-footer")
        .background(WorkspaceLayoutAnchor(identifier: "navigator.runtime-footer.layout"))
    }
}

struct WorkspaceNavigationResultRow: View {
    let item: WorkspaceNavigationItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(item.attentionCount > 0 ? Color.orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                HStack(spacing: 5) {
                    if item.kind != .project { Text(item.projectName).lineLimit(1) }
                    if !item.detail.isEmpty, item.detail != item.projectName {
                        Text(item.detail).lineLimit(1)
                    }
                    if let status = item.status {
                        Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if item.attentionCount > 0 {
                Label {
                    Text(verbatim: "\(item.attentionCount)")
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    .help("Needs Attention")
            } else if let status = item.status {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(minHeight: 38)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var systemImage: String {
        switch item.kind {
        case .project: "folder"
        case .conversation: "bubble.left"
        case .team: "person.3"
        }
    }
}

struct WorkspaceNavigationSearchResults: View {
    let isSearching: Bool
    let results: [WorkspaceNavigationItem]
    let onOpen: (WorkspaceNavigationItem) -> Void

    var body: some View {
        List {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").foregroundStyle(.secondary)
                }
            } else if results.isEmpty {
                Label("No Results", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            } else {
                Section("Results") {
                    ForEach(results) { item in
                        Button { onOpen(item) } label: {
                            WorkspaceNavigationResultRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct WorkspaceNavigationSidebar: View {
    @Bindable var model: AppModel
    let onRename: (Conversation) -> Void
    let onDelete: (Conversation) -> Void
    let onPromote: (Conversation) -> Void
    let onDisableWorkspaces: (Project) -> Void
    let onRemoveProject: (Project) -> Void
    @Binding var showArchivedSessions: Bool
    @Binding var sessionAgentFilter: String
    @Binding var sessionSort: String
    @SceneStorage("navigation.expandedSessionIDs") private var storedExpandedSessionIDs = ""
    @State private var expandedSessionIDSet: Set<String> = []

    init(
        model: AppModel,
        onRename: @escaping (Conversation) -> Void,
        onDelete: @escaping (Conversation) -> Void,
        onPromote: @escaping (Conversation) -> Void,
        onDisableWorkspaces: @escaping (Project) -> Void,
        onRemoveProject: @escaping (Project) -> Void,
        showArchivedSessions: Binding<Bool> = .constant(false),
        sessionAgentFilter: Binding<String> = .constant("all"),
        sessionSort: Binding<String> = .constant(SessionNavigationSort.activity.rawValue)
    ) {
        self.model = model
        self.onRename = onRename
        self.onDelete = onDelete
        self.onPromote = onPromote
        self.onDisableWorkspaces = onDisableWorkspaces
        self.onRemoveProject = onRemoveProject
        _showArchivedSessions = showArchivedSessions
        _sessionAgentFilter = sessionAgentFilter
        _sessionSort = sessionSort
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarSearchField
            projectSwitcher
            Group {
                if model.navigationSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    activityList
                } else {
                    searchResultsList
                }
            }
            .onAppear {
                expandedSessionIDSet = decodedExpandedSessionIDs
                revealSelectedConversation()
            }
            .onChange(of: model.selectedConversationID) { revealSelectedConversation() }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarSearchField: some View {
        NavigatorSearchField(
            text: searchBinding,
            isPresented: $model.isNavigationSearchPresented
        )
        .frame(height: 28)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var projectSwitcher: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.projects) { project in
                    Button {
                        if project.id != model.selectedProjectID { model.selectProject(project) }
                    } label: {
                        if project.id == model.selectedProjectID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
                Divider()
                Button("Add Project…", systemImage: "folder.badge.plus") {
                    model.presentProjectRegistration()
                }
            } label: {
                Label(model.selectedProject?.name ?? String(localized: "Project"), systemImage: "folder")
                    .lineLimit(1)
            }
            .menuIndicator(.visible)

            Spacer(minLength: 4)

            if let project = model.selectedProject {
                Menu {
                    if model.isLocalManagedConnection {
                        Button("Restore Folder Access…", systemImage: "folder.badge.questionmark") {
                            model.reauthorizeProject(project)
                        }
                    }
                    Button(project.workspacesEnabled ? "Disable Workspaces..." : "Enable Workspaces") {
                        if project.workspacesEnabled { onDisableWorkspaces(project) }
                        else { model.setWorkspacesEnabled(project, enabled: true) }
                    }
                    Divider()
                    Button("Remove Project", systemImage: "minus.circle", role: .destructive) {
                        onRemoveProject(project)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .buttonStyle(NavigatorToolbarControlStyle())
                .help("Project Actions")
                .workspaceAccessibility(.projectActions)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var activityList: some View {
        List(selection: activitySelection) {
            ForEach(sessionSections) { section in
                Section {
                    sessionTreeRows(section.roots)
                } header: {
                    Text(section.id.title)
                }
            }
            if sessionSections.isEmpty {
                Section("Sessions") {
                    Label("No Sessions", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                        .foregroundStyle(.secondary)
                }
            }
            if !model.teams.isEmpty {
                Section("Teams") {
                    ForEach(model.teams) { snapshot in
                        teamRow(snapshot)
                            .tag(WorkspaceActivitySelection.team(snapshot.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
        .contextMenu {
            newSessionContextMenu
        }
    }

    private var searchResultsList: some View {
        WorkspaceNavigationSearchResults(
            isSearching: model.isSearchingNavigation,
            results: model.navigationSearchResults,
            onOpen: open
        )
    }

    @ViewBuilder
    private var newSessionContextMenu: some View {
        Button("New Session...", systemImage: "plus.bubble") {
            model.presentSessionSetup()
        }
        .workspaceAccessibility(.newSession)
        .disabled(model.selectedProject == nil || model.availableAgents.isEmpty)
    }

    private var attentionMenu: some View {
        Menu {
            Section("Needs Attention") {
                ForEach(model.navigationAttentionItems) { item in
                    Button { open(item) } label: {
                        Label {
                            Text(verbatim: "\(item.title) — \(item.projectName)")
                        } icon: {
                            Image(systemName: item.kind == .team ? "person.3.fill" : "bubble.left.fill")
                        }
                    }
                }
            }
        } label: {
            Label {
                Text(verbatim: "\(model.totalNavigationAttentionCount)")
            } icon: {
                Image(systemName: "bell.fill")
            }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
        }
        .help(String(
            format: String(localized: "%lld items need attention"),
            Int64(model.totalNavigationAttentionCount)
        ))
        .accessibilityLabel(Text(String(
            format: String(localized: "%lld items need attention"),
            Int64(model.totalNavigationAttentionCount)
        )))
    }

    private func sessionRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: sessionIcon(conversation))
                .foregroundStyle(conversation.archived == true ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title).lineLimit(1)
                HStack(spacing: 5) {
                    AgentIdentityLabel(agentID: conversation.agentID, iconSize: 11)
                    if let relationship = relationshipLabel(conversation.relationship) {
                        Text(relationship)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if conversation.latestRunStatus == "waiting_permission" {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Needs Attention")
            } else if let status = conversation.latestRunStatus {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 7, height: 7)
                    .help(status.replacingOccurrences(of: "_", with: " ").capitalized)
            }
        }
        .contentShape(Rectangle())
        .opacity(conversation.archived == true ? 0.65 : 1)
    }

    private func sessionTreeRows(_ nodes: [SessionNavigationNode]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if node.children.isEmpty {
                sessionListRow(node.conversation)
            } else {
                DisclosureGroup(isExpanded: sessionExpansionBinding(node.id)) {
                    sessionTreeRows(node.children)
                } label: {
                    sessionListRow(node.conversation)
                }
            }
        })
    }

    private func sessionListRow(_ conversation: Conversation) -> some View {
        sessionRow(conversation)
            .tag(WorkspaceActivitySelection.conversation(conversation.id))
            .contextMenu { sessionCommands(conversation) }
    }

    private func sessionExpansionBinding(_ conversationID: String) -> Binding<Bool> {
        Binding(
            get: { expandedSessionIDSet.contains(conversationID) },
            set: { isExpanded in
                var ids = expandedSessionIDSet
                if isExpanded { ids.insert(conversationID) }
                else { ids.remove(conversationID) }
                persistExpandedSessionIDs(ids)
            }
        )
    }

    private var decodedExpandedSessionIDs: Set<String> {
        Set(storedExpandedSessionIDs.split(separator: "\n").map(String.init))
    }

    private func persistExpandedSessionIDs(_ ids: Set<String>) {
        expandedSessionIDSet = ids
        storedExpandedSessionIDs = ids.sorted().joined(separator: "\n")
    }

    private func revealSelectedConversation() {
        guard let selectedConversationID = model.selectedConversationID else { return }
        var ids = expandedSessionIDSet
        ids.formUnion(SessionNavigationProjection.ancestorIDs(
            of: selectedConversationID,
            in: model.conversations
        ))
        persistExpandedSessionIDs(ids)
    }

    @ViewBuilder
    private func sessionCommands(_ conversation: Conversation) -> some View {
        newSessionContextMenu
        Divider()
        Button("Rename…", systemImage: "pencil") { onRename(conversation) }
        if conversation.manualTitle != nil, conversation.agentTitle != nil {
            Button("Use Agent Title", systemImage: "textformat") {
                model.renameConversation(conversation, title: nil)
            }
        }
        Button(
            conversation.archived == true ? "Unarchive" : "Archive",
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
            onPromote(conversation)
        }
        if SessionLifecyclePolicy.canDelete(conversation) {
            Divider()
            Button("Delete Session", systemImage: "trash", role: .destructive) {
                onDelete(conversation)
            }
        }
    }

    private var sessionPreferences: SessionNavigationPreferences {
        SessionNavigationPreferences(
            showArchived: showArchivedSessions,
            agentID: AgentID(rawValue: sessionAgentFilter),
            sort: SessionNavigationSort(rawValue: sessionSort) ?? .activity
        )
    }

    private var sessionSections: [SessionNavigationSection] {
        SessionNavigationProjection.sections(
            model.conversations,
            preferences: sessionPreferences
        )
    }

    private func sessionIcon(_ conversation: Conversation) -> String {
        switch conversation.relationship {
        case "branch", "fork": "arrow.triangle.branch"
        case "subagent": "point.3.connected.trianglepath.dotted"
        case "team_member": "person.crop.circle"
        default: "bubble.left"
        }
    }

    private func relationshipLabel(_ relationship: String?) -> String? {
        switch relationship {
        case "branch": String(localized: "Branch")
        case "fork": String(localized: "Fork")
        case "subagent": String(localized: "Subagent")
        case "team_member": String(localized: "Team Member")
        default: nil
        }
    }

    private func teamRow(_ snapshot: TeamSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.team.title).lineLimit(1)
                Spacer()
                if snapshot.summary.needsAttention > 0 {
                    Label {
                        Text(verbatim: "\(snapshot.summary.needsAttention)")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    .help("Needs Attention")
                } else {
                    Circle()
                        .fill(statusColor(snapshot.team.status))
                        .frame(width: 7, height: 7)
                }
            }
            Text(snapshot.team.goal)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { model.navigationSearchQuery },
            set: { model.searchNavigation($0) }
        )
    }

    private var activitySelection: Binding<WorkspaceActivitySelection?> {
        Binding(
            get: {
                if let id = model.selectedConversationID { return .conversation(id) }
                if let id = model.selectedTeamID { return .team(id) }
                return nil
            },
            set: { selection in
                switch selection {
                case let .conversation(id):
                    guard id != model.selectedConversationID,
                          let conversation = model.conversations.first(where: { $0.id == id })
                    else { return }
                    model.selectConversation(conversation)
                case let .team(id):
                    guard id != model.selectedTeamID,
                          let team = model.teams.first(where: { $0.id == id })
                    else { return }
                    model.selectTeam(team)
                case nil:
                    model.clearActivitySelection()
                }
            }
        )
    }

    private func open(_ item: WorkspaceNavigationItem) {
        model.openNavigationItem(item)
        model.isNavigationSearchPresented = false
    }
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "running", "active", "starting": .green
    case "waiting_permission", "needs_attention", "queued", "paused": .orange
    case "failed", "cancelled", "timed_out": .red
    default: .secondary
    }
}
