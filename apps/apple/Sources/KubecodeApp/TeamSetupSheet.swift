import SwiftUI
import KubecodeKit

struct TeamSetupSheet: View {
    @Bindable var model: AppModel
    let conversation: Conversation?
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TeamSnapshot?
    @State private var title: String
    @State private var leaderName: String
    @State private var goal: String
    @State private var acceptance: String
    @State private var agentID: AgentID
    @State private var workspace: String
    @State private var mode: String
    @State private var allowedAgentIDs: Set<AgentID>
    @State private var maxTeammates: Int
    @State private var maxParallelRuns: Int
    @State private var maxReviewRounds: Int
    @State private var leaderState: AgentSessionState?
    @State private var isPreparingDraft = false
    @State private var isLoadingLeaderState = false
    @State private var isStarting = false
    @State private var pendingControlID: String?
    @State private var setupError: String?

    init(
        model: AppModel,
        conversation: Conversation? = nil,
        draft: TeamSnapshot? = nil,
        initialLeaderState: AgentSessionState? = nil
    ) {
        self.model = model
        self.conversation = conversation
        let leader = Self.leaderConversation(in: draft) ?? conversation
        let leaderMember = draft?.members.first(where: { $0.id == draft?.team.leaderMemberID })
        _draft = State(initialValue: draft)
        _title = State(initialValue: draft?.team.title ?? conversation?.title ?? "")
        _leaderName = State(initialValue: leaderMember?.name ?? "Leader")
        _goal = State(initialValue: draft?.team.goal ?? "")
        _acceptance = State(initialValue: (draft?.team.acceptanceCriteria ?? []).joined(separator: "\n"))
        _agentID = State(initialValue: leader?.agentID ?? .claudeCode)
        _workspace = State(initialValue: draft?.team.workspace ?? conversation?.executionMode ?? "shared")
        _mode = State(initialValue: draft?.team.requestedMode ?? "standard")
        _allowedAgentIDs = State(initialValue: Set(draft?.team.allowedAgentIDs ?? []))
        _maxTeammates = State(initialValue: draft?.team.maxTeammates ?? 3)
        _maxParallelRuns = State(initialValue: draft?.team.maxParallelRuns ?? 2)
        _maxReviewRounds = State(initialValue: draft?.team.maxReviewRounds ?? 3)
        _leaderState = State(initialValue: initialLeaderState)
    }

