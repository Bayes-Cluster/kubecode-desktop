import SwiftUI
import KubecodeKit

enum QuickOpenPresentationMetrics {
    static let actionBarHeight: CGFloat = 52
    static let actionSpacing: CGFloat = 8
}

struct QuickOpenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let onSelect: ((FileEntry) -> Void)?
    @State private var query = ""
    @State private var selectedEntryID: String?
    @AppStorage("editor.showHidden") private var showHidden = false
    @AppStorage("editor.showIgnored") private var showIgnored = false
    @AppStorage("editor.showGenerated") private var showGenerated = false

    init(
        model: AppModel,
        onSelect: ((FileEntry) -> Void)? = nil,
        initialQuery: String = ""
    ) {
        self.model = model
        self.onSelect = onSelect
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Quick Open",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Search by file name or relative path.")
                    )
                } else if model.isSearchingQuickOpen && model.quickOpenResults.isEmpty {
                    ProgressView("Searching Project files…")
                } else if model.quickOpenResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(selection: $selectedEntryID) {
                        ForEach(model.quickOpenResults) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .tag(entry.id)
                            .accessibilityLabel(Text(verbatim: "\(entry.name), \(entry.path)"))
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: QuickOpenPresentationMetrics.actionSpacing) {
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            close()
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Open") { openSelected() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(selectedEntry == nil)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: QuickOpenPresentationMetrics.actionBarHeight)
                }
                .background(.bar)
            }
            .navigationTitle("Quick Open")
            .searchable(text: $query, placement: .toolbar, prompt: "Search Project files")
            .onChange(of: query) { beginSearch() }
            .onChange(of: showHidden) { beginSearch() }
            .onChange(of: showIgnored) { beginSearch() }
            .onChange(of: showGenerated) { beginSearch() }
            .onChange(of: model.quickOpenResults) {
                selectedEntryID = NativeListSelection.reconciled(
                    current: selectedEntryID,
                    identifiers: model.quickOpenResults.map(\.id)
                )
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 520)
        .onExitCommand(perform: close)
        .background {
#if os(macOS)
            NativeListCommandMonitor(
                onMove: moveSelection,
                onOpen: openSelected,
                onEscape: close
            )
                .frame(width: 0, height: 0)
#endif
        }
        .onAppear {
            selectedEntryID = NativeListSelection.reconciled(
                current: selectedEntryID,
                identifiers: model.quickOpenResults.map(\.id)
            )
        }
        .onDisappear { model.cancelQuickOpenSearch() }
    }

    private var selectedEntry: FileEntry? {
        guard let selectedEntryID else { return nil }
        return model.quickOpenResults.first { $0.id == selectedEntryID }
    }

    @discardableResult
    private func openSelected() -> Bool {
        guard let entry = selectedEntry else { return false }
        if let onSelect {
            onSelect(entry)
            dismiss()
        } else {
            model.openQuickOpenResult(entry)
        }
        return true
    }

    @discardableResult
    private func moveSelection(_ offset: Int) -> Bool {
        guard !model.quickOpenResults.isEmpty else { return false }
        selectedEntryID = NativeListSelection.moved(
            current: selectedEntryID,
            offset: offset,
            identifiers: model.quickOpenResults.map(\.id)
        )
        return true
    }

    private func close() {
        model.cancelQuickOpenSearch()
        if onSelect == nil {
            model.isQuickOpenPresented = false
        }
        dismiss()
    }

    private func beginSearch() {
        selectedEntryID = nil
        model.searchQuickOpen(
            query,
            includeHidden: showHidden,
            includeIgnored: showIgnored,
            includeGenerated: showGenerated
        )
    }
}
