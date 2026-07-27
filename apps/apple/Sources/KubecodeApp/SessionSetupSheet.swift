import SwiftUI
import KubecodeKit

struct SessionSetupSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var agentID: AgentID
    @State private var workspaceMode = "shared"
    @State private var importHistory = false
    @State private var providerSessionID: String?

    init(model: AppModel, initialAgentID: AgentID) {
        self.model = model
        let available = model.availableAgents.map(\.id)
        _agentID = State(initialValue: available.contains(initialAgentID)
            ? initialAgentID
            : available.first ?? .claudeCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Session").font(.title2.weight(.semibold))
            Form {
                Picker("Agent", selection: $agentID) {
                    ForEach(model.availableAgents) { agent in
                        AgentIdentityLabel(agentID: agent.id).tag(agent.id)
                    }
                }
                Picker("Workspace", selection: $workspaceMode) {
                    Text("Shared Project").tag("shared")
                    Text("Isolated Worktree").tag("worktree")
                }
                .disabled(importHistory)
                Toggle("Resume provider-native history", isOn: $importHistory)
            }
            .formStyle(.grouped)

            if importHistory {
                GroupBox("Provider Sessions") {
                    if model.isLoadingProviderSessions {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 90)
                    } else if model.providerSessions.isEmpty {
                        ContentUnavailableView("No provider sessions", systemImage: "clock.arrow.circlepath")
                            .frame(minHeight: 90)
                    } else {
                        List(model.providerSessions, selection: $providerSessionID) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title ?? session.sessionID).lineLimit(1)
                                Text(session.updatedAt ?? session.sessionID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(session.sessionID)
                        }
                        .frame(minHeight: 150)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(importHistory ? "Resume Session" : "Create Session") {
                    let provider = model.providerSessions.first { $0.sessionID == providerSessionID }
                    model.createSession(
                        agent: agentID,
                        workspaceMode: workspaceMode,
                        providerSession: importHistory ? provider : nil
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(importHistory && providerSessionID == nil)
            }
        }
        .padding(24)
        .frame(width: 560, height: importHistory ? 520 : 300)
        .task { await model.loadProviderSessions(agent: agentID) }
        .onChange(of: agentID) {
            providerSessionID = nil
            Task { await model.loadProviderSessions(agent: agentID) }
        }
        .onChange(of: model.availableAgents.map(\.id)) { _, available in
            guard !available.contains(agentID), let fallback = available.first else { return }
            agentID = fallback
        }
    }
}
