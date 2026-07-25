import SwiftUI
import UserNotifications
import KubecodeKit
import KubecodeMacRuntime

private struct WorkspaceModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var workspaceModel: AppModel? {
        get { self[WorkspaceModelKey.self] }
        set { self[WorkspaceModelKey.self] = newValue }
    }
}

@MainActor
protocol ApplicationConnectionOwnership: AnyObject {
    var hasManagedRuntimeActivity: Bool { get }
    func stopAll()
}

extension MacConnectionManager: ApplicationConnectionOwnership {}

struct WorkspaceKeyboardShortcut: Hashable {
    let key: Character
    let modifiers: EventModifiers

    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    static func == (lhs: WorkspaceKeyboardShortcut, rhs: WorkspaceKeyboardShortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifierMask == rhs.modifierMask
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifierMask)
    }

    private var modifierMask: UInt8 {
        var mask: UInt8 = 0
        if modifiers.contains(.command) { mask |= 1 << 0 }
        if modifiers.contains(.shift) { mask |= 1 << 1 }
        if modifiers.contains(.option) { mask |= 1 << 2 }
        if modifiers.contains(.control) { mask |= 1 << 3 }
        if modifiers.contains(.capsLock) { mask |= 1 << 4 }
        if modifiers.contains(.numericPad) { mask |= 1 << 5 }
        return mask
    }
}

enum WorkspaceKeyboardShortcuts {
    static let addProject = WorkspaceKeyboardShortcut(key: "o", modifiers: [.command, .shift])
    static let newSession = WorkspaceKeyboardShortcut(key: "n", modifiers: [.command])
    static let quickOpen = WorkspaceKeyboardShortcut(key: "p", modifiers: [.command])
    static let save = WorkspaceKeyboardShortcut(key: "s", modifiers: [.command])
    static let refresh = WorkspaceKeyboardShortcut(key: "r", modifiers: [.command, .shift])
    static let searchSessions = WorkspaceKeyboardShortcut(key: "k", modifiers: [.command])
    static let find = WorkspaceKeyboardShortcut(key: "f", modifiers: [.command])
    static let findAndReplace = WorkspaceKeyboardShortcut(key: "f", modifiers: [.command, .option])
    static let terminalPanel = WorkspaceKeyboardShortcut(key: "j", modifiers: [.command])
    static let inspector = WorkspaceKeyboardShortcut(key: "0", modifiers: [.command, .option])

    static let all: [WorkspaceKeyboardShortcut] = [
        addProject,
        newSession,
        quickOpen,
        save,
        refresh,
        searchSessions,
        find,
        findAndReplace,
        terminalPanel,
        inspector,
    ]
}

private struct WorkspaceWindow: View {
    @State private var model: AppModel
    @SceneStorage("workspace.persistence-id") private var persistenceID = UUID().uuidString
    @SceneStorage("workspace.inspector-presented") private var inspectorPresented = true
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.uiFont") private var uiFont = WorkspaceTypography.systemFontName
    @AppStorage("appearance.uiSize") private var uiSize = WorkspaceTypography.defaultPointSize

