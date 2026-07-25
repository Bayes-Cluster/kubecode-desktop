import SwiftUI
import AppKit
import UserNotifications
import KubecodeKit
import KubecodeMacRuntime

enum ServerProfileDraftPolicy {
    static func canAdd(
        name: String,
        mode: ServerConnectionMode,
        endpoint: String,
        bearerToken: String,
        sshHost: String
    ) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch mode {
        case .httpsAttached:
            let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: value),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false
            else { return false }
            return !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .sshManaged:
            return !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .localManaged:
            return false
        }
    }
}

struct ServerSettingsView: View {
    @Bindable var store: ServerProfileStore
    let connections: MacConnectionManager

    @State private var name = ""
    @State private var mode: ServerConnectionMode = .httpsAttached
    @State private var endpoint = "https://"
    @State private var basePath = ""
    @State private var sshHost = ""
    @State private var remoteExecutable = "kubecode-server"
    @State private var remoteWorkspaceRoot = "."
    @State private var bearerToken = ""
    @State private var errorMessage: String?

    var body: some View {
        TabView {
            serverProfiles
                .tabItem { Label("Servers", systemImage: "server.rack") }
            AgentDiagnosticsSettings(connections: connections)
                .tabItem { Label("Agents", systemImage: "cpu") }
            RuntimeDiagnosticsSettings(store: store, connections: connections)
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "curlybraces") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(minWidth: 660, minHeight: 540)
        .padding()
    }

