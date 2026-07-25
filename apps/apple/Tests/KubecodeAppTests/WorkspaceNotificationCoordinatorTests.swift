import Foundation
import Testing
import UserNotifications
@testable import KubecodeApp
import KubecodeKit

@Suite(.serialized)
@MainActor
struct WorkspaceNotificationCoordinatorTests {
    @Test func durable_events_map_to_browser_compatible_categories() throws {
        #expect(WorkspaceNotificationCategory.classify(try event(id: 1, kind: "permission_requested")) == .attention)
        #expect(WorkspaceNotificationCategory.classify(try event(id: 2, kind: "elicitation_requested")) == .attention)
        #expect(WorkspaceNotificationCategory.classify(try event(id: 3, kind: "run_completed")) == .completion)
        #expect(WorkspaceNotificationCategory.classify(try event(id: 4, kind: "run_completed", status: "completed")) == .completion)
        #expect(WorkspaceNotificationCategory.classify(try event(id: 5, kind: "run_completed", status: "failed")) == .error)
        #expect(WorkspaceNotificationCategory.classify(try event(id: 6, kind: "run_completed", status: "timed_out")) == .error)
        #expect(WorkspaceNotificationCategory.classify(try event(id: 7, kind: "run_completed", status: "cancelled")) == nil)
        #expect(WorkspaceNotificationCategory.classify(try event(id: 8, kind: "error")) == nil)
    }

    @Test func focus_mode_and_category_preferences_gate_delivery() throws {
        let defaults = try defaults()
        defaults.set("unfocused", forKey: WorkspaceNotificationPreferences.modeKey)
        defaults.set(false, forKey: WorkspaceNotificationPreferences.completionEnabledKey)
        let preferences = WorkspaceNotificationPreferences(defaults: defaults)

        #expect(!preferences.shouldNotify(category: .attention, appIsActive: true))
        #expect(preferences.shouldNotify(category: .attention, appIsActive: false))
        #expect(!preferences.shouldNotify(category: .completion, appIsActive: false))
    }

    @Test func shared_coordinator_delivers_each_server_event_once_with_category_sound() throws {
        let defaults = try defaults()
        defaults.set("always", forKey: WorkspaceNotificationPreferences.modeKey)
        defaults.set("none", forKey: WorkspaceNotificationPreferences.attentionSoundKey)
        let scheduler = RecordingNotificationScheduler()
        let coordinator = WorkspaceNotificationCoordinator(scheduler: scheduler, defaults: defaults)
        let serverID = UUID()
        let request = try event(id: 42, kind: "permission_requested")

        coordinator.handle(
            request,
            serverID: serverID,
            serverName: "Local Runtime",
            projectName: "Kubecode",
            conversationTitle: "Fix notifications",
            agentName: "Claude Code",
            appIsActive: true
        )
        coordinator.handle(
            request,
            serverID: serverID,
            serverName: "Local Runtime",
            projectName: "Kubecode",
            conversationTitle: "Fix notifications",
            agentName: "Claude Code",
            appIsActive: true
        )

        let delivered = try #require(scheduler.requests.first)
        #expect(scheduler.requests.count == 1)
        #expect(delivered.content.title == "Claude Code · Fix notifications")
        #expect(delivered.content.body == "Kubecode needs your attention")
        #expect(delivered.content.sound == nil)
        #expect(delivered.content.userInfo["project_id"] as? String == "project-1")
        #expect(delivered.content.userInfo["conversation_id"] as? String == "session-1")
    }

    @Test func resolving_attention_removes_the_stable_delivered_notification() throws {
        let defaults = try defaults()
        let scheduler = RecordingNotificationScheduler()
        let coordinator = WorkspaceNotificationCoordinator(scheduler: scheduler, defaults: defaults)
        let serverID = UUID()
        coordinator.handle(
            try event(id: 1, kind: "permission_requested"),
            serverID: serverID,
            serverName: "Remote",
            projectName: "Project",
            conversationTitle: nil,
            agentName: "Codex",
            appIsActive: false
        )
        coordinator.handle(
            try event(id: 2, kind: "permission_resolved"),
            serverID: serverID,
            serverName: "Remote",
            projectName: "Project",
            conversationTitle: nil,
            agentName: "Codex",
            appIsActive: false
        )

        #expect(scheduler.removedIdentifiers.last == scheduler.requests.first?.identifier)
        #expect(scheduler.removedIdentifiers.count == 2)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "WorkspaceNotificationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func event(id: Int, kind: String, status: String? = nil) throws -> WorkspaceEvent {
        let statusField = status.map { #""status":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(WorkspaceEvent.self, from: Data(#"""
        {
          "id":\#(id),
          "kind":"\#(kind)",
          "project_id":"project-1",
          "conversation_id":"session-1",
          "run_id":"run-1",
          "payload":{\#(statusField)},
          "created_at":"2026-07-23T00:00:00Z"
        }
        """#.utf8))
    }
}

@MainActor
private final class RecordingNotificationScheduler: WorkspaceNotificationScheduling {
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []

    func add(_ request: UNNotificationRequest) {
        requests.append(request)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}
