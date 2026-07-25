import Foundation
import AppKit
import Testing
@testable import KubecodeApp
import KubecodeKit
import KubecodeMacRuntime

@Suite
@MainActor
struct DocumentLifecycleTests {
    @Test @MainActor func workspace_window_uses_a_full_size_transparent_native_titlebar() {
        let model = AppModel(connections: MacConnectionManager())
        let coordinator = WorkspaceWindowCloseCoordinator(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        coordinator.attach(to: window)

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarSeparatorStyle == .none)
    }

    @Test func switching_between_documents_preserves_each_dirty_draft() throws {
        let model = AppModel(connections: MacConnectionManager())
        let first = try document(path: "Sources/First.swift", content: "let first = 1")
        let second = try document(path: "Sources/Second.swift", content: "let second = 2")
        model.openDocuments = [first, second]
        model.activeDocument = first
        model.documentDraft = "let first = 10"

        model.selectDocument(second)
        #expect(model.documentDraft == second.content)
        #expect(model.isDocumentDirty(first))

        model.documentDraft = "let second = 20"
        model.selectDocument(first)
        #expect(model.documentDraft == "let first = 10")
        #expect(model.isDocumentDirty(second))

        model.requestCloseDocument(second)
        #expect(model.pendingDocumentClosePath == second.path)
        #expect(model.activeDocument?.path == first.path)
    }

    @Test func autosave_scheduler_uses_one_second_and_debounces_edits() async {
        #expect(DocumentAutosaveScheduler.defaultDelay == .seconds(1))
        let scheduler = DocumentAutosaveScheduler(delay: .milliseconds(40))
        var saves: [String] = []

        scheduler.schedule(key: "Sources/App.swift") { saves.append("first") }
        try? await Task.sleep(for: .milliseconds(20))
        scheduler.schedule(key: "Sources/App.swift") { saves.append("second") }
        let debouncedSaveCompleted = await eventually { saves == ["second"] }

        #expect(debouncedSaveCompleted)
        #expect(saves == ["second"])

        saves.removeAll()
        scheduler.schedule(key: "Sources/First.swift") { saves.append("first-file") }
        scheduler.schedule(key: "Sources/Second.swift") { saves.append("second-file") }
        let independentSavesCompleted = await eventually {
            Set(saves) == Set(["first-file", "second-file"])
        }
        #expect(independentSavesCompleted)
        #expect(Set(saves) == Set(["first-file", "second-file"]))
    }

    @Test func window_close_collects_every_dirty_document_in_tab_order() throws {
        let model = AppModel(connections: MacConnectionManager())
        let first = try document(path: "Sources/First.swift", content: "let first = 1")
        let second = try document(path: "Sources/Second.swift", content: "let second = 2")
        let clean = try document(path: "README.md", content: "Ready")
        model.openDocuments = [first, clean, second]
        model.documentDrafts[first.path] = "let first = 10"
        model.activeDocument = second
        model.documentDraft = "let second = 20"

        #expect(model.dirtyDocumentPathsForWindowClose() == [first.path, second.path])
        #expect(model.documentDrafts[second.path] == "let second = 20")
    }

    @Test func missing_folder_access_disables_file_commands_and_preserves_dirty_close_save() async throws {
        let model = AppModel(connections: MacConnectionManager())
        let project = try project(id: "project-1")
        let source = try document(path: "Sources/App.swift", content: "let value = 1")
        model.projects = [project]
        model.selectedProjectID = project.id
        model.openDocuments = [source]
        model.activeDocument = source
        model.documentDraft = "let value = 2"

        #expect(model.selectedProjectNeedsFolderAccess)
        #expect(!model.canUseSelectedProjectFiles)
        #expect(!model.canSaveActiveDocument)
        #expect(await model.saveDocumentForWindowClose(path: source.path) == .failed)
        #expect(model.documentDraft == "let value = 2")
        #expect(model.errorMessage == String(localized: "Restore folder access before saving this file."))

        model.errorMessage = nil
        model.requestCloseDocument(source)
        model.savePendingDocumentClose()
        #expect(model.pendingDocumentClosePath == source.path)
        #expect(model.documentDraft == "let value = 2")
        #expect(model.errorMessage == String(localized: "Restore folder access before saving this file."))
    }

