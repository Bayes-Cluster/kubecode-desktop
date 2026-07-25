import SwiftUI
import KubecodeKit

enum TeamActionPolicy {
    static func canAssign(_ task: TeamTask) -> Bool {
        task.status == "pending" && task.assigneeMemberID == nil
    }

    static func canRetry(_ task: TeamTask) -> Bool {
        ["failed", "cancelled"].contains(task.status)
    }

    static func canCancel(_ task: TeamTask) -> Bool {
        !["accepted", "cancelled"].contains(task.status)
    }

    static func canRemove(_ member: TeamMember) -> Bool {
        member.role == "teammate" && !["removed", "removing"].contains(member.status)
    }

    static func assignmentCandidates(_ members: [TeamMember]) -> [TeamMember] {
        members.filter(canRemove)
    }

    static func canPause(status: String) -> Bool {
        ["active", "verifying", "needs_attention"].contains(status)
    }

    static func canResume(status: String) -> Bool {
        status == "paused"
    }

    static func canReconfigure(status: String) -> Bool {
        status == "needs_attention"
    }

    static func canComplete(status: String, counters: TeamCounters) -> Bool {
        ["active", "verifying", "needs_attention", "paused"].contains(status)
            && counters.running == 0
            && counters.needsAttention == 0
    }

    static func permissionOwner(
        _ permission: TeamPermissionRequest,
        members: [TeamMember]
    ) -> TeamMember? {
        members.first { $0.id == permission.memberID }
    }

    static func attentionOwner(
        _ attention: TeamAttention,
        members: [TeamMember]
    ) -> TeamMember? {
        guard let memberID = attention.memberID else { return nil }
        return members.first { $0.id == memberID }
    }
}

enum TeamConversationProjection {
    /// Replaces the conversations owned by one Team while preserving the
    /// Navigator order of every other Project conversation.
    static func reconcile(
        teamID: String,
        latest: [Conversation],
        existing: [Conversation]
    ) -> [Conversation] {
        var uniqueLatest: [Conversation] = []
        var latestIDs = Set<String>()
        for conversation in latest where latestIDs.insert(conversation.id).inserted {
            uniqueLatest.append(conversation)
        }

        var result: [Conversation] = []
        var inserted = false
        for conversation in existing {
            guard conversation.teamID == teamID else {
                result.append(conversation)
                continue
            }
            if !inserted {
                result.append(contentsOf: uniqueLatest)
                inserted = true
            }
        }
        if !inserted {
            result.append(contentsOf: uniqueLatest)
        }
        return result
    }
}

enum TeamSetupPolicy {
    static func navigationTitle(for status: String) -> String {
        status == "needs_attention"
            ? String(localized: "Reconfigure Team")
            : String(localized: "Configure Team")
    }

    static func confirmationTitle(for status: String) -> String {
        status == "needs_attention"
            ? String(localized: "Restart Team")
            : String(localized: "Start Team")
    }

    static func canStart(
        goal: String,
        acceptanceCriteria: [String],
        allowedAgentIDs: Set<AgentID>
    ) -> Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acceptanceCriteria.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !allowedAgentIDs.isEmpty
    }

    static func parallelRuns(_ value: Int, limitedBy maxTeammates: Int) -> Int {
        min(max(1, value), max(1, maxTeammates))
    }

    static func nativePermissionLabel(for agentID: AgentID) -> String {
        switch agentID {
        case .claudeCode: String(localized: "Claude Code · bypassPermissions")
        case .codex: String(localized: "Codex · Agent (full access)")
        case .opencode: String(localized: "OpenCode · allow")
        }
    }

    static func permissionModeLocked(teamMode: String, leaderAgentID: AgentID) -> Bool {
        teamMode == "yolo" && leaderAgentID != .opencode
    }
}

struct TeamTaskDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: TeamSnapshot
    let task: TeamTask
    let onAssign: (TeamMember) -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onRemoveMember: (TeamMember) -> Void
    let onOpenMember: (TeamMember) -> Void

    private var assignee: TeamMember? {
        snapshot.members.first { $0.id == task.assigneeMemberID }
    }

    private var attempts: [TeamTaskAttempt] {
        (snapshot.taskAttempts ?? []).filter { $0.taskID == task.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    LabeledContent("Status", value: task.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    LabeledContent("Assignee", value: assignee?.name ?? String(localized: "Unassigned"))
                    if !task.description.isEmpty {
                        Text(task.description).textSelection(.enabled)
                    }
                    if let dependencies = task.dependencies, !dependencies.isEmpty {
                        LabeledContent("Dependencies", value: dependencies.joined(separator: ", "))
                    }
                    if let ownedPaths = task.ownedPaths, !ownedPaths.isEmpty {
                        LabeledContent("Owned Paths", value: ownedPaths.joined(separator: ", "))
                    }
                }

                if let plan = task.plan {
                    Section("Plan") { Text(plan).textSelection(.enabled) }
                }
                if let result = task.result {
                    Section("Result") { Text(result).textSelection(.enabled) }
                }
                if let verification = task.verification {
                    Section("Verification") { Text(verification).textSelection(.enabled) }
                }
                if !attempts.isEmpty {
                    Section("Attempts") {
                        ForEach(attempts) { attempt in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attempt.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                if let error = attempt.error {
                                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                Section("Actions") {
                    if let assignee {
                        Button("Open Member Session", systemImage: "arrow.right.circle") {
                            onOpenMember(assignee)
                            dismiss()
                        }
                    }
                    if TeamActionPolicy.canAssign(task) {
                        Menu("Assign to", systemImage: "person.badge.plus") {
                            ForEach(TeamActionPolicy.assignmentCandidates(snapshot.members)) { member in
                                Button(member.name) {
                                    onAssign(member)
                                    dismiss()
                                }
                            }
                        }
                    }
                    if TeamActionPolicy.canRetry(task) {
                        Button("Retry Task", systemImage: "arrow.clockwise") {
                            onRetry()
                            dismiss()
                        }
                    }
                    if let assignee, TeamActionPolicy.canRemove(assignee) {
                        Button("Remove Member…", systemImage: "person.badge.minus", role: .destructive) {
                            onRemoveMember(assignee)
                            dismiss()
                        }
                    }
                    if TeamActionPolicy.canCancel(task) {
                        Button("Cancel Task…", systemImage: "xmark", role: .destructive) {
                            onCancel()
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(task.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 460, idealHeight: 620)
    }
}

struct TeamSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: TeamSnapshot
    let onSave: (String, Int) -> Void
    @State private var memberManagementPolicy: String
    @State private var maxParallelRuns: Int

    init(snapshot: TeamSnapshot, onSave: @escaping (String, Int) -> Void) {
        self.snapshot = snapshot
        self.onSave = onSave
        _memberManagementPolicy = State(initialValue: snapshot.team.memberManagementPolicy ?? "ask")
        _maxParallelRuns = State(initialValue: snapshot.team.maxParallelRuns ?? 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Member Management") {
                    Picker("New teammate proposals", selection: $memberManagementPolicy) {
                        Text("Ask for Approval").tag("ask")
                        Text("Approve Automatically").tag("auto")
                    }
                    .pickerStyle(.radioGroup)
                }
                Section("Concurrency") {
                    Stepper(
                        "Maximum parallel runs: \(maxParallelRuns)",
                        value: $maxParallelRuns,
                        in: 1...max(1, snapshot.team.maxTeammates ?? 8)
                    )
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Team Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(memberManagementPolicy, maxParallelRuns)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 480, height: 340)
    }
}