    init(connections: MacConnectionManager) {
        _model = State(initialValue: AppModel(
            connections: connections,
            notificationCoordinator: .shared
        ))
    }

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 1040, minHeight: 680)
            .background(WorkspaceWindowCloseBridge(model: model).frame(width: 0, height: 0))
            .focusedSceneValue(\.workspaceModel, model)
            .preferredColorScheme(preferredColorScheme)
            .workspaceTypography(WorkspaceTypography(fontName: uiFont, pointSize: uiSize))
            .task {
                model.isInspectorPresented = inspectorPresented
                model.configureWindowPersistence(id: persistenceID)
                await model.start()
            }
            .onChange(of: model.isInspectorPresented) { _, presented in
                inspectorPresented = presented
            }
            .onReceive(NotificationCenter.default.publisher(
                for: SessionDraftStore.persistencePreferenceDidChange
            )) { _ in
                model.handleDraftPersistencePreferenceChanged()
            }
            .onDisappear { model.disconnectWindow() }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceModel) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model?.presentProjectRegistration() }
                .keyboardShortcut(
                    WorkspaceKeyboardShortcuts.addProject.keyEquivalent,
                    modifiers: WorkspaceKeyboardShortcuts.addProject.modifiers
                )
                .disabled(model?.isReady != true)
            Button("New Session") { model?.isSessionSetupPresented = true }
                .keyboardShortcut(
                    WorkspaceKeyboardShortcuts.newSession.keyEquivalent,
                    modifiers: WorkspaceKeyboardShortcuts.newSession.modifiers
                )
                .disabled(model?.selectedProject == nil)
            Button("New Team", systemImage: "person.3") { model?.isTeamSetupPresented = true }
                .disabled(model?.canCreateTeam != true)
            Button("Quick Open") { model?.isQuickOpenPresented = true }
                .keyboardShortcut(
                    WorkspaceKeyboardShortcuts.quickOpen.keyEquivalent,
                    modifiers: WorkspaceKeyboardShortcuts.quickOpen.modifiers
                )
                .disabled(model?.canUseSelectedProjectFiles != true)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model?.saveDocument() }
                .keyboardShortcut(
                    WorkspaceKeyboardShortcuts.save.keyEquivalent,
                    modifiers: WorkspaceKeyboardShortcuts.save.modifiers
                )
                .disabled(model?.canSaveActiveDocument != true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find", systemImage: "magnifyingglass") { model?.requestFind() }
                .keyboardShortcut(
                    WorkspaceKeyboardShortcuts.find.keyEquivalent,
                    modifiers: WorkspaceKeyboardShortcuts.find.modifiers
                )
                .disabled(model?.activeDocument == nil)
            Button("Find and Replace", systemImage: "arrow.triangle.2.circlepath") {
                model?.requestFindAndReplace()
            }
            .keyboardShortcut(
                WorkspaceKeyboardShortcuts.findAndReplace.keyEquivalent,
                modifiers: WorkspaceKeyboardShortcuts.findAndReplace.modifiers
            )
            .disabled(model?.activeDocument == nil)
        }
        CommandMenu("Runtime") {
            Button("Refresh Workspace") {
                guard let model else { return }
                Task { await model.refresh() }
            }
            .keyboardShortcut(
                WorkspaceKeyboardShortcuts.refresh.keyEquivalent,
                modifiers: WorkspaceKeyboardShortcuts.refresh.modifiers
            )
            .disabled(model?.isReady != true)
            Button("Show Runtime Log") { model?.openRuntimeLog() }
        }
        CommandGroup(after: .sidebar) {
            Button("Search Sessions", systemImage: "magnifyingglass") {
                model?.isNavigationSearchPresented = true
            }
            .keyboardShortcut(
                WorkspaceKeyboardShortcuts.searchSessions.keyEquivalent,
                modifiers: WorkspaceKeyboardShortcuts.searchSessions.modifiers
            )
            .disabled(model?.selectedProject == nil)
            Button(terminalPanelCommandTitle, systemImage: "rectangle.bottomhalf.inset.filled") {
                model?.toggleTerminalPanel()
            }
            .keyboardShortcut(
                WorkspaceKeyboardShortcuts.terminalPanel.keyEquivalent,
                modifiers: WorkspaceKeyboardShortcuts.terminalPanel.modifiers
            )
            .disabled(model?.canToggleTerminalPanel != true)
        }
    }

    private var terminalPanelCommandTitle: LocalizedStringKey {
        model?.isTerminalPanelPresented == true ? "Hide Terminal Panel" : "Show Terminal Panel"
    }

}

@main
struct KubecodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var connections: MacConnectionManager

    init() {
        let connections = MacConnectionManager()
        _connections = State(initialValue: connections)
        appDelegate.connections = connections
    }

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceWindow(connections: connections)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            WorkspaceCommands()
        }

        Settings {
            ServerSettingsView(store: connections.profiles, connections: connections)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var connections: (any ApplicationConnectionOwnership)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidFinishRestoringWindows(_:)),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: notification.object
        )
    }

    @objc private func applicationDidFinishRestoringWindows(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        scheduleWorkspaceWindowRecovery(for: application)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        scheduleWorkspaceWindowRecovery(for: application)
    }

    private func scheduleWorkspaceWindowRecovery(for application: NSApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard Self.needsWorkspaceWindow(in: application.windows) else { return }
            if let newWindowItem = Self.newWindowMenuItem(in: application.mainMenu),
               let action = newWindowItem.action {
                _ = application.sendAction(action, to: newWindowItem.target, from: newWindowItem)
            } else if !application.sendAction(Selector(("newWindow:")), to: nil, from: nil) {
                NSLog("Kubecode could not reopen its workspace window after state restoration.")
            }
        }
    }

    static func needsWorkspaceWindow(in windows: [NSWindow]) -> Bool {
        !windows.contains { !($0 is NSPanel) && $0.styleMask.contains(.titled) }
    }

    static func newWindowMenuItem(in mainMenu: NSMenu?) -> NSMenuItem? {
        guard let fileMenu = mainMenu?.items.first(where: { $0.submenu?.items.contains(where: {
            $0.keyEquivalent.lowercased() == "n"
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
        }) == true })?.submenu else { return nil }
        return fileMenu.items.first {
            $0.keyEquivalent.lowercased() == "n"
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
                && $0.isEnabled
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard connections?.hasManagedRuntimeActivity == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Kubecode?")
        alert.informativeText = String(localized: "Active local Agent sessions and terminals will stop.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        connections?.stopAll()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
