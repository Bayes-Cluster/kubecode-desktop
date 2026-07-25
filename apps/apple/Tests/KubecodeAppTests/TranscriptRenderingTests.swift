import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
import Vision
#endif
@testable import KubecodeApp
import KubecodeKit
import KubecodeMacRuntime
import KubecodeUI

@MainActor
private final class ApplicationConnectionOwnershipSpy: ApplicationConnectionOwnership {
    var hasManagedRuntimeActivity = false
    private(set) var stopCount = 0

    func stopAll() {
        stopCount += 1
    }
}

@Suite(.serialized)
@MainActor
struct TranscriptRenderingTests {
    @Test func inspector_defaults_to_a_compact_workbench_column() {
        #expect(WorkbenchPresentationMetrics.inspectorMinimumWidth == 220)
        #expect(WorkbenchPresentationMetrics.inspectorIdealWidth == 260)
        #expect(WorkbenchPresentationMetrics.inspectorMaximumWidth == 360)
        #expect(WorkbenchPresentationMetrics.inspectorIdealWidth < 290)
    }

    @Test func server_switcher_keeps_a_compact_native_footer() {
        #expect(WorkspaceNavigationSidebarMetrics.serverSwitcherHeight == 30)
        #expect(WorkspaceNavigationSidebarMetrics.serverSwitcherWidth == 140)
    }