    private var serverProfiles: some View {
        Form {
            Section("Server Profiles") {
                if store.profiles.isEmpty {
                    Text("No remote Servers configured.").foregroundStyle(.secondary)
                }
                ForEach(store.profiles) { profile in
                    HStack {
                        Image(systemName: profile.mode == .sshManaged ? "network" : "lock.shield")
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text(profile.mode == .sshManaged
                                ? profile.sshHost ?? ""
                                : profile.url?.absoluteString ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            do { try store.remove(profile) }
                            catch { errorMessage = error.localizedDescription }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Add Server") {
                TextField("Name", text: $name)
                Picker("Connection", selection: $mode) {
                    Text("HTTPS").tag(ServerConnectionMode.httpsAttached)
                    Text("SSH Config").tag(ServerConnectionMode.sshManaged)
                }
                .pickerStyle(.segmented)
                if mode == .httpsAttached {
                    TextField("HTTPS endpoint", text: $endpoint)
                    TextField("Base path (optional)", text: $basePath)
                    SecureField("Bearer token", text: $bearerToken)
                } else {
                    TextField("SSH host", text: $sshHost)
                    TextField("Remote Runtime executable", text: $remoteExecutable)
                    TextField("Remote workspace root", text: $remoteWorkspaceRoot)
                }
                Button("Add Server") { addProfile() }
                    .disabled(!ServerProfileDraftPolicy.canAdd(
                        name: name,
                        mode: mode,
                        endpoint: endpoint,
                        bearerToken: bearerToken,
                        sshHost: sshHost
                    ))
            }

            if let errorMessage {
                Section("Error") { Text(errorMessage).textSelection(.enabled).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private func addProfile() {
        do {
            let profile: ServerProfile
            if mode == .httpsAttached {
                let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https", url.host != nil else {
                    errorMessage = String(localized: "HTTPS endpoint is invalid.")
                    return
                }
                profile = ServerProfile(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    mode: mode,
                    url: url,
                    basePath: basePath.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try store.upsert(profile, bearerToken: bearerToken)
            } else {
                profile = ServerProfile(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    mode: mode,
                    sshHost: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
                    remoteExecutable: remoteExecutable.trimmingCharacters(in: .whitespacesAndNewlines),
                    remoteWorkspaceRoot: remoteWorkspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try store.upsert(profile)
            }
            name = ""
            bearerToken = ""
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

enum RuntimeDiagnosticsSelection: Hashable {
    case local
    case profile(UUID)

    var source: RuntimeDiagnosticSource {
        switch self {
        case .local: .local
        case let .profile(profileID): .profile(profileID)
        }
    }
}

struct RuntimeDiagnosticsSettings: View {
    @Bindable var store: ServerProfileStore
    let connections: MacConnectionManager

    @State private var selection = RuntimeDiagnosticsSelection.local
    @State private var logText = ""
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section("Runtime Diagnostics") {
                Picker("Log Source", selection: $selection) {
                    Text("Local Runtime").tag(RuntimeDiagnosticsSelection.local)
                    ForEach(store.profiles) { profile in
                        Text(profile.name).tag(RuntimeDiagnosticsSelection.profile(profile.id))
                    }
                }
                LabeledContent("Connection", value: connectionStatus)
            }

            Section {
                HStack {
                    Button(copied ? "Copied" : "Copy Logs", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        copyLogs()
                    }
                    .disabled(logText.isEmpty)
                    Button("Show in Finder", systemImage: "folder") { revealLog() }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                }

                if logText.isEmpty, errorMessage == nil {
                    ContentUnavailableView(
                        "No Runtime Logs",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Runtime and connection diagnostics will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: logText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 280)
                    .accessibilityLabel("Recent Runtime Logs")
                }
            } header: {
                Text("Recent Logs")
            }

            if let errorMessage {
                Section("Error") {
                    HStack(alignment: .top) {
                        Text(errorMessage).textSelection(.enabled).foregroundStyle(.red)
                        Spacer()
                        Button("Copy Error", systemImage: "doc.on.doc") {
                            copyToPasteboard(errorMessage)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: selection) {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: store.profiles.map(\.id)) { _, profileIDs in
            if case let .profile(profileID) = selection, !profileIDs.contains(profileID) {
                selection = .local
            }
        }
    }

    private var connectionStatus: String {
        switch selection {
        case .local:
            switch connections.localRuntime.state {
            case .stopped: String(localized: "Stopped")
            case .starting: String(localized: "Starting")
            case .ready: String(localized: "Connected")
            case .failed: String(localized: "Unavailable")
            }
        case let .profile(profileID):
            connections.sessions[profileID] == nil
                ? String(localized: "Disconnected")
                : String(localized: "Connected")
        }
    }

    private func refresh() {
        do {
            logText = try connections.diagnostics.recentText(for: selection.source)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyLogs() {
        copyToPasteboard(logText)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func revealLog() {
        do {
            try connections.diagnostics.ensureExists(selection.source)
            NSWorkspace.shared.activateFileViewerSelecting([
                connections.diagnostics.url(for: selection.source),
            ])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct AgentDiagnosticsSettings: View {
    let connections: MacConnectionManager
    @State private var agents: [AgentDescriptor] = []
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("CLI and adapter readiness is discovered by the Runtime.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Report", systemImage: "doc.on.doc") { copyReport() }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(isRefreshing)
                }
            }
            Section("Agent Diagnostics") {
                ForEach(agents) { agent in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(agent.id.displayName).font(.headline)
                            Spacer()
                            Text(agent.readiness ?? (agent.available ? "ready" : "unavailable"))
                                .foregroundStyle(agent.available ? .green : .red)
                        }
                        diagnosticRow("CLI", status: agent.cli?.status, detail: agent.cli?.detail ?? agent.error)
                        diagnosticRow("Adapter", status: agent.adapter?.status, detail: agent.adapter?.detail)
                        if let version = agent.version { Text("Version: \(version)").font(.caption) }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }
            if let errorMessage {
                Section("Error") { Text(errorMessage).textSelection(.enabled).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func diagnosticRow(_ label: String, status: String?, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 70, alignment: .leading)
            Text(status ?? "unknown").font(.caption.monospaced())
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let session = try await connections.connectLocal()
            agents = try await session.refreshAgents()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func copyReport() {
        let report = agents.map { agent in
            [
                "\(agent.id.rawValue): \(agent.readiness ?? "unknown")",
                "  version: \(agent.version ?? "unknown")",
                "  cli: \(agent.cli?.status ?? "unknown") \(agent.cli?.detail ?? "")",
                "  adapter: \(agent.adapter?.status ?? "unknown") \(agent.adapter?.detail ?? "")",
            ].joined(separator: "\n")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

private struct AppearanceSettings: View {
    @AppStorage("appearance.mode") private var mode = "system"
    @AppStorage("appearance.uiFont") private var uiFont = WorkspaceTypography.systemFontName
    @AppStorage("appearance.codeFont") private var codeFont = WorkspaceTypography.systemMonospacedFontName
    @AppStorage("appearance.terminalFont") private var terminalFont = WorkspaceTypography.systemMonospacedFontName
    @AppStorage("appearance.uiSize") private var uiSize = WorkspaceTypography.defaultPointSize

    private let uiFontFamilies = WorkspaceTypography.availableFontFamilies()
    private let monospacedFontFamilies = WorkspaceTypography.availableFontFamilies(monospacedOnly: true)

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color scheme", selection: $mode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Picker("UI font", selection: $uiFont) {
                    Text("System").tag(WorkspaceTypography.systemFontName)
                    ForEach(uiFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Picker("UI size", selection: $uiSize) {
                    ForEach(WorkspaceTypography.allowedPointSizes, id: \.self) { size in
                        Text(verbatim: "\(size) pt").tag(Double(size))
                    }
                }
                Picker("Code font", selection: $codeFont) {
                    Text("System Mono").tag(WorkspaceTypography.systemMonospacedFontName)
                    ForEach(monospacedFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Picker("Terminal font", selection: $terminalFont) {
                    Text("System Mono").tag(WorkspaceTypography.systemMonospacedFontName)
                    ForEach(monospacedFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .workspaceTypography(WorkspaceTypography(fontName: uiFont, pointSize: uiSize))
        .onAppear(perform: normalizeStoredTypography)
    }

    private func normalizeStoredTypography() {
        let typography = WorkspaceTypography(fontName: uiFont, pointSize: uiSize)
        uiFont = typography.displayFontName
        uiSize = typography.pointSize
        if codeFont != WorkspaceTypography.systemMonospacedFontName,
           !monospacedFontFamilies.contains(codeFont) {
            codeFont = WorkspaceTypography.systemMonospacedFontName
        }
        if terminalFont != WorkspaceTypography.systemMonospacedFontName,
           !monospacedFontFamilies.contains(terminalFont) {
            terminalFont = WorkspaceTypography.systemMonospacedFontName
        }
    }
}

private struct EditorSettings: View {
    @AppStorage("editor.autosave") private var autosave = false
    @AppStorage("editor.showHidden") private var showHidden = false
    @AppStorage("editor.showIgnored") private var showIgnored = false
    @AppStorage(SessionDraftStore.relaunchPersistencePreferenceKey)
    private var restoreSessionDrafts = false

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Auto-save after one second", isOn: $autosave)
                Toggle("Show hidden files", isOn: $showHidden)
                Toggle("Show ignored files", isOn: $showIgnored)
            }
            Section("Terminal") {
                Text("Terminal layouts restore panes and split ratios without saving terminal output.")
                    .foregroundStyle(.secondary)
            }
            Section("Session Drafts") {
                Toggle("Restore unfinished prompts after relaunch", isOn: Binding(
                    get: { restoreSessionDrafts },
                    set: { enabled in
                        restoreSessionDrafts = enabled
                        SessionDraftStore.setRelaunchPersistenceEnabled(enabled)
                    }
                ))
                Text("When enabled, unfinished Agent prompts are stored on this Mac for each window and Session.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @AppStorage(WorkspaceNotificationPreferences.modeKey) private var mode = "always"
    @AppStorage("notifications.errors") private var errors = true
    @AppStorage("notifications.attention") private var attention = true
    @AppStorage("notifications.completed") private var completed = true
    @AppStorage(WorkspaceNotificationPreferences.completionSoundKey) private var completionSound = "system"
    @AppStorage(WorkspaceNotificationPreferences.attentionSoundKey) private var attentionSound = "system"
    @AppStorage(WorkspaceNotificationPreferences.errorSoundKey) private var errorSound = "system"
    @State private var status = ""

    var body: some View {
        Form {
            Section("System Notifications") {
                Picker("Delivery", selection: $mode) {
                    Text("Always").tag("always")
                    Text("When Unfocused").tag("unfocused")
                    Text("Off").tag("off")
                }
                .pickerStyle(.segmented)
            }
            Section("Notification Categories") {
                categoryRow("Completed Runs", enabled: $completed, sound: $completionSound)
                categoryRow("Needs Attention", enabled: $attention, sound: $attentionSound)
                categoryRow("Errors", enabled: $errors, sound: $errorSound)
            }
            Section {
                HStack {
                    Button("Request Permission") { requestPermission() }
                    Button("Send Test Notification") { sendTest() }
                    Spacer()
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func requestPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                status = granted ? String(localized: "Allowed") : String(localized: "Not allowed")
            } catch { status = error.localizedDescription }
        }
    }

    private func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Kubecode"
        content.body = String(localized: "Notification settings are working.")
        if completionSound == "system" { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private func categoryRow(
        _ title: LocalizedStringKey,
        enabled: Binding<Bool>,
        sound: Binding<String>
    ) -> some View {
        LabeledContent {
            HStack(spacing: 12) {
                Toggle("Enabled", isOn: enabled)
                    .labelsHidden()
                Picker("Sound", selection: sound) {
                    Text("System Sound").tag("system")
                    Text("No Sound").tag("none")
                }
                .labelsHidden()
                .frame(width: 140)
            }
        } label: {
            Text(title)
        }
    }
}