    @Test func window_close_queue_resolves_in_order_and_cancel_preserves_remaining_work() {
        var queue = WindowDocumentCloseQueue(paths: ["First.swift", "Second.swift", "First.swift"])

        #expect(queue.currentPath == "First.swift")
        #expect(queue.resolveCurrent() == .needsDecision("Second.swift"))
        #expect(queue.currentPath == "Second.swift")

        queue.cancel()
        #expect(queue.state == .cancelled)
        #expect(queue.currentPath == nil)
    }

    @Test func window_delegate_uses_a_native_sheet_and_cancel_preserves_the_draft() async throws {
        let model = AppModel(connections: MacConnectionManager())
        let document = try document(path: "Sources/App.swift", content: "let value = 1")
        model.openDocuments = [document]
        model.activeDocument = document
        model.documentDraft = "let value = 2"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let coordinator = WorkspaceWindowCloseCoordinator(model: model)
        coordinator.attach(to: window)

        #expect(!coordinator.windowShouldClose(window))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))

        let alert = try #require(coordinator.presentedAlert)
        #expect(window.attachedSheet === alert.window)
        #expect(alert.buttons.map(\.title) == ["Save", "Don't Save", "Cancel"])

        alert.buttons[2].performClick(nil)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!coordinator.isReviewing)
        #expect(model.dirtyDocumentPathsForWindowClose() == [document.path])
    }

    @Test func window_delegate_reviews_multiple_dirty_documents_in_tab_order() async throws {
        let model = AppModel(connections: MacConnectionManager())
        let first = try document(path: "Sources/First.swift", content: "let first = 1")
        let second = try document(path: "Sources/Second.swift", content: "let second = 2")
        model.openDocuments = [first, second]
        model.documentDrafts[first.path] = "let first = 10"
        model.activeDocument = second
        model.documentDraft = "let second = 20"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let coordinator = WorkspaceWindowCloseCoordinator(model: model)
        coordinator.attach(to: window)

        #expect(!coordinator.windowShouldClose(window))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        let firstAlert = try #require(coordinator.presentedAlert)
        #expect(firstAlert.messageText.contains("First.swift"))
        firstAlert.buttons[1].performClick(nil)

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        let secondAlert = try #require(coordinator.presentedAlert)
        #expect(secondAlert.messageText.contains("Second.swift"))
        secondAlert.buttons[2].performClick(nil)

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!coordinator.isReviewing)
        #expect(model.dirtyDocumentPathsForWindowClose() == [first.path, second.path])
    }

    @Test func window_close_bridge_preserves_the_existing_delegate_policy() {
        let model = AppModel(connections: MacConnectionManager())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let original = WindowCloseDelegateSpy()
        window.delegate = original
        let coordinator = WorkspaceWindowCloseCoordinator(model: model)
        coordinator.attach(to: window)

        #expect(!coordinator.windowShouldClose(window))
        #expect(original.shouldCloseCalls == 1)

        coordinator.detach()
        #expect(window.delegate === original)
    }

    private func document(path: String, content: String) throws -> TextDocument {
        let value: [String: Any] = [
            "path": path,
            "content": content,
            "revision": "rev-1",
            "size": content.utf8.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(TextDocument.self, from: data)
    }

    private func project(id: String) throws -> Project {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "name": "Project",
            "workspaces_enabled": false,
        ])
        return try JSONDecoder().decode(Project.self, from: data)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}

@MainActor
private final class WindowCloseDelegateSpy: NSObject, NSWindowDelegate {
    private(set) var shouldCloseCalls = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCalls += 1
        return false
    }
}