    @Test func navigator_toolbar_controls_share_one_native_hit_frame() {
        #expect(WorkspaceNavigationSidebarMetrics.columnMinimumWidth == 210)
        #expect(WorkspaceNavigationSidebarMetrics.columnIdealWidth == 250)
        #expect(WorkspaceNavigationSidebarMetrics.columnMaximumWidth == 310)
        #expect(
            WorkspaceNavigationSidebarMetrics.toolbarControlSize
                == WorkspaceToolbarSymbolMetrics.buttonSize
        )
        #expect(WorkspaceNavigationSidebarMetrics.toolbarSymbolLayoutSize == 22)
        #expect(WorkspaceNavigationSidebarMetrics.toolbarSpacing == 14)
        #expect(
            WorkspaceNavigationSidebarMetrics.toolbarControlSize
                > WorkspaceNavigationSidebarMetrics.toolbarSymbolLayoutSize
        )
    }

    @Test func new_team_and_terminal_commands_share_window_model_availability() throws {
        let model = AppModel(connections: MacConnectionManager())
        #expect(!model.canCreateTeam)
        #expect(!model.canToggleTerminalPanel)
        #expect(!model.canToggleInspector)
        #expect(!model.isNavigationSearchPresented)

        model.projects = [try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)]
        model.selectedProjectID = "project-1"
        model.agents = [try decode(AgentDescriptor.self, from: """
        {
          "id":"claude_code","available":true,"executable":"claude",
          "detail":null,"adapter":null
        }
        """)]

        #expect(model.canCreateTeam)
        #expect(model.canToggleTerminalPanel)
        #expect(model.canToggleInspector)
        #expect(model.isInspectorPresented)
        model.toggleInspector()
        #expect(!model.isInspectorPresented)
        model.toggleInspector()
        #expect(model.isInspectorPresented)
        model.isNavigationSearchPresented = true
        #expect(model.isNavigationSearchPresented)
        model.isTeamSetupPresented = true
        #expect(model.isTeamSetupPresented)
        model.isTerminalPanelPresented = true
        model.toggleTerminalPanel()
        #expect(!model.isTerminalPanelPresented)
    }

    @Test func user_message_bubbles_follow_content_width_and_cap_long_lines() {
        let typography = WorkspaceTypography(
            fontName: WorkspaceTypography.systemFontName,
            pointSize: WorkspaceTypography.defaultPointSize
        )
        let short = UserMessageBubbleMetrics.width(for: "Hi", typography: typography)
        let multiline = UserMessageBubbleMetrics.width(
            for: "Hi\nThis is a longer second line",
            typography: typography
        )
        let long = UserMessageBubbleMetrics.width(
            for: String(repeating: "long ", count: 200),
            typography: typography
        )

        #expect(short >= UserMessageBubbleMetrics.minimumWidth)
        #expect(short < multiline)
        #expect(long == UserMessageBubbleMetrics.maximumWidth)
    }

    @Test func editor_find_commands_share_the_window_model_request() throws {
        let model = AppModel(connections: MacConnectionManager())
        #expect(model.nativeFindRequest.sequence == 0)

        model.requestFind()
        #expect(model.nativeFindRequest.sequence == 0)

        model.activeDocument = try decode(TextDocument.self, from: """
        {"path":"Sources/App.swift","content":"let value = 1","revision":"revision-1","size":13}
        """)
        model.requestFind()
        #expect(model.nativeFindRequest.sequence == 1)
        #expect(model.nativeFindRequest.action == .showFindInterface)
        model.requestFindAndReplace()
        #expect(model.nativeFindRequest.sequence == 2)
        #expect(model.nativeFindRequest.action == .showReplaceInterface)
    }

    @Test func quick_open_keeps_native_actions_clear_of_the_search_toolbar() {
        #expect(QuickOpenPresentationMetrics.actionBarHeight == 52)
        #expect(QuickOpenPresentationMetrics.actionSpacing == 8)
    }

    @Test func application_termination_always_stops_app_owned_connections() {
        let connections = ApplicationConnectionOwnershipSpy()
        let delegate = AppDelegate()
        delegate.connections = connections

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(connections.stopCount == 1)
    }

    @Test func attached_servers_do_not_request_a_managed_runtime_quit_confirmation() {
        let connections = ApplicationConnectionOwnershipSpy()
        let delegate = AppDelegate()
        delegate.connections = connections

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(connections.stopCount == 0)
    }

    @Test func workspace_window_is_reopened_after_empty_state_restoration() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        #expect(AppDelegate.needsWorkspaceWindow(in: []))
        #expect(AppDelegate.needsWorkspaceWindow(in: [window]) == false)
    }

    @Test func workspace_recovery_uses_the_system_new_window_command_before_session_commands() {
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newWindow = NSMenuItem(title: "New Window", action: nil, keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = .command
        let newSession = NSMenuItem(title: "New Session", action: nil, keyEquivalent: "n")
        newSession.keyEquivalentModifierMask = .command
        fileMenu.addItem(newWindow)
        fileMenu.addItem(newSession)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        #expect(AppDelegate.newWindowMenuItem(in: mainMenu) === newWindow)
    }

    @Test @MainActor func window_models_share_connections_but_keep_selection_independent() {
        let connections = MacConnectionManager()
        let first = AppModel(connections: connections)
        let second = AppModel(connections: connections)

        first.selectedProjectID = "project-a"
        first.selectedConversationID = "session-a"

        #expect(first.connections === second.connections)
        #expect(second.selectedProjectID == nil)
        #expect(second.selectedConversationID == nil)
    }

    @Test @MainActor func team_member_navigation_forces_a_read_only_transcript() throws {
        let connections = MacConnectionManager()
        let model = AppModel(connections: connections)
        let conversation = try decode(Conversation.self, from: """
        {
            "id":"member-session",
            "project_id":"project-1",
            "agent_id":"claude_code",
            "title":"Researcher",
            "execution_mode":"default",
            "read_only":false
        }
        """)
        let member = try decode(TeamMember.self, from: """
        {
            "id":"member-1",
            "name":"Researcher",
            "role":"worker",
            "status":"idle",
            "conversation_id":"member-session"
        }
        """)
        model.conversations = [conversation]

        model.openTeamMember(member)
        #expect(model.selectedConversationIsReadOnly)

        model.selectConversation(conversation)
        #expect(!model.selectedConversationIsReadOnly)
    }

#if os(macOS)
    @Test func quick_open_selection_defaults_preserves_and_moves_within_results() throws {
        let first = try decode(FileEntry.self, from: """
        {"path":"Sources/App.swift","name":"App.swift","kind":"file"}
        """)
        let second = try decode(FileEntry.self, from: """
        {"path":"README.md","name":"README.md","kind":"file"}
        """)
        let results = [first, second]

        let identifiers = results.map(\.id)
        #expect(NativeListSelection.reconciled(current: nil, identifiers: identifiers) == first.id)
        #expect(NativeListSelection.reconciled(current: second.id, identifiers: identifiers) == second.id)
        #expect(NativeListSelection.reconciled(current: "removed", identifiers: identifiers) == first.id)
        #expect(NativeListSelection.reconciled(current: first.id, identifiers: []) == nil)
        #expect(NativeListSelection.moved(current: first.id, offset: 1, identifiers: identifiers) == second.id)
        #expect(NativeListSelection.moved(current: second.id, offset: 1, identifiers: identifiers) == second.id)
        #expect(NativeListSelection.moved(current: second.id, offset: -1, identifiers: identifiers) == first.id)
        #expect(NativeListSelection.moved(current: first.id, offset: -1, identifiers: identifiers) == first.id)
    }

    @Test @MainActor func quick_open_cancel_closes_and_clears_an_idle_presentation() throws {
        let model = AppModel(connections: MacConnectionManager())
        model.isQuickOpenPresented = true
        model.isSearchingQuickOpen = true
        model.quickOpenResults = [try decode(FileEntry.self, from: """
        {"path":"Sources/App.swift","name":"App.swift","kind":"file"}
        """)]

        model.dismissQuickOpen()

        #expect(!model.isQuickOpenPresented)
        #expect(!model.isSearchingQuickOpen)
        #expect(model.quickOpenResults.isEmpty)
    }

    @Test @MainActor func quick_open_key_monitor_routes_navigation_open_and_escape_for_its_own_window() throws {
        let model = AppModel(connections: MacConnectionManager())
        model.isQuickOpenPresented = true
        var moves: [Int] = []
        var openCount = 0
        let monitor = NativeListCommandMonitor.KeyMonitorView(frame: .zero)
        monitor.onMove = { offset in moves.append(offset); return true }
        monitor.onOpen = { openCount += 1; return true }
        monitor.onEscape = { model.dismissQuickOpen() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = monitor
        defer { monitor.stopMonitoring() }

        let down = try #require(keyEvent(window: window, keyCode: 125))
        let up = try #require(keyEvent(window: window, keyCode: 126))
        let open = try #require(keyEvent(window: window, keyCode: 36, characters: "\r"))
        let escape = try #require(keyEvent(window: window, keyCode: 53, characters: "\u{1b}"))
        let letter = try #require(keyEvent(window: window, keyCode: 0, characters: "a"))
        let commandDown = try #require(keyEvent(
            window: window,
            keyCode: 125,
            modifiers: .command
        ))

        #expect(monitor.consume(down) == nil)
        #expect(monitor.consume(up) == nil)
        #expect(monitor.consume(open) == nil)
        #expect(monitor.consume(escape) == nil)
        #expect(monitor.consume(letter) === letter)
        #expect(monitor.consume(commandDown) === commandDown)

        #expect(moves == [1, -1])
        #expect(openCount == 1)
        #expect(!model.isQuickOpenPresented)
        #expect(model.quickOpenResults.isEmpty)
    }

    @Test @MainActor func native_quick_open_renders_a_selected_result_list() throws {
        let model = AppModel(connections: MacConnectionManager())
        model.quickOpenResults = [
            try decode(FileEntry.self, from: """
            {"path":"Sources/App.swift","name":"App.swift","kind":"file"}
            """),
            try decode(FileEntry.self, from: """
            {"path":"README.md","name":"README.md","kind":"file"}
            """),
        ]
        let controller = NSHostingController(rootView: QuickOpenSheet(
            model: model,
            onSelect: { _ in },
            initialQuery: "app"
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))

        #expect(recognizedText.contains("App.swift"))
        #expect(recognizedText.contains("README.md"))
        #expect(recognizedText.contains("Cancel"))
        #expect(recognizedText.contains("Open"))
        #expect(bitmap.representation(using: .png, properties: [:])?.count ?? 0 > 8_000)
        if let path = ProcessInfo.processInfo.environment["KUBECODE_QUICK_OPEN_SNAPSHOT"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func agent_markdown_selection_crosses_rendered_lines_and_blocks() throws {
        let controller = NSHostingController(rootView: AgentMarkdownView(source: """
        Selection alpha begins in the first rendered paragraph.

        Selection omega ends in the second rendered paragraph.
        """)
        .frame(width: 440, height: 150, alignment: .topLeading)
        .padding(20))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let textView = try #require(firstSubview(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        let range = try #require(textView.string.range(
            of: "alpha begins in the first rendered paragraph.\nSelection omega"
        ))
        let selection = NSRange(range, in: textView.string)

        NSPasteboard.general.clearContents()
        textView.setSelectedRange(selection)
        window.makeFirstResponder(textView)
        textView.copy(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let selected = NSPasteboard.general.string(forType: .string) ?? ""
        #expect(selected.contains("alpha"))
        #expect(selected.contains("omega"))
    }

    @Test @MainActor func unchanged_agent_markdown_reuses_the_native_rendered_document() {
        let coordinator = NativeSelectableAgentMarkdownView.Coordinator()
        let typography = WorkspaceTypography(fontName: "System", pointSize: 14)
        let source = String(repeating: "A long historical response with **Markdown**.\n", count: 500)

        let first = coordinator.rendered(
            source: source,
            typography: typography,
            tone: .primary
        )
        let second = coordinator.rendered(
            source: source,
            typography: typography,
            tone: .primary
        )

        #expect(first === second)
        #expect(coordinator.renderCount == 1)

        let updated = coordinator.rendered(
            source: source + "streamed delta",
            typography: typography,
            tone: .primary
        )
        #expect(updated !== first)
        #expect(coordinator.renderCount == 2)
    }

    @Test @MainActor func viewport_updates_do_not_replace_unchanged_native_text_storage() throws {
        let coordinator = NativeSelectableAgentMarkdownView.Coordinator()
        let typography = WorkspaceTypography(fontName: "System", pointSize: 14)
        let source = String(repeating: "Historical **Markdown** response.\n", count: 500)

        let initial = try #require(coordinator.renderedUpdate(
            source: source,
            typography: typography,
            tone: .primary
        ))
        #expect(initial.length > 1_000)
        for _ in 0..<1_000 {
            #expect(coordinator.renderedUpdate(
                source: source,
                typography: typography,
                tone: .primary
            ) == nil)
        }

        #expect(coordinator.renderCount == 1)
        #expect(coordinator.applyCount == 1)
        #expect(coordinator.renderedUpdate(
            source: source + "delta",
            typography: typography,
            tone: .primary
        ) != nil)
        #expect(coordinator.renderCount == 2)
        #expect(coordinator.applyCount == 2)
    }

    @Test @MainActor func native_code_blocks_start_at_the_message_leading_edge() throws {
        let typography = WorkspaceTypography(fontName: "System", pointSize: 14)
        let rendered = NativeAgentMarkdownRenderer.render(
            AgentMarkdownDocument(source: """
            ```
            first line
            second line
            ```
            """),
            typography: typography,
            tone: .primary
        )

        #expect(rendered.string == "first line\nsecond line")
        let style = try #require(rendered.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent == 0)
        #expect(style.headIndent == 0)
    }

    @Test @MainActor func inline_math_attachments_use_the_formula_baseline() throws {
        let typography = WorkspaceTypography(fontName: "System", pointSize: 14)
        let rendered = NativeAgentMarkdownRenderer.render(
            AgentMarkdownDocument(source: "Text $x^2 + y^2$ continues."),
            typography: typography,
            tone: .primary
        )
        var attachment: NSTextAttachment?
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            guard let value = value as? NSTextAttachment else { return }
            attachment = value
            stop.pointee = true
        }
        let mathAttachment = try #require(attachment)
        let bounds = mathAttachment.bounds

        #expect(bounds.height > typography.pointSize)
        #expect(bounds.origin.y < -2)
        #expect(bounds.origin.y > -bounds.height)
    }

    @Test @MainActor func agent_response_context_menu_copies_raw_markdown_without_replacing_selection_copy() throws {
        let rawResponse = "**Rendered response** with $x + y$."
        let controller = NSHostingController(rootView: AgentMarkdownView(
            source: rawResponse,
            copyResponseSource: rawResponse
        )
        .frame(width: 440, height: 100, alignment: .topLeading)
        .padding(20))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 140),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let textView = try #require(firstSubview(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))

        let renderedRange = try #require(textView.string.range(of: "Rendered response"))
        textView.setSelectedRange(NSRange(renderedRange, in: textView.string))
        NSPasteboard.general.clearContents()
        textView.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "Rendered response")

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(textView.menu(for: event))
        let copyResponse = try #require(menu.items.first {
            $0.identifier?.rawValue == WorkspaceAccessibilityAction.copyResponse.rawValue
        })
        #expect(copyResponse.title == String(localized: "Copy Response"))

        NSPasteboard.general.clearContents()
        let action = try #require(copyResponse.action)
        #expect(NSApp.sendAction(action, to: copyResponse.target, from: copyResponse))
        #expect(NSPasteboard.general.string(forType: .string) == rawResponse)
    }

    @Test func terminal_header_routes_selection_and_close_to_distinct_commands() {
        var selectionCount = 0
        var closeCount = 0
        let actions = TerminalPaneHeaderActions(
            onSelect: { selectionCount += 1 },
            onClose: { closeCount += 1 }
        )

        actions.select()
        #expect(selectionCount == 1)
        #expect(closeCount == 0)

        actions.close()
        #expect(selectionCount == 1)
        #expect(closeCount == 1)
        #expect(TerminalPaneHeader.selectionIdentifier(terminalID: "one") == "terminal.select.one")
        #expect(TerminalPaneHeader.closeIdentifier(terminalID: "one") == "terminal.close.one")
    }

    @Test @MainActor func terminal_header_keeps_the_native_close_control_visible() throws {
        let controller = NSHostingController(rootView: TerminalPaneHeader(
            terminalID: "terminal-1",
            title: "Shell",
            status: "running",
            isSelected: true,
            onSelect: {},
            onClose: {}
        )
        .frame(width: 320, height: 28))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)

        #expect(contrastingPixelCount(
            in: NSRect(x: 290, y: 5, width: 25, height: 18),
            bitmap: bitmap,
            logicalSize: controller.view.bounds.size
        ) > 8)
        if let path = ProcessInfo.processInfo.environment["KUBECODE_TERMINAL_HEADER_SNAPSHOT"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func agent_markdown_accepts_a_native_mouse_drag_across_visual_lines() throws {
        let controller = NSHostingController(rootView: AgentMarkdownView(source: """
        Drag selection starts on the first visual line and continues through enough words to wrap.

        Drag selection ends on the final rendered paragraph.
        """)
        .frame(width: 320, height: 180, alignment: .topLeading)
        .padding(20))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let textView = try #require(firstSubview(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        let start = try #require(textView.string.range(of: "starts"))
        let end = try #require(textView.string.range(of: "paragraph"))
        let startIndex = NSRange(start, in: textView.string).location
        let endRange = NSRange(end, in: textView.string)
        let startRect = textView.firstRect(
            forCharacterRange: NSRange(location: startIndex, length: 0),
            actualRange: nil
        )
        let endRect = textView.firstRect(
            forCharacterRange: NSRange(location: NSMaxRange(endRange), length: 0),
            actualRange: nil
        )
        let startPoint = window.convertPoint(fromScreen: NSPoint(x: startRect.minX, y: startRect.midY))
        let endPoint = window.convertPoint(fromScreen: NSPoint(x: endRect.maxX, y: endRect.midY))
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let drag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0
        ))
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(drag, atStart: true)
        textView.mouseDown(with: down)

        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        #expect(selected.contains("starts"))
        #expect(selected.contains("paragraph"))
        #expect(selected.contains("\n"))
    }

    @Test func empty_composer_stays_at_single_line_height() {
        let font = NSFont.preferredFont(forTextStyle: .body)

        #expect(ComposerHeightCalculator.height(for: "", width: 640, font: font) == 36)
        #expect(ComposerPresentationMetrics.barHeight(contentHeight: 36) == 56)
        #expect(ComposerPresentationMetrics.barHeight(contentHeight: 72) == 92)
        #expect(ComposerPresentationMetrics.expandedBarHeight(contentHeight: 72) == 138)
        #expect(ComposerPresentationMetrics.leadingInset == 14)
        #expect(ComposerPresentationMetrics.controlSpacing == 12)
        #expect(ComposerPresentationMetrics.transitionDuration == 0.22)
        #expect(ComposerPresentationMetrics.agentDisclosureRotation(isPresented: false) == 0)
        #expect(ComposerPresentationMetrics.agentDisclosureRotation(isPresented: true) == 180)
        #expect(ComposerPresentationMetrics.shouldUseExpandedLayout(
            measuredHeight: 72,
            stateRequested: false
        ))
        #expect(ComposerPresentationMetrics.primaryActionIsProminent(
            hasActiveRun: true,
            hasSendableText: false
        ))
        #expect(!ComposerPresentationMetrics.primaryActionIsProminent(
            hasActiveRun: false,
            hasSendableText: false
        ))
        #expect(ComposerHeightCalculator.height(
            for: String(repeating: "A longer composer line that wraps. ", count: 24),
            width: 280,
            font: font
        ) > 36)
        #expect(ComposerHeightCalculator.height(
            for: String(repeating: "Line\n", count: 20),
            width: 280,
            font: font
        ) == 72)
    }

    @Test @MainActor func native_composer_remeasures_wrapped_text_after_appkit_layout() async {
        var text = String(repeating: "A native composer line that must wrap. ", count: 20)
        var measuredHeight = ComposerHeightCalculator.minimumHeight
        let controller = NSHostingController(rootView: NativeComposerTextView(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            height: Binding(
                get: { measuredHeight },
                set: { measuredHeight = $0 }
            ),
            onSubmit: {}
        )
        .frame(width: 260, height: ComposerHeightCalculator.maximumHeight))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 72),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))

        let scrollView = firstSubview(of: ComposerScrollView.self, in: controller.view)
        let textView = scrollView?.documentView as? NSTextView
        let actualWidth = scrollView?.contentSize.width ?? 0
        let independentlyMeasuredHeight = textView.map {
            ComposerHeightCalculator.height(
                for: $0.string,
                width: actualWidth,
                font: $0.font ?? .preferredFont(forTextStyle: .body)
            )
        } ?? 0
        #expect(actualWidth > 40)
        #expect(textView?.string == text)
        #expect(independentlyMeasuredHeight == ComposerHeightCalculator.maximumHeight)
        #expect(scrollView?.heightBinding != nil)
        scrollView?.heightBinding?.wrappedValue = 40
        #expect(measuredHeight == 40)
        measuredHeight = ComposerHeightCalculator.minimumHeight
        scrollView?.scheduleMeasurement()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(measuredHeight == ComposerHeightCalculator.maximumHeight)
    }

    @Test func editor_tabs_and_terminal_panel_use_bounded_workbench_dimensions() {
        #expect(WorkbenchPresentationMetrics.editorTabHeight == 30)
        #expect(WorkbenchPresentationMetrics.editorTabMaximumWidth == 180)
        #expect(WorkbenchPresentationMetrics.terminalMinimumHeight == 140)
        #expect(WorkbenchPresentationMetrics.terminalIdealHeight == 220)
        #expect(WorkbenchPresentationMetrics.terminalMaximumHeight == 360)
    }

    @Test @MainActor func native_capability_palette_renders_commands_and_file_reference_entry() throws {
        let commands = [
            NativeCommand(name: "review", description: "Review the current changes"),
            NativeCommand(name: "btw", description: "Ask Claude a side question"),
        ]
        var selectedCommand: NativeCommand?
        var fileSelectionCount = 0
        var dismissCount = 0
        let controller = NSHostingController(rootView: ComposerCapabilityPalette(
            commands: commands,
            onChooseCommand: { selectedCommand = $0 },
            onChooseFile: { fileSelectionCount += 1 },
            onDismiss: { dismissCount += 1 }
        )
        .frame(width: 440, height: 360))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))
        #expect(recognizedText.contains("Reference File"))
        #expect(recognizedText.contains("/review"))
        #expect(recognizedText.contains("Review the current changes"))
        #expect(recognizedText.contains("/btw"))
        let monitor = try #require(descendant(
            of: NativeListCommandMonitor.KeyMonitorView.self,
            in: controller.view
        ))
        let down = try #require(keyEvent(window: window, keyCode: 125))
        let open = try #require(keyEvent(window: window, keyCode: 36, characters: "\r"))
        let escape = try #require(keyEvent(window: window, keyCode: 53, characters: "\u{1b}"))
        #expect(monitor.consume(down) == nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(monitor.consume(open) == nil)
        #expect(selectedCommand == commands[0])
        #expect(fileSelectionCount == 0)
        #expect(monitor.consume(escape) == nil)
        #expect(dismissCount == 1)
        if let path = ProcessInfo.processInfo.environment["KUBECODE_CAPABILITY_PALETTE_SNAPSHOT"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func draft_team_setup_renders_runtime_advertised_leader_controls() throws {
        let model = AppModel(connections: MacConnectionManager())
        model.agents = [try decode(AgentDescriptor.self, from: #"""
        {
          "id":"claude_code","available":true,"version":"1","executable":"claude",
          "error":null,"readiness":"ready","checked_at":1,"cli":null,"adapter":null
        }
        """#)]
        let draft = try decode(TeamSnapshot.self, from: #"""
        {
          "team":{
            "id":"team-1","project_id":"project-1","title":"Research Team",
            "status":"draft","goal":"Ship","leader_member_id":"leader-1",
            "workspace":"shared","requested_mode":"standard",
            "acceptance_criteria":["Tests pass"],"allowed_agent_ids":["claude_code"],
            "max_teammates":3,"max_parallel_runs":2,"max_review_rounds":3
          },
          "summary":{"running":0,"queued":0,"needs_attention":0,"done":0,"total_tasks":0},
          "members":[{
            "id":"leader-1","name":"Leader","role":"leader","status":"idle",
            "conversation_id":"leader-session"
          }],
          "tasks":[],"attention":[],
          "leader_conversation":{
            "id":"leader-session","project_id":"project-1","agent_id":"claude_code",
            "title":"Research Team","execution_mode":"shared","team_id":"team-1","team_role":"leader"
          }
        }
        """#)
        let state = try decode(AgentSessionState.self, from: #"""
        {
          "capabilities":null,"available_commands":null,
          "current_mode":{
            "currentModeId":"plan","availableModes":[
              {"id":"default","name":"Default"},{"id":"plan","name":"Plan Mode"}
            ]
          },
          "config_options":{"configOptions":[
            {"id":"model","name":"Model","type":"select","currentValue":"sonnet","options":[
              {"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}
            ]},
            {"id":"fast","name":"Fast mode","type":"boolean","currentValue":true}
          ]},
          "plan":null,"usage":null,"mode_access":{"can_change":true,"reason":null}
        }
        """#)
        let controller = NSHostingController(rootView: TeamSetupSheet(
            model: model,
            draft: draft,
            initialLeaderState: state
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))
        #expect(recognizedText.contains("Leader Configuration"))
        #expect(recognizedText.contains("Plan Mode"))
        #expect(recognizedText.contains("Model"))
        #expect(recognizedText.contains("Sonnet"))
        #expect(recognizedText.contains("Fast mode"))
    }

    @Test @MainActor func native_team_task_details_expose_result_verification_and_safe_actions() throws {
        let snapshot = try decode(TeamSnapshot.self, from: #"""
        {
          "team":{"id":"team-1","project_id":"project-1","title":"Research","status":"active","goal":"Ship"},
          "summary":{"running":0,"queued":0,"needs_attention":0,"done":0,"total_tasks":1},
          "members":[
            {"id":"member-1","name":"Researcher","role":"teammate","status":"idle","conversation_id":"session-1"}
          ],
          "tasks":[
            {"id":"task-1","title":"Audit Runtime","description":"Inspect the implementation","status":"failed","completion_required":true,"assignee_member_id":"member-1","result":"Focused tests passed","verification":"Reviewed independently"}
          ],
          "task_attempts":[
            {"id":"attempt-1","task_id":"task-1","member_id":"member-1","status":"failed","error":"Needs another pass"}
          ],
          "attention":[]
        }
        """#)
        let task = try #require(snapshot.tasks.first)
        let controller = NSHostingController(rootView: TeamTaskDetailSheet(
            snapshot: snapshot,
            task: task,
            onAssign: { _ in },
            onRetry: {},
            onCancel: {},
            onRemoveMember: { _ in },
            onOpenMember: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 1000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))
        #expect(recognizedText.contains("Focused tests passed"))
        #expect(recognizedText.contains("Reviewed independently"))

        let formScrollView = try #require(descendants(of: NSScrollView.self, in: controller.view).first {
            guard let documentView = $0.documentView else { return false }
            return documentView.bounds.height > $0.documentVisibleRect.height + 1
        })
        scrollToBottom(formScrollView)
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let actionsBitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: actionsBitmap)
        let actionText = try recognizeText(in: try #require(actionsBitmap.cgImage))
        #expect(actionText.contains("Retry Task"))
        #expect(actionText.contains("Remove Member"))
        #expect(actionText.contains("Cancel Task"))
    }

    @Test @MainActor func native_team_monitor_surfaces_mode_fallback_and_verification_rounds() async throws {
        let model = AppModel(connections: MacConnectionManager())
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)
        let snapshot = try decode(TeamSnapshot.self, from: #"""
        {
          "team":{
            "id":"team-1","project_id":"project-1","title":"Research Team",
            "status":"needs_attention","goal":"Verify the native implementation",
            "mode":"standard","requested_mode":"yolo",
            "mode_fallback":{
              "agent_id":"claude_code","reason_code":"native_mode_unavailable",
              "reason":"Provider rejected the YOLO permission profile","occurred_at":"now"
            }
          },
          "summary":{"running":0,"queued":0,"needs_attention":1,"done":1,"total_tasks":1},
          "members":[
            {"id":"member-1","name":"Researcher","role":"teammate","status":"needs_attention","conversation_id":"member-session"}
          ],
          "tasks":[],
          "attention":[
            {"id":"attention-1","kind":"member_attention","member_id":"member-1","summary":"Researcher needs input"}
          ],
          "proposal":{
            "id":"proposal-1","summary":"Add an independent review pair","status":"pending",
            "members_json":"[{\"name\":\"Reviewer\"},{\"role\":\"Implementer\"}]"
          },
          "discrimination_rounds":[
            {"id":"round-2","round":2,"status":"completed","verdict":"Implementation accepted","evidence":"58 tests passed"}
          ]
        }
        """#)
        let memberConversation = try decode(Conversation.self, from: """
        {
          "id":"member-session","project_id":"project-1","agent_id":"codex",
          "title":"Researcher","execution_mode":"default"
        }
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        model.teams = [snapshot]
        model.conversations = [memberConversation]
        model.selectTeam(snapshot)

        let controller = NSHostingController(rootView: ContentView(model: model)
            .frame(width: 1400, height: 900))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        await settle(window: window, controller: controller)

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))
        #expect(recognizedText.contains("Provider rejected the YOLO permission profile"))
        #expect(recognizedText.contains("Verification Round 2"))
        #expect(recognizedText.contains("Implementation accepted"))
        #expect(recognizedText.contains("58 tests passed"))
        #expect(recognizedText.contains("Reviewer"))
        #expect(recognizedText.contains("Implementer"))
        #expect(!recognizedText.contains("Reconfigur"))
        #expect(
            recognizedText.components(separatedBy: "Folder Access Required").count - 1 == 1
        )
        #expect(contrastingPixelCount(
            in: NSRect(x: 660, y: 5, width: 35, height: 45),
            bitmap: bitmap,
            logicalSize: controller.view.bounds.size
        ) > 8)
        if let path = ProcessInfo.processInfo.environment["KUBECODE_TEAM_MONITOR_SNAPSHOT"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func native_runtime_diagnostics_exposes_recent_copyable_profile_logs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "RuntimeDiagnosticsSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = ServerProfileStore(defaults: defaults)
        let diagnostics = RuntimeDiagnosticLog(directory: directory)
        try diagnostics.append("manager: Runtime ready for diagnostics", to: .local)
        let connections = MacConnectionManager(profiles: store, diagnostics: diagnostics)
        let controller = NSHostingController(rootView: RuntimeDiagnosticsSettings(
            store: store,
            connections: connections
        )
        .frame(width: 660, height: 540))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        await settle(window: window, controller: controller)
        try? await Task.sleep(for: .milliseconds(150))
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))
        #expect(recognizedText.contains("Runtime Diagnostics"))
        #expect(recognizedText.contains("Copy Logs"))
        #expect(recognizedText.contains("Runtime ready for diagnostics"))
    }

    @Test @MainActor func code_editor_scrolls_horizontally_when_a_middle_line_is_wider_than_the_viewport() async throws {
        let longLine = "let command = \"" + String(repeating: "long-argument-", count: 90) + "\""
        let text = "let short = true\n\(longLine)\nreturn short"
        let controller = NSHostingController(rootView: CodeEditorView(
            text: .constant(text),
            path: "Scripts/long-command.swift"
        )
        .frame(width: 760, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        await settle(window: window, controller: controller)
        let scrollView = try #require(descendant(of: NSScrollView.self, in: controller.view))
        let documentView = try #require(scrollView.documentView)

        #expect(scrollView.hasHorizontalScroller)
        #expect(documentView.frame.width > scrollView.contentView.bounds.width + 400)

        scrollView.contentView.scroll(to: NSPoint(x: 300, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.documentVisibleRect.minX > 200)
        if let path = ProcessInfo.processInfo.environment["KUBECODE_EDITOR_SCROLL_SNAPSHOT"] {
            try snapshot(controller.view).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func project_hydration_preserves_one_navigation_split_shell() async throws {
        let model = AppModel(connections: MacConnectionManager())
        let controller = NSHostingController(rootView: ContentView(model: model)
            .frame(width: 1200, height: 800))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        await settle(window: window, controller: controller)
        let shellBefore = try #require(descendant(
            accessibilityIdentifier: "workspace.navigation-shell.layout",
            in: controller.view
        ))
        let splitBefore = try #require(descendant(of: NSSplitView.self, in: controller.view))
        let toolbarBefore = try #require(window.toolbar)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
        let onboardingFooter = try #require(descendant(
            accessibilityIdentifier: "navigator.runtime-footer.layout",
            in: controller.view
        ))
        let onboardingFooterFrame = controller.view.convert(
            onboardingFooter.bounds,
            from: onboardingFooter
        )
        if controller.view.isFlipped {
            #expect(abs(onboardingFooterFrame.maxY - controller.view.bounds.maxY) <= 10)
        } else {
            #expect(abs(onboardingFooterFrame.minY - controller.view.bounds.minY) <= 10)
        }

        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"SVD","workspaces_enabled":false}
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        await settle(window: window, controller: controller)

        let shellAfter = try #require(descendant(
            accessibilityIdentifier: "workspace.navigation-shell.layout",
            in: controller.view
        ))
        let splitAfter = try #require(descendant(of: NSSplitView.self, in: controller.view))
        let toolbarAfter = try #require(window.toolbar)
        #expect(shellBefore === shellAfter)
        #expect(splitBefore === splitAfter)
        #expect(toolbarBefore === toolbarAfter)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
    }

    @Test @MainActor func files_list_owns_the_remaining_inspector_height() async throws {
        let suite = "FilesLayoutTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ServerProfileStore(defaults: defaults)
        let remote = ServerProfile(
            name: "Snapshot Runtime",
            mode: .httpsAttached,
            url: URL(string: "https://runtime.example")
        )
        try profiles.upsert(remote)
        let model = AppModel(connections: MacConnectionManager(profiles: profiles))
        model.currentServerProfileID = remote.id
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"SVD","workspaces_enabled":false}
        """)
        let jobs = try decode(FileEntry.self, from: """
        {"name":"jobs","path":"jobs","kind":"directory","hidden":false,"ignored":false}
        """)
        let scripts = try decode(FileEntry.self, from: """
        {"name":"scripts","path":"scripts","kind":"directory","hidden":false,"ignored":false}
        """)
        let children = try (0..<24).map { index in
            try decode(FileEntry.self, from: """
            {"name":"job-\(index).sh","path":"jobs/job-\(index).sh","kind":"file","hidden":false,"ignored":false}
            """)
        }
        model.projects = [project]
        model.selectedProjectID = project.id
        model.fileTree.replaceChildren([jobs, scripts], of: "")
        model.fileTree.replaceChildren(children, of: jobs.path)
        model.fileTree.expand(jobs.path)

        let controller = NSHostingController(rootView: ContentView(model: model)
            .frame(width: 1400, height: 900))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        await settle(window: window, controller: controller)
        let navigatorColumn = try #require(descendant(
            accessibilityIdentifier: "navigator.column.layout",
            in: controller.view
        ))
        let searchField = try #require(descendant(of: NSSearchField.self, in: controller.view))
        let closeButton = try #require(window.standardWindowButton(.closeButton))
        let zoomButton = try #require(window.standardWindowButton(.zoomButton))
        let navigatorColumnFrame = controller.view.convert(navigatorColumn.bounds, from: navigatorColumn)
        let searchFrame = controller.view.convert(searchField.bounds, from: searchField)
        let closeButtonFrame = controller.view.convert(closeButton.bounds, from: closeButton)
        let zoomButtonFrame = controller.view.convert(zoomButton.bounds, from: zoomButton)
        let toolbar = try #require(window.toolbar)
        let sidebarToggleIndex = try #require(toolbar.items.firstIndex {
            $0.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
        })
        let navigatorItems = toolbar.items[..<sidebarToggleIndex].filter { $0.view != nil }
        #expect(navigatorItems.count == 1)
        let navigatorControls = try #require(navigatorItems.first?.view)
        let navigatorControlsFrame = controller.view.convert(
            navigatorControls.bounds,
            from: navigatorControls
        )
        #expect(abs(navigatorControlsFrame.midY - closeButtonFrame.midY) <= 2)
        #expect(navigatorControlsFrame.width >= (
            WorkspaceNavigationSidebarMetrics.toolbarControlSize * 2
                + WorkspaceNavigationSidebarMetrics.toolbarSpacing
        ))
        let trafficLightGap = navigatorControlsFrame.minX - zoomButtonFrame.maxX
        #expect(trafficLightGap >= 8)
        #expect(navigatorControlsFrame.maxX <= navigatorColumnFrame.maxX)
        if controller.view.isFlipped {
            #expect(searchFrame.minY >= closeButtonFrame.maxY)
        } else {
            #expect(searchFrame.maxY <= closeButtonFrame.minY)
        }
        #expect(!(window.toolbar?.items.isEmpty ?? true))
        #expect(window.titlebarAccessoryViewControllers.isEmpty)

        let filesList = try #require(descendant(
            accessibilityIdentifier: "explorer.files-list.layout",
            in: controller.view
        ))
        let runtimeFooter = try #require(descendant(
            accessibilityIdentifier: "navigator.runtime-footer.layout",
            in: controller.view
        ))
        let filesFrame = controller.view.convert(filesList.bounds, from: filesList)
        let footerFrame = controller.view.convert(runtimeFooter.bounds, from: runtimeFooter)

        #expect(filesFrame.height >= 120)
        if controller.view.isFlipped {
            #expect(filesFrame.maxY <= footerFrame.minY)
            #expect(abs(footerFrame.maxY - controller.view.bounds.maxY) <= 10)
        } else {
            #expect(filesFrame.minY >= footerFrame.maxY)
            #expect(abs(footerFrame.minY - controller.view.bounds.minY) <= 10)
        }
        #expect(abs(footerFrame.height - WorkspaceNavigationSidebarMetrics.serverSwitcherHeight) <= 1)
        if let path = ProcessInfo.processInfo.environment["KUBECODE_FILES_LAYOUT_SNAPSHOT"] {
            try snapshot(controller.view).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test func terminal_reconnect_stops_at_a_retryable_failure() {
        #expect(!TerminalReconnectPolicy.shouldStopAutomatically(after: 4))
        #expect(TerminalReconnectPolicy.shouldStopAutomatically(after: 5))
        #expect(TerminalReconnectPolicy.delayMilliseconds(attempt: 1) == 250)
        #expect(TerminalReconnectPolicy.delayMilliseconds(attempt: 20) == 4_000)
    }

    @Test @MainActor func revision_navigator_renders_a_stable_native_position_control() throws {
        let navigator = SessionRevisionNavigator(
            activeIndex: 1,
            total: 3,
            isLoading: false,
            onSelect: { _ in }
        )
        #expect(navigator.positionLabel == "Revision 2 of 3")

        let controller = NSHostingController(rootView: navigator
            .padding(12)
            .frame(width: 260, height: 52)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))

        #expect(recognizedText.contains("Revision 2 of 3"))
    }

    @Test @MainActor func global_navigation_renders_actionable_cross_project_search_results() throws {
        let model = AppModel(connections: MacConnectionManager())
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"Local Project","workspaces_enabled":false}
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        let result = WorkspaceNavigationItem(
            kind: .conversation,
            projectID: "project-2",
            resourceID: "session-remote",
            projectName: "Remote Project",
            title: "Remote Approval",
            detail: "Codex",
            status: "waiting_permission",
            attentionCount: 1,
            archived: false
        )
        model.navigationSearchQuery = "approval"
        model.navigationSearchResults = [result]
        model.navigationAttentionItems = [result]

        let controller = NSHostingController(rootView: WorkspaceNavigationSearchResults(
            isSearching: false,
            results: model.navigationSearchResults,
            onOpen: { _ in }
        )
        .frame(width: 380, height: 520))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))

        #expect(recognizedText.contains("Results"))
        #expect(recognizedText.contains("Remote Approval"))
        #expect(recognizedText.contains("Remote Project"))
        #expect(recognizedText.contains("Waiting Permission"))
        if let path = ProcessInfo.processInfo.environment["KUBECODE_NAVIGATION_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func hierarchical_session_sidebar_renders_native_sections_and_relationships() throws {
        let model = AppModel(connections: MacConnectionManager())
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)
        let parent = try decode(Conversation.self, from: """
        {
          "id":"session-parent","project_id":"project-1","agent_id":"codex",
          "title":"Release Work","execution_mode":"shared","archived":false,
          "latest_run_status":"waiting_permission","created_at":"2026-07-23 00:00:00",
          "updated_at":"2026-07-23 00:10:00"
        }
        """)
        let branch = try decode(Conversation.self, from: """
        {
          "id":"session-branch","project_id":"project-1","agent_id":"claude_code",
          "title":"Investigate Failure","execution_mode":"shared","archived":false,
          "created_at":"2026-07-23 00:15:00","updated_at":"2026-07-23 00:20:00",
          "parent_conversation_id":"session-parent","relationship":"branch"
        }
        """)
        let older = try decode(Conversation.self, from: """
        {
          "id":"session-older","project_id":"project-1","agent_id":"opencode",
          "title":"Previous Refactor","execution_mode":"shared","archived":false,
          "created_at":"2026-06-01 00:00:00","updated_at":"2026-06-01 00:00:00"
        }
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        model.conversations = [parent, branch, older]
        model.selectedConversationID = branch.id

        let controller = NSHostingController(rootView: WorkspaceNavigationSidebar(
            model: model,
            onRename: { _ in },
            onDelete: { _ in },
            onPromote: { _ in },
            onDisableWorkspaces: { _ in },
            onRemoveProject: { _ in }
        )
        .frame(width: 380, height: 700))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))

        #expect(png.count > 15_000)
        #expect(recognizedText.contains("Needs Attention"))
        #expect(recognizedText.contains("Kubecode"))
        #expect(recognizedText.contains("Release Work"))
        #expect(recognizedText.contains("Investigate Failure"))
        #expect(recognizedText.contains("Branch"))
        #expect(recognizedText.contains("Older"))
        #expect(recognizedText.contains("Previous Refactor"))
        if let path = ProcessInfo.processInfo.environment["KUBECODE_SESSION_NAVIGATION_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test func code_language_is_selected_from_file_extension() {
        #expect(CodeSyntaxLanguage.detect(path: "Sources/App.swift") == .swift)
        #expect(CodeSyntaxLanguage.detect(path: "server/src/main.rs") == .rust)
        #expect(CodeSyntaxLanguage.detect(path: "package.json") == .json)
        #expect(CodeSyntaxLanguage.detect(path: "README.md") == .markdown)
        #expect(CodeSyntaxLanguage.detect(path: "notes.txt") == .plainText)
    }

    @Test func code_highlighting_marks_language_tokens_without_changing_text() {
        let source = "let answer = 42 // result"
        let highlighted = CodeSyntaxHighlighter.attributedString(
            source,
            path: "Example.swift",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let keywordColor = highlighted.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor

        #expect(highlighted.string == source)
        #expect(keywordColor == .systemPurple)
    }

    @Test @MainActor func unified_explorer_renders_a_nonblank_native_workstation_snapshot() async throws {
        let suite = "ExplorerSnapshotTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ServerProfileStore(defaults: defaults)
        let remote = ServerProfile(
            name: "Snapshot Runtime",
            mode: .httpsAttached,
            url: URL(string: "https://runtime.example")
        )
        try profiles.upsert(remote)
        let model = AppModel(connections: MacConnectionManager(profiles: profiles))
        model.currentServerProfileID = remote.id
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)
        let conversation = try decode(Conversation.self, from: """
        {
          "id":"session-1","project_id":"project-1","agent_id":"claude_code",
          "title":"Native Explorer","execution_mode":"default","latest_run_status":"running"
        }
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        model.conversations = [conversation]
        model.selectedConversationID = conversation.id
        if let snapshotComposer = ProcessInfo.processInfo.environment["KUBECODE_COMPOSER_SNAPSHOT_TEXT"] {
            model.composer = snapshotComposer
        }
        let run = try decode(AgentRun.self, from: """
        {
          "id":"run-1","conversation_id":"session-1","project_id":"project-1",
          "message":"Implement the native revision workflow","status":"completed",
          "error":null,"permission_mode":null,"internal":false
        }
        """)
        model.runs = [run]
        model.transcript = AppModel.transcriptItems(run: run, events: [])
        model.revisions = [try decode(ConversationRevision.self, from: """
        {
          "id":"revision-1","conversation_id":"session-1",
          "snapshot_conversation_id":"snapshot-1","forked_at_run_id":"run-1",
          "created_at":"now","workspace_restore":"restored",
          "workspace_restore_reason":null
        }
        """)]
        model.gitStatus = try decode(GitStatus.self, from: """
        {
          "is_repository":true,"branch":"main",
          "files":[{"path":"Sources/App.swift","index_status":"M","worktree_status":"M"}]
        }
        """)
        model.fileTree.replaceChildren([
            try decode(FileEntry.self, from: """
            {"name":"Sources","path":"Sources","kind":"directory","hidden":false,"ignored":false}
            """),
            try decode(FileEntry.self, from: """
            {"name":"README.md","path":"README.md","kind":"file","hidden":false,"ignored":false}
            """),
        ], of: "")
        model.files = [try decode(FileEntry.self, from: """
        {"name":"README.md","path":"README.md","kind":"file","hidden":false,"ignored":false}
        """)]
        model.applySessionState(try decode(AgentSessionState.self, from: """
        {
          "capabilities":null,"available_commands":null,
          "current_mode":{
            "currentModeId":"build",
            "availableModes":[
              {"id":"build","name":"Build"},
              {"id":"plan","name":"Plan"}
            ]
          },
          "config_options":{
            "configOptions":[{
              "id":"model","name":"Model","currentValue":"sonnet",
              "options":[
                {"value":"sonnet","name":"Sonnet"},
                {"value":"opus","name":"Opus"}
              ]
            }]
          },
          "usage":{
            "used":53000,"size":200000,
            "cost":{"amount":0.045,"currency":"USD"}
          },"mode_access":{"can_change":true,"reason":null},
          "plan":{"entries":[
            {"content":"Inspect the Project","priority":"medium","status":"completed"},
            {"content":"Implement the native Explorer","priority":"high","status":"in_progress"}
          ]}
        }
        """))

        let controller = NSHostingController(rootView: ContentView(model: model)
            .frame(width: 1400, height: 900))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))

        #expect(png.count > 20_000)
        #expect(recognizedText.contains("Changes"))
        #expect(recognizedText.contains("Agent Plan"))
        #expect(recognizedText.contains("Files"))
        #expect(recognizedText.contains("27%"))
        #expect(recognizedText.contains("Completed"))
        if ProcessInfo.processInfo.environment["KUBECODE_COMPOSER_SNAPSHOT_TEXT"] == nil {
            #expect(recognizedText.contains("Claude Code"))
            #expect(recognizedText.contains("Sonnet"))
            #expect(recognizedText.split(separator: "\n").count { $0.contains("Terminal") } == 1)
        }
        #expect(recognizedText.lowercased().contains("revision"))
        if let path = ProcessInfo.processInfo.environment["KUBECODE_EXPLORER_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func native_agent_markdown_renders_blocks_and_core_text_math() throws {
        let controller = NSHostingController(rootView: AgentMarkdownView(source: #"""
        # Result

        - Native markdown
        - Selectable code

        Inline formula $z = 1$ remains in the paragraph.

        \[P(X=x\mid p) \propto p^x(1-p)^{n-x}\]

        \[
        \boxed{p\mid X=x \sim \operatorname{Beta}(\alpha+x,\beta+n-x)}
        \]

        \[
        \text{new }\alpha

        = \text{old }\alpha + \text{successes}
        \]

        ```swift
        let answer = 42
        ```
        """#)
        .padding(24)
        .frame(width: 720, height: 700, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.displayIfNeeded()

        let textView = try #require(firstSubview(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        ))
        #expect(Set(textView.renderedMathSources) == [
            #"\(z = 1\)"#,
            #"\[P(X=x\mid p) \propto p^x(1-p)^{n-x}\]"#,
            #"\[\boxed{p\mid X=x \sim \operatorname{Beta}(\alpha+x,\beta+n-x)}\]"#,
            #"""
            \[\text{new }\alpha

            = \text{old }\alpha + \text{successes}\]
            """#,
        ])
        NSPasteboard.general.clearContents()
        textView.setSelectedRange(NSRange(location: 0, length: textView.attributedString().length))
        textView.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        #expect(copied.contains(#"\boxed{p\mid X=x"#))
        #expect(copied.contains(#"\operatorname{Beta}"#))

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["KUBECODE_MARKDOWN_SNAPSHOT"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))
        #expect(recognizedText.contains("Result"))
        #expect(recognizedText.contains("Native markdown"))
        #expect(recognizedText.contains("answer = 42"))
    }

    @Test func inline_markdown_flow_aligns_text_and_math_on_each_baseline() {
        let geometry = MarkdownFlowLayout.geometry(
            for: [
                .init(size: CGSize(width: 48, height: 20), firstTextBaseline: 15),
                .init(size: CGSize(width: 14, height: 14), firstTextBaseline: 11),
                .init(size: CGSize(width: 48, height: 20), firstTextBaseline: 15),
            ],
            maximumWidth: 70,
            rowSpacing: 3
        )

        #expect(geometry.positions == [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 48, y: 4),
            CGPoint(x: 0, y: 23),
        ])
        #expect(geometry.size == CGSize(width: 62, height: 43))
    }

    @Test @MainActor func editor_and_agent_tui_render_as_bounded_workbench_panes() throws {
        let model = AppModel(connections: MacConnectionManager())
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)
        let document = try decode(TextDocument.self, from: #"""
        {
          "path":"Sources/App.swift",
          "content":"import SwiftUI\n\nstruct AppView: View {\n    var body: some View { Text(\"Native\") }\n}",
          "revision":"rev-1","size":86
        }
        """#)
        let terminal = try decode(TerminalInfo.self, from: """
        {
          "id":"term-1","project_id":"project-1","conversation_id":null,
          "title":"Claude Code","kind":"claude_code","cols":100,"rows":28,
          "status":"running","exit_code":null,"signal":null
        }
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        model.openDocuments = [document]
        model.activeDocument = document
        model.documentDraft = document.content
        model.terminals = [terminal]
        model.selectTerminal(terminal)

        let controller = NSHostingController(rootView: ContentView(model: model)
            .frame(width: 1400, height: 900))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))
        if let path = ProcessInfo.processInfo.environment["KUBECODE_WORKBENCH_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        #expect(png.count > 25_000)
        #expect(contrastingPixelCount(
            in: NSRect(x: 1_300, y: 565, width: 40, height: 35),
            bitmap: bitmap,
            logicalSize: controller.view.bounds.size
        ) > 50)
        #expect(recognizedText.contains("App.swift"))
        #expect(recognizedText.contains("Claude Code"))
        #expect(recognizedText.contains("Terminal"))
    }

    @Test @MainActor func dirty_document_requires_a_close_decision() throws {
        let model = AppModel(connections: MacConnectionManager())
        let document = try decode(TextDocument.self, from: """
        {"path":"Sources/App.swift","content":"let value = 1","revision":"rev-1","size":13}
        """)
        model.openDocuments = [document]
        model.activeDocument = document
        model.documentDraft = "let value = 2"

        model.requestCloseDocument(document)

        #expect(model.pendingDocumentClosePath == document.path)
        #expect(model.openDocuments == [document])

        model.cancelPendingDocumentClose()
        #expect(model.pendingDocumentClosePath == nil)

        model.requestCloseDocument(document)
        model.discardPendingDocumentClose()
        #expect(model.openDocuments.isEmpty)
        #expect(model.activeDocument == nil)
    }

    @Test @MainActor func clean_document_closes_without_a_prompt() throws {
        let model = AppModel(connections: MacConnectionManager())
        let document = try decode(TextDocument.self, from: """
        {"path":"README.md","content":"Ready","revision":"rev-1","size":5}
        """)
        model.openDocuments = [document]
        model.activeDocument = document
        model.documentDraft = document.content

        model.requestCloseDocument(document)

        #expect(model.pendingDocumentClosePath == nil)
        #expect(model.openDocuments.isEmpty)
    }

    @Test func revision_conflicts_are_actionable_document_failures() {
        let conflict = DocumentSaveFailure(code: "revision_conflict", message: "File changed")
        let generic = DocumentSaveFailure(code: "request_failed", message: "Offline")

        #expect(conflict == .revisionConflict("File changed"))
        #expect(generic == .other("Offline"))
    }

    @Test func native_find_requests_preserve_the_system_action() {
        var request = NativeFindRequest()

        request.send(.showReplaceInterface)

        #expect(request.sequence == 1)
        #expect(request.action == .showReplaceInterface)
    }

    @Test @MainActor func selecting_terminal_opens_bottom_panel_without_replacing_document() throws {
        let model = AppModel(connections: MacConnectionManager())
        let document = try decode(TextDocument.self, from: """
        {"path":"Sources/App.swift","content":"let value = 1","revision":"rev-1","size":13}
        """)
        let terminal = try decode(TerminalInfo.self, from: """
        {
            "id":"term-1","project_id":"project-1","conversation_id":"session-1",
            "title":"Claude Code","kind":"claude_code","cols":100,"rows":28,
            "status":"running","exit_code":null,"signal":null
        }
        """)
        model.activeDocument = document

        model.selectTerminal(terminal)

        #expect(model.activeDocument == document)
        #expect(model.isTerminalPanelPresented)
        #expect(model.terminalWorkspace.activeGroup?.layout.terminalIDs == [terminal.id])
        #expect(model.activeTerminalID == terminal.id)
    }

    @Test @MainActor func terminal_layout_restores_per_window_and_project() throws {
        let suite = "AppModelTerminalWorkspace-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let first = try decode(TerminalInfo.self, from: """
        {
            "id":"term-1","project_id":"project-1","conversation_id":"session-1",
            "title":"Claude Code","kind":"claude_code","cols":100,"rows":28,
            "status":"running","exit_code":null,"signal":null
        }
        """)
        let second = try decode(TerminalInfo.self, from: """
        {
            "id":"term-2","project_id":"project-1","conversation_id":null,
            "title":"Shell","kind":"regular","cols":100,"rows":28,
            "status":"running","exit_code":null,"signal":null
        }
        """)
        let original = AppModel(
            connections: MacConnectionManager(),
            terminalWorkspaceStore: store
        )
        original.configureWindowPersistence(id: "window-1")
        original.selectedProjectID = "project-1"
        original.terminals = [first, second]
        original.reconcileTerminalWorkspace()
        original.selectTerminal(first)
        original.openTerminal(second, inSplit: .vertical)

        let restored = AppModel(
            connections: MacConnectionManager(),
            terminalWorkspaceStore: store
        )
        restored.configureWindowPersistence(id: "window-1")
        restored.selectedProjectID = "project-1"
        restored.terminals = [first, second]
        restored.reconcileTerminalWorkspace()
        let independent = AppModel(
            connections: MacConnectionManager(),
            terminalWorkspaceStore: store
        )
        independent.configureWindowPersistence(id: "window-2")
        independent.selectedProjectID = "project-1"
        independent.terminals = [first, second]
        independent.reconcileTerminalWorkspace()

        #expect(restored.terminalWorkspace.groups.count == 1)
        #expect(restored.terminalWorkspace.activeGroup?.layout.terminalIDs == ["term-1", "term-2"])
        #expect(independent.terminalWorkspace.groups.count == 2)
    }

    @Test func terminal_stream_tracks_cursor_and_exit_status() throws {
        let output = try decode(TerminalServerEvent.self, from: """
        {"type":"output","data":"ready\\n","cursor":42,"truncated":true}
        """)
        let status = try decode(TerminalServerEvent.self, from: """
        {"type":"status","status":"exited","exit_code":7,"signal":null}
        """)
        var state = TerminalStreamState()

        let outputUpdate = state.apply(output)
        let statusUpdate = state.apply(status)

        #expect(outputUpdate == .output(data: "ready\n", reset: true))
        #expect(statusUpdate == .status(status: "exited", exitCode: 7, signal: nil))
        #expect(state.cursor == 42)
        #expect(state.isExited)
    }

    @Test func terminal_restart_preserves_original_runtime_context() throws {
        let terminal = try decode(TerminalInfo.self, from: """
        {
            "id":"term-old","project_id":"project-1","conversation_id":"session-original",
            "title":"Tests","kind":"codex","cols":132,"rows":41,
            "status":"exited","exit_code":1,"signal":null
        }
        """)

        let restart = TerminalRestartDescriptor(terminal: terminal)

        #expect(restart.projectID == "project-1")
        #expect(restart.conversationID == "session-original")
        #expect(restart.title == "Tests")
        #expect(restart.kind == .codex)
        #expect(restart.cols == 132)
        #expect(restart.rows == 41)
    }

    @Test func restarting_terminal_preserves_pane_order() {
        #expect(AppModel.replacingTerminalID(
            "term-old",
            with: "term-new",
            in: ["term-left", "term-old", "term-right"]
        ) == ["term-left", "term-new", "term-right"])
    }

    private func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { firstSubview(of: type, in: $0) }.first
    }
#endif

    @Test func streaming_text_and_thinking_deltas_are_grouped_by_provider_message() throws {
        let run = try decode(AgentRun.self, from: """
        {
            "id":"run-1",
            "conversation_id":"session-1",
            "project_id":"project-1",
            "message":"Explain the failure",
            "status":"completed",
            "error":null
        }
        """)
        let events = try decode([AgentEvent].self, from: """
        [
            {"run_id":"run-1","seq":1,"kind":"thinking_delta","payload":{"messageId":"thought-1","text":"Inspect "},"created_at":"2026-07-22T00:00:00Z"},
            {"run_id":"run-1","seq":2,"kind":"thinking_delta","payload":{"messageId":"thought-1","text":"the logs."},"created_at":"2026-07-22T00:00:01Z"},
            {"run_id":"run-1","seq":3,"kind":"text_delta","payload":{"message_id":"answer-1","text":"The socket "},"created_at":"2026-07-22T00:00:02Z"},
            {"run_id":"run-1","seq":4,"kind":"text_delta","payload":{"message_id":"answer-1","text":"closed."},"created_at":"2026-07-22T00:00:03Z"}
        ]
        """)

        let items = AppModel.transcriptItems(run: run, events: events)

        #expect(items.count == 4)
        #expect(items[0].role == .user)
        #expect(items[1].role == .thinking)
        #expect(items[1].text == "Inspect the logs.")
        #expect(items[2].role == .agent)
        #expect(items[2].text == "The socket closed.")
        #expect(items[3].role == .status)
        #expect(items[3].status == "completed")
    }

    @Test func separate_provider_messages_do_not_merge() throws {
        let run = try decode(AgentRun.self, from: """
        {
            "id":"run-2",
            "conversation_id":"session-1",
            "project_id":"project-1",
            "message":"Continue",
            "status":"completed",
            "error":null
        }
        """)
        let events = try decode([AgentEvent].self, from: """
        [
            {"run_id":"run-2","seq":1,"kind":"text_delta","payload":{"messageId":"answer-1","text":"First"},"created_at":"2026-07-22T00:00:00Z"},
            {"run_id":"run-2","seq":2,"kind":"text_delta","payload":{"messageId":"answer-2","text":"Second"},"created_at":"2026-07-22T00:00:01Z"}
        ]
        """)

        let items = AppModel.transcriptItems(run: run, events: events)

        #expect(items.map(\.text) == ["Continue", "First", "Second", "completed"])
        #expect(items.last?.role == .status)
    }

    @Test func live_workspace_deltas_append_to_stable_message_blocks() throws {
        let events = try decode([WorkspaceEvent].self, from: """
        [
            {"id":41,"kind":"thinking_delta","project_id":"project-1","conversation_id":"session-1","run_id":"run-3","payload":{"message_id":"thought-1","text":"Check "},"created_at":"2026-07-22T00:00:00Z"},
            {"id":42,"kind":"thinking_delta","project_id":"project-1","conversation_id":"session-1","run_id":"run-3","payload":{"message_id":"thought-1","text":"state."},"created_at":"2026-07-22T00:00:01Z"},
            {"id":43,"kind":"text_delta","project_id":"project-1","conversation_id":"session-1","run_id":"run-3","payload":{"message_id":"answer-1","text":"It "},"created_at":"2026-07-22T00:00:02Z"},
            {"id":44,"kind":"text_delta","project_id":"project-1","conversation_id":"session-1","run_id":"run-3","payload":{"message_id":"answer-1","text":"streams."},"created_at":"2026-07-22T00:00:03Z"}
        ]
        """)

        let items = events.reduce(into: [TranscriptItem]()) { items, event in
            AppModel.applyStreamingDelta(event, to: &items)
        }

        #expect(items.count == 2)
        #expect(items[0].role == .thinking)
        #expect(items[0].text == "Check state.")
        #expect(items[1].role == .agent)
        #expect(items[1].text == "It streams.")
    }

    @Test func long_streams_keep_stable_thinking_answer_and_tool_rows() throws {
        var items: [TranscriptItem] = []

        for sequence in 1...400 {
            let event = try decode(AgentEvent.self, from: """
            {
                "run_id":"run-long",
                "seq":\(sequence),
                "kind":"thinking_delta",
                "payload":{"message_id":"thought-1","text":"x"},
                "created_at":"2026-07-23T00:00:00Z"
            }
            """)
            TranscriptReducer.applyStreamingEvent(event, to: &items)
        }
        for sequence in 401...800 {
            let event = try decode(AgentEvent.self, from: """
            {
                "run_id":"run-long",
                "seq":\(sequence),
                "kind":"text_delta",
                "payload":{"message_id":"answer-1","text":"y"},
                "created_at":"2026-07-23T00:00:00Z"
            }
            """)
            TranscriptReducer.applyStreamingEvent(event, to: &items)
        }
        for sequence in 801...900 {
            let event = try decode(AgentEvent.self, from: """
            {
                "run_id":"run-long",
                "seq":\(sequence),
                "kind":"tool_updated",
                "payload":{
                    "tool_id":"tool-1",
                    "tool":"Shell",
                    "output":"chunk \(sequence)",
                    "status":"running"
                },
                "created_at":"2026-07-23T00:00:00Z"
            }
            """)
            TranscriptReducer.applyStreamingEvent(event, to: &items)
        }

        #expect(items.count == 3)
        #expect(items.map(\.role) == [.thinking, .agent, .tool])
        #expect(items[0].text.count == 400)
        #expect(items[1].text.count == 400)
        #expect(items[2].detail == "Output\nchunk 900")
    }

    @Test @MainActor func native_conversation_fixture_keeps_user_and_agent_surfaces_distinct() async throws {
        let model = AppModel(connections: MacConnectionManager())
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)
        let conversation = try decode(Conversation.self, from: """
        {
          "id":"session-1","project_id":"project-1","agent_id":"claude_code",
          "title":"Native Conversation","execution_mode":"default","latest_run_status":"completed"
        }
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        model.conversations = [conversation]
        model.selectedConversationID = conversation.id
        model.transcript = [
            TranscriptItem(
                id: "run-1-user",
                role: .user,
                text: "Explain the native implementation and verify the result.",
                runID: "run-1"
            ),
            TranscriptItem(
                id: "run-1-thinking",
                role: .thinking,
                text: "Inspect the existing implementation before choosing the smallest coherent change.",
                eventKind: "thinking_delta",
                runID: "run-1"
            ),
            TranscriptItem(
                id: "run-1-answer",
                role: .agent,
                text: """
                ## Result

                The native implementation keeps system controls and selectable Markdown.

                - User messages remain on the right.
                - Agent output, thinking, and tools remain on the left.
                """,
                eventKind: "text_delta",
                runID: "run-1"
            ),
            TranscriptItem(
                id: "run-1-tool",
                role: .tool,
                text: "Run focused tests",
                runID: "run-1",
                detail: "All focused checks passed.",
                status: "completed"
            ),
            TranscriptItem(
                id: "run-1-status",
                role: .status,
                text: "completed",
                runID: "run-1",
                status: "completed"
            ),
        ]

        let controller = NSHostingController(rootView: ContentView(model: model)
            .frame(width: 980, height: 760))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        await settle(window: window, controller: controller)
        let rendered = try snapshot(controller.view)
        let bitmap = try #require(NSBitmapImageRep(data: rendered))
        let recognizedText = try recognizeText(in: try #require(bitmap.cgImage))

        #expect(recognizedText.contains("Native Conversation"))
        #expect(recognizedText.contains("Explain the native implementation"))
        #expect(recognizedText.contains("Result"))
        #expect(recognizedText.contains("Run focused tests"))
        let markdownViews = descendants(
            of: NativeAgentMarkdownTextView.self,
            in: controller.view
        )
        #expect(markdownViews.count >= 2)
        let markdownFrames = markdownViews
            .map { $0.convert($0.bounds, to: controller.view) }
            .sorted { $0.minY < $1.minY }
        #expect(markdownFrames.allSatisfy { $0.height > 20 })
        for pair in zip(markdownFrames, markdownFrames.dropFirst()) {
            #expect(pair.0.maxY <= pair.1.minY + 1)
        }
        if let path = ProcessInfo.processInfo.environment["KUBECODE_TRANSCRIPT_SNAPSHOT"] {
            try rendered.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test @MainActor func transcript_follows_streaming_output_without_overriding_user_scroll() async throws {
        let model = AppModel(connections: MacConnectionManager())
        let project = try decode(Project.self, from: """
        {"id":"project-1","name":"Kubecode","workspaces_enabled":false}
        """)
        let conversation = try decode(Conversation.self, from: """
        {
          "id":"session-1","project_id":"project-1","agent_id":"codex",
          "title":"Streaming Session","execution_mode":"default","latest_run_status":"running"
        }
        """)
        model.projects = [project]
        model.selectedProjectID = project.id
        model.conversations = [conversation]
        model.selectedConversationID = conversation.id
        model.transcript = [
            TranscriptItem(
                id: "run-1-user",
                role: .user,
                text: "Explain the implementation",
                runID: "run-1"
            ),
            TranscriptItem(
                id: "run-1-answer",
                role: .agent,
                text: String(repeating: "Initial streamed output line.\n", count: 80),
                eventKind: "text_delta",
                runID: "run-1"
            ),
        ]

        let controller = NSHostingController(rootView: ContentView(model: model)
            .frame(width: 980, height: 680))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        await settle(window: window, controller: controller)
        let observer = try #require(descendant(
            of: NativeTranscriptScrollObserver.ObserverView.self,
            in: controller.view
        ))
        let scrollView = try #require(observer.enclosingScrollView)
        #expect(distanceFromBottom(of: scrollView) <= 80)

        model.transcript[1] = TranscriptItem(
            id: "run-1-answer",
            role: .agent,
            text: String(repeating: "Growing streamed output line.\n", count: 130),
            eventKind: "text_delta",
            runID: "run-1"
        )
        await settle(window: window, controller: controller)
        #expect(distanceFromBottom(of: scrollView) <= 80)

        scrollUp(scrollView, distance: 240)
        observer.coordinator?.reportUserNavigation()
        try? await Task.sleep(for: .milliseconds(80))
        let userPosition = scrollView.documentVisibleRect.origin.y
        #expect(distanceFromBottom(of: scrollView) > 150)

        model.transcript[1] = TranscriptItem(
            id: "run-1-answer",
            role: .agent,
            text: String(repeating: "Growing streamed output line.\n", count: 180),
            eventKind: "text_delta",
            runID: "run-1"
        )
        await settle(window: window, controller: controller)
        #expect(abs(scrollView.documentVisibleRect.origin.y - userPosition) < 4)
        #expect(distanceFromBottom(of: scrollView) > 150)

        scrollToBottom(scrollView)
        observer.coordinator?.reportUserNavigation()
        try? await Task.sleep(for: .milliseconds(80))
        model.transcript[1] = TranscriptItem(
            id: "run-1-answer",
            role: .agent,
            text: String(repeating: "Growing streamed output line.\n", count: 220),
            eventKind: "text_delta",
            runID: "run-1"
        )
        await settle(window: window, controller: controller)
        #expect(distanceFromBottom(of: scrollView) <= 48)
    }

    @Test func run_stream_reconnect_resumes_after_the_last_sequence_and_is_bounded() {
        var policy = RunStreamReconnectPolicy(initialSequence: 7)

        let acceptedEight = policy.accept(sequence: 8)
        let duplicateEight = policy.accept(sequence: 8)
        let olderSix = policy.accept(sequence: 6)
        let firstRetry = policy.recordDisconnection()
        let secondRetry = policy.recordDisconnection()

        let acceptedNine = policy.accept(sequence: 9)
        let resetRetry = policy.recordDisconnection()
        let nextRetry = policy.recordDisconnection()
        let thirdRetry = policy.recordDisconnection()
        let fourthRetry = policy.recordDisconnection()
        let stopped = policy.recordDisconnection()

        #expect(acceptedEight)
        #expect(!duplicateEight)
        #expect(!olderSix)
        #expect(firstRetry == .retry(afterSequence: 8, delayMilliseconds: 250))
        #expect(secondRetry == .retry(afterSequence: 8, delayMilliseconds: 500))
        #expect(acceptedNine)
        #expect(resetRetry == .retry(afterSequence: 9, delayMilliseconds: 250))
        #expect(nextRetry == .retry(afterSequence: 9, delayMilliseconds: 500))
        #expect(thirdRetry == .retry(afterSequence: 9, delayMilliseconds: 1_000))
        #expect(fourthRetry == .retry(afterSequence: 9, delayMilliseconds: 2_000))
        #expect(stopped == .stop)
    }

    @Test func history_prepend_preserves_order_and_deduplicates_stable_items() throws {
        let oldPage = try decode(ConversationHistoryPage.self, from: """
        {
            "runs":[{
                "id":"run-old",
                "conversation_id":"session-1",
                "project_id":"project-1",
                "message":"Old question",
                "status":"completed",
                "error":null
            }],
            "events":{
                "run-old":[
                    {"run_id":"run-old","seq":1,"kind":"text_delta","payload":{"message_id":"old-answer","text":"Old answer"},"created_at":"2026-07-22T00:00:00Z"}
                ]
            },
            "next_cursor":null,
            "session_events":[]
        }
        """)
        let newRun = try decode(AgentRun.self, from: """
        {
            "id":"run-new",
            "conversation_id":"session-1",
            "project_id":"project-1",
            "message":"New question",
            "status":"completed",
            "error":null
        }
        """)
        let newEvents = try decode([AgentEvent].self, from: """
        [
            {"run_id":"run-new","seq":1,"kind":"text_delta","payload":{"message_id":"new-answer","text":"New answer"},"created_at":"2026-07-22T00:01:00Z"}
        ]
        """)
        let existing = AppModel.transcriptItems(run: newRun, events: newEvents)

        let first = AppModel.prependingHistory(oldPage, to: existing)
        let second = AppModel.prependingHistory(oldPage, to: first)
        let runs = AppModel.prependingRuns(oldPage.runs, to: [newRun])

        #expect(first.map(\.text) == [
            "Old question", "Old answer", "completed",
            "New question", "New answer", "completed",
        ])
        #expect(first.filter { $0.role == .status }.count == 2)
        #expect(second.map(\.id) == first.map(\.id))
        #expect(runs.map(\.id) == ["run-old", "run-new"])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func keyEvent(
        window: NSWindow,
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func descendant<ViewType: NSView>(
        of type: ViewType.Type,
        in view: NSView
    ) -> ViewType? {
        if let match = view as? ViewType { return match }
        for child in view.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

    private func descendants<ViewType: NSView>(
        of type: ViewType.Type,
        in view: NSView
    ) -> [ViewType] {
        var matches = view.subviews.flatMap { descendants(of: type, in: $0) }
        if let match = view as? ViewType { matches.insert(match, at: 0) }
        return matches
    }

    private func descendant(
        accessibilityIdentifier: String,
        in view: NSView
    ) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier { return view }
        for child in view.subviews {
            if let match = descendant(
                accessibilityIdentifier: accessibilityIdentifier,
                in: child
            ) {
                return match
            }
        }
        return nil
    }

    private func distanceFromBottom(of scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        let visible = scrollView.documentVisibleRect
        return documentView.isFlipped
            ? max(0, documentView.bounds.maxY - visible.maxY)
            : max(0, visible.minY - documentView.bounds.minY)
    }

    private func contrastingPixelCount(
        in logicalRect: NSRect,
        bitmap: NSBitmapImageRep,
        logicalSize: NSSize
    ) -> Int {
        let scaleX = CGFloat(bitmap.pixelsWide) / logicalSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / logicalSize.height
        let minX = max(0, Int(logicalRect.minX * scaleX))
        let maxX = min(bitmap.pixelsWide, Int(logicalRect.maxX * scaleX))
        let minY = max(0, Int(logicalRect.minY * scaleY))
        let maxY = min(bitmap.pixelsHigh, Int(logicalRect.maxY * scaleY))
        var count = 0
        for x in minX..<maxX {
            for y in minY..<maxY {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.alphaComponent > 0.5,
                   min(color.redComponent, color.greenComponent, color.blueComponent) < 0.72 {
                    count += 1
                }
            }
        }
        return count
    }

    private func scrollUp(_ scrollView: NSScrollView, distance: CGFloat) {
        let visible = scrollView.documentVisibleRect
        let nextY = scrollView.documentView?.isFlipped == false
            ? visible.origin.y + distance
            : visible.origin.y - distance
        scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: max(0, nextY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollToBottom(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let visible = scrollView.documentVisibleRect
        let nextY = documentView.isFlipped
            ? max(0, documentView.bounds.maxY - visible.height)
            : documentView.bounds.minY
        scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func settle(
        window: NSWindow,
        controller: NSHostingController<some View>
    ) async {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(120))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }

    private func snapshot(_ view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