    private var acceptanceCriteria: [String] {
        acceptance
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var orderedAllowedAgentIDs: [AgentID] {
        model.availableAgents.map(\.id).filter(allowedAgentIDs.contains)
    }

    private var leaderConversation: Conversation? {
        Self.leaderConversation(in: draft) ?? conversation
    }

    private var leaderControls: NativeSessionControls {
        NativeSessionControlProjection.controls(from: leaderState)
    }

    private var canCreateDraft: Bool {
        !leaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.availableAgents.contains { $0.id == agentID }
    }

    private var canStart: Bool {
        leaderState != nil && TeamSetupPolicy.canStart(
            goal: goal,
            acceptanceCriteria: acceptanceCriteria,
            allowedAgentIDs: allowedAgentIDs
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft == nil {
                    draftIdentitySections
                } else {
                    configurationSections
                }
                if let setupError {
                    Section {
                        Label {
                            Text(verbatim: setupError).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        if draft != nil, leaderState == nil, !isLoadingLeaderState {
                            Button("Retry Leader Configuration") {
                                Task { await loadLeaderState() }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmationButton
                }
            }
        }
        .frame(width: 580, height: 720)
        .onAppear {
            if draft == nil, conversation == nil, let first = model.availableAgents.first {
                agentID = first.id
            }
            if allowedAgentIDs.isEmpty {
                allowedAgentIDs = Set(model.availableAgents.map(\.id))
            }
        }
        .onChange(of: model.availableAgents.map(\.id)) { _, available in
            let availableSet = Set(available)
            allowedAgentIDs.formIntersection(availableSet)
            if allowedAgentIDs.isEmpty { allowedAgentIDs = availableSet }
            if !availableSet.contains(agentID), let first = available.first { agentID = first }
        }
        .onChange(of: maxTeammates) { _, limit in
            maxParallelRuns = TeamSetupPolicy.parallelRuns(maxParallelRuns, limitedBy: limit)
        }
        .task(id: draft?.id) {
            if draft != nil, leaderState == nil { await loadLeaderState() }
        }
    }

    @ViewBuilder
    private var draftIdentitySections: some View {
        Section("Team") {
            TextField("Title", text: $title)
            TextField("Leader name", text: $leaderName)
            if conversation == nil {
                Picker("Leader Agent", selection: $agentID) {
                    ForEach(model.availableAgents) { agent in
                        Text(verbatim: agent.id.displayName).tag(agent.id)
                    }
                }
            } else if let conversation {
                LabeledContent("Leader Agent") {
                    Text(verbatim: conversation.agentID.displayName)
                }
            }
        }

        Section("Workspace") {
            Picker("Workspace", selection: $workspace) {
                Text("Shared").tag("shared")
                Text("Worktree").tag("worktree")
            }
            .pickerStyle(.segmented)
            Text("Kubecode creates the draft first, then loads the Leader's provider-native options.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var configurationSections: some View {
        if let draft, let leaderConversation {
            Section("Team") {
                LabeledContent("Title") { Text(verbatim: draft.team.title) }
                LabeledContent("Leader Agent") {
                    Text(verbatim: leaderConversation.agentID.displayName)
                }
                LabeledContent("Workspace") {
                    Text(draft.team.workspace == "worktree" ? "Worktree" : "Shared")
                }
            }
        }

        Section("Objective") {
            TextField("Goal", text: $goal, axis: .vertical).lineLimit(2...5)
            TextField("Acceptance criteria (one per line)", text: $acceptance, axis: .vertical)
                .lineLimit(2...6)
        }

        Section("Execution") {
            Picker("Permission mode", selection: $mode) {
                Text("Standard").tag("standard")
                Text("YOLO").tag("yolo")
            }
            .pickerStyle(.segmented)
            if mode == "yolo", let leaderConversation {
                Label(
                    "YOLO uses each Agent's maximum native permission profile.",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                LabeledContent("Leader native permission") {
                    Text(verbatim: TeamSetupPolicy.nativePermissionLabel(for: leaderConversation.agentID))
                }
            }
        }

        leaderConfigurationSection

        Section("Agent Budget") {
            ForEach(model.availableAgents) { agent in
                Toggle(isOn: allowedAgentBinding(for: agent.id)) {
                    Text(verbatim: agent.id.displayName)
                }
                .toggleStyle(.checkbox)
            }
            Stepper(value: $maxTeammates, in: 1...8) {
                LabeledContent("Maximum teammates", value: String(maxTeammates))
            }
            Stepper(value: $maxParallelRuns, in: 1...maxTeammates) {
                LabeledContent("Maximum parallel runs", value: String(maxParallelRuns))
            }
            if mode == "yolo" {
                Stepper(value: $maxReviewRounds, in: 1...10) {
                    LabeledContent("Maximum review rounds", value: String(maxReviewRounds))
                }
            }
        }
    }

    @ViewBuilder
    private var leaderConfigurationSection: some View {
        Section("Leader Configuration") {
            if isLoadingLeaderState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading Leader configuration…")
                        .foregroundStyle(.secondary)
                }
            } else if let leaderState, let leaderConversation {
                let modeLocked = TeamSetupPolicy.permissionModeLocked(
                    teamMode: mode,
                    leaderAgentID: leaderConversation.agentID
                )
                if modeLocked {
                    LabeledContent("Session Mode") {
                        Text("Controlled by YOLO permission mode")
                            .foregroundStyle(.secondary)
                    }
                } else if let nativeMode = leaderControls.mode {
                    nativeSelect(nativeMode, modeAccess: leaderState.modeAccess)
                }
                ForEach(leaderControls.configs) { config in
                    if config.isBoolean {
                        Toggle(config.name, isOn: booleanBinding(for: config))
                            .disabled(pendingControlID != nil)
                    } else {
                        nativeSelect(config)
                    }
                }
                if leaderControls.mode == nil, leaderControls.configs.isEmpty, !modeLocked {
                    Text("This Agent does not advertise provider-native Leader options.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nativeSelect(
        _ control: NativeSessionControl,
        modeAccess: SessionModeAccess? = nil
    ) -> some View {
        Picker(control.name, selection: selectBinding(for: control)) {
            ForEach(control.choices) { choice in
                Text(verbatim: choice.name).tag(choice.id)
            }
        }
        .disabled(pendingControlID != nil || modeAccess?.canChange == false)
        .help(modeAccess?.reason ?? control.name)
    }

    @ViewBuilder
    private var confirmationButton: some View {
        if draft == nil {
            Button("Continue") {
                Task { await prepareDraft() }
            }
            .disabled(!canCreateDraft || isPreparingDraft)
        } else if let draft {
            Button(TeamSetupPolicy.confirmationTitle(for: draft.team.status)) {
                Task { await startTeam() }
            }
            .disabled(!canStart || isStarting || pendingControlID != nil)
        }
    }

    private var navigationTitle: String {
        if let draft { return TeamSetupPolicy.navigationTitle(for: draft.team.status) }
        return conversation == nil
            ? String(localized: "New Team")
            : String(localized: "Promote to Team")
    }

    private func prepareDraft() async {
        guard !isPreparingDraft else { return }
        isPreparingDraft = true
        setupError = nil
        defer { isPreparingDraft = false }
        let created = if let conversation {
            await model.promoteConversationToTeamDraft(
                conversation: conversation,
                leaderName: leaderName.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                workspace: workspace
            )
        } else {
            await model.createTeamDraft(
                agentID: agentID,
                leaderName: leaderName.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                workspace: workspace
            )
        }
        guard let created else {
            setupError = model.errorMessage ?? String(localized: "Could not create the Team draft.")
            return
        }
        draft = created
    }

    private func loadLeaderState() async {
        guard let leaderConversation, !isLoadingLeaderState else { return }
        isLoadingLeaderState = true
        setupError = nil
        defer { isLoadingLeaderState = false }
        guard let loaded = await model.loadSessionStateForSetup(conversationID: leaderConversation.id) else {
            setupError = model.errorMessage ?? String(localized: "Could not load Leader configuration.")
            return
        }
        leaderState = loaded
    }

    private func startTeam() async {
        guard let draft, !isStarting else { return }
        isStarting = true
        setupError = nil
        defer { isStarting = false }
        let started = await model.startTeamDraft(
            draft,
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            acceptanceCriteria: acceptanceCriteria,
            mode: mode,
            allowedAgentIDs: orderedAllowedAgentIDs,
            maxTeammates: maxTeammates,
            maxParallelRuns: maxParallelRuns,
            maxReviewRounds: maxReviewRounds
        )
        guard started != nil else {
            setupError = model.errorMessage ?? String(localized: "Could not start the Team.")
            return
        }
        dismiss()
    }

    private func update(_ control: NativeSessionControl, value: JSONValue) {
        guard let leaderConversation, pendingControlID == nil else { return }
        pendingControlID = control.id
        setupError = nil
        Task {
            defer { pendingControlID = nil }
            guard let updated = await model.updateSessionControl(
                conversationID: leaderConversation.id,
                control: control,
                value: value
            ) else {
                setupError = model.errorMessage ?? String(localized: "Could not update Leader configuration.")
                return
            }
            leaderState = updated
        }
    }

    private func selectBinding(for control: NativeSessionControl) -> Binding<String> {
        Binding(
            get: { control.currentChoiceID ?? "" },
            set: { selected in
                guard let choice = control.choices.first(where: { $0.id == selected }) else { return }
                update(control, value: choice.value)
            }
        )
    }

    private func booleanBinding(for control: NativeSessionControl) -> Binding<Bool> {
        Binding(
            get: { control.currentBoolValue ?? false },
            set: { update(control, value: .bool($0)) }
        )
    }

    private func allowedAgentBinding(for agentID: AgentID) -> Binding<Bool> {
        Binding(
            get: { allowedAgentIDs.contains(agentID) },
            set: { selected in
                if selected { allowedAgentIDs.insert(agentID) }
                else { allowedAgentIDs.remove(agentID) }
            }
        )
    }

    private static func leaderConversation(in draft: TeamSnapshot?) -> Conversation? {
        guard let draft else { return nil }
        if let leader = draft.leaderConversation { return leader }
        if let leaderMemberID = draft.team.leaderMemberID,
           let leaderMember = draft.members.first(where: { $0.id == leaderMemberID }) {
            return draft.conversations?.first(where: { $0.id == leaderMember.conversationID })
        }
        return draft.conversations?.first(where: { $0.teamRole == "leader" })
    }
}
