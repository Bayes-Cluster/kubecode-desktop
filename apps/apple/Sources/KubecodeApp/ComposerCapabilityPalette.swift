import Foundation
import SwiftUI

enum ComposerCapabilityProjection {
    static func commands(
        provider: [NativeCommand],
        includeClaudeSideQuestion: Bool
    ) -> [NativeCommand] {
        var names = Set<String>()
        var projected = provider.filter { command in
            names.insert(command.name.lowercased()).inserted
        }
        if includeClaudeSideQuestion, names.insert("btw").inserted {
            projected.append(NativeCommand(
                name: "btw",
                description: String(localized: "Ask Claude a side question without interrupting its current turn")
            ))
        }
        return projected
    }

    static func filtered(_ commands: [NativeCommand], query: String) -> [NativeCommand] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }
        return commands.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    static func includesFileReference(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return String(localized: "Reference File").localizedCaseInsensitiveContains(query)
            || String(localized: "Choose a Project file to reference in your message.")
                .localizedCaseInsensitiveContains(query)
    }

    static func inserting(_ token: String, into draft: String) -> String {
        let base = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "\(token) " : "\(base) \(token) "
    }
}

enum ComposerCapabilitySelection {
    static let referenceFileID = "reference-file"

    static func commandID(_ command: NativeCommand) -> String { "command:\(command.id)" }

    static func identifiers(
        commands: [NativeCommand],
        includeFileReference: Bool = true
    ) -> [String] {
        (includeFileReference ? [referenceFileID] : []) + commands.map(commandID)
    }

    static func command(selectedID: String?, commands: [NativeCommand]) -> NativeCommand? {
        commands.first { commandID($0) == selectedID }
    }
}

struct ComposerCapabilityPalette: View {
    let commands: [NativeCommand]
    let onChooseCommand: (NativeCommand) -> Void
    let onChooseFile: () -> Void
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var selectedID: String?

    init(
        commands: [NativeCommand],
        onChooseCommand: @escaping (NativeCommand) -> Void,
        onChooseFile: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.commands = commands
        self.onChooseCommand = onChooseCommand
        self.onChooseFile = onChooseFile
        self.onDismiss = onDismiss
    }

    private var filteredCommands: [NativeCommand] {
        ComposerCapabilityProjection.filtered(commands, query: query)
    }

    private var includesFileReference: Bool {
        ComposerCapabilityProjection.includesFileReference(query: query)
    }

    private var selectionIdentifiers: [String] {
        ComposerCapabilitySelection.identifiers(
            commands: filteredCommands,
            includeFileReference: includesFileReference
        )
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedID) {
                if includesFileReference {
                    Button {
                        selectedID = ComposerCapabilitySelection.referenceFileID
                        onChooseFile()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reference File")
                                Text("Choose a Project file to reference in your message.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.badge.plus")
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(ComposerCapabilitySelection.referenceFileID)
                }

                if filteredCommands.isEmpty {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            "No Agent Commands",
                            systemImage: "terminal",
                            description: Text("This Agent has not exposed any skills or commands yet.")
                        )
                    }
                } else {
                    Section("Agent Commands") {
                        ForEach(filteredCommands) { command in
                            Button {
                                selectedID = ComposerCapabilitySelection.commandID(command)
                                onChooseCommand(command)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: "/\(command.name)")
                                        if !command.description.isEmpty {
                                            Text(command.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: "terminal")
                                }
                            }
                            .buttonStyle(.plain)
                            .tag(ComposerCapabilitySelection.commandID(command))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Add Context")
            .searchable(text: $query, prompt: "Search Skills and Commands")
            .onChange(of: selectionIdentifiers) { reconcileSelection() }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 300, idealHeight: 400)
        .background {
#if os(macOS)
            NativeListCommandMonitor(
                onMove: moveSelection,
                onOpen: chooseSelected,
                onEscape: onDismiss
            )
            .frame(width: 0, height: 0)
#endif
        }
        .onAppear(perform: reconcileSelection)
    }

    private func reconcileSelection() {
        selectedID = NativeListSelection.reconciled(
            current: selectedID,
            identifiers: selectionIdentifiers
        )
    }

    @discardableResult
    private func moveSelection(_ offset: Int) -> Bool {
        guard !selectionIdentifiers.isEmpty else { return false }
        selectedID = NativeListSelection.moved(
            current: selectedID,
            offset: offset,
            identifiers: selectionIdentifiers
        )
        return true
    }

    @discardableResult
    private func chooseSelected() -> Bool {
        guard let selectedID else { return false }
        if selectedID == ComposerCapabilitySelection.referenceFileID {
            onChooseFile()
            return true
        }
        guard let command = ComposerCapabilitySelection.command(
            selectedID: selectedID,
            commands: filteredCommands
        ) else { return false }
        onChooseCommand(command)
        return true
    }
}
