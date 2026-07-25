import SwiftUI
import KubecodeKit

struct ProjectBrowserSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var create = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Project").font(.headline)
                Spacer()
                if model.isLoadingProjectDirectory { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()

            List(model.projectDirectoryListing?.entries ?? []) { entry in
                Button {
                    path = entry.path
                    Task { await model.loadProjectDirectories(path: entry.path) }
                } label: {
                    Label(entry.name, systemImage: entry.hidden ? "folder.fill.badge.questionmark" : "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Divider()
            Form {
                TextField("Server path", text: $path)
                Toggle("Create a new directory", isOn: $create)
            }
            .formStyle(.grouped)
            .frame(height: 110)

            HStack {
                Button("Back") {
                    if let parent = model.projectDirectoryListing?.parent {
                        path = parent
                        Task { await model.loadProjectDirectories(path: parent) }
                    }
                }
                .disabled(model.projectDirectoryListing?.parent == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(create ? "Create Project" : "Import Project") {
                    model.registerServerProject(path: path, create: create)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
        .task {
            await model.loadProjectDirectories()
            path = model.projectDirectoryListing?.path ?? ""
        }
    }
}
