import SwiftUI
import KubecodeKit

struct WorkspaceMigrationSheet: View {
    @Bindable var model: AppModel
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var resolutions: [String: WorkspaceMigrationStrategy] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disable Workspaces").font(.title2.weight(.semibold))
            Text("Resolve each isolated Session before returning the Project to shared mode.")
                .foregroundStyle(.secondary)

            if let preview = model.workspaceMigrationPreview {
                if !preview.activeConversationIDs.isEmpty {
                    Label("Stop active Agent runs before continuing.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                List(preview.worktrees) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            if item.dirty { Text("Uncommitted changes").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Picker("Resolution", selection: resolutionBinding(item.id)) {
                            Text("Merge").tag(WorkspaceMigrationStrategy.merge)
                            Text("Export Patch").tag(WorkspaceMigrationStrategy.exportPatch)
                            Text("Discard").tag(WorkspaceMigrationStrategy.discard)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Disable Workspaces") {
                    let values = resolutions.map {
                        WorkspaceMigrationResolution(conversationID: $0.key, strategy: $0.value)
                    }
                    model.migrateWorkspaces(projectID: project.id, resolutions: values)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 620, height: 460)
        .task {
            await model.loadWorkspaceMigration(projectID: project.id)
            for item in model.workspaceMigrationPreview?.worktrees ?? [] {
                resolutions[item.id] = item.dirty ? .exportPatch : .discard
            }
        }
    }

    private var canSubmit: Bool {
        guard let preview = model.workspaceMigrationPreview else { return false }
        return preview.activeConversationIDs.isEmpty && resolutions.count == preview.worktrees.count
    }

    private func resolutionBinding(_ id: String) -> Binding<WorkspaceMigrationStrategy> {
        Binding(get: { resolutions[id] ?? .exportPatch }, set: { resolutions[id] = $0 })
    }
}
