import AppKit
import Foundation
import UserNotifications
import KubecodeKit

enum WorkspaceNotificationCategory: String, CaseIterable, Sendable {
    case completion
    case attention
    case error

    static func classify(_ event: WorkspaceEvent) -> Self? {
        switch event.kind {
        case "permission_requested", "elicitation_requested":
            return .attention
        case "run_completed":
            switch event.payload["status"]?.stringValue {
            case nil, "completed": return .completion
            case "failed", "timed_out", "interrupted": return .error
            default: return nil
            }
        default:
            return nil
        }
    }
}

enum WorkspaceNotificationMode: String, Sendable {
    case off
    case unfocused
    case always
}

enum WorkspaceNotificationSound: String, Sendable {
    case system
    case none
}

struct WorkspaceNotificationPreferences: Equatable, Sendable {
    static let modeKey = "notifications.mode"
    static let completionEnabledKey = "notifications.completed"
    static let attentionEnabledKey = "notifications.attention"
    static let errorEnabledKey = "notifications.errors"
    static let legacySoundKey = "notifications.sound"
    static let completionSoundKey = "notifications.sound.completion"
    static let attentionSoundKey = "notifications.sound.attention"
    static let errorSoundKey = "notifications.sound.error"

    let mode: WorkspaceNotificationMode
    let enabled: [WorkspaceNotificationCategory: Bool]
    let sound: [WorkspaceNotificationCategory: WorkspaceNotificationSound]

    init(defaults: UserDefaults = .standard) {
        mode = WorkspaceNotificationMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .always
        enabled = Dictionary(uniqueKeysWithValues: WorkspaceNotificationCategory.allCases.map { category in
            let key = switch category {
            case .completion: Self.completionEnabledKey
            case .attention: Self.attentionEnabledKey
            case .error: Self.errorEnabledKey
            }
            return (category, defaults.object(forKey: key) as? Bool ?? true)
        })
        let legacySound = defaults.object(forKey: Self.legacySoundKey) as? Bool
        sound = Dictionary(uniqueKeysWithValues: WorkspaceNotificationCategory.allCases.map { category in
            let key = switch category {
            case .completion: Self.completionSoundKey
            case .attention: Self.attentionSoundKey
            case .error: Self.errorSoundKey
            }
            let fallback: WorkspaceNotificationSound = legacySound == false ? .none : .system
            return (category, WorkspaceNotificationSound(rawValue: defaults.string(forKey: key) ?? "") ?? fallback)
        })
    }

    func shouldNotify(category: WorkspaceNotificationCategory, appIsActive: Bool) -> Bool {
        guard enabled[category] == true, mode != .off else { return false }
        return mode == .always || !appIsActive
    }
}

@MainActor
protocol WorkspaceNotificationScheduling: AnyObject {
    func add(_ request: UNNotificationRequest)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
private final class UserNotificationScheduler: WorkspaceNotificationScheduling {
    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

@MainActor
final class WorkspaceNotificationCoordinator {
    static let shared = WorkspaceNotificationCoordinator()

    private static let maximumRememberedEvents = 2_048
    private let scheduler: WorkspaceNotificationScheduling
    private let defaults: UserDefaults
    private var processedEvents: Set<String> = []
    private var processedEventOrder: [String] = []

    init(
        scheduler: WorkspaceNotificationScheduling = UserNotificationScheduler(),
        defaults: UserDefaults = .standard
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
    }

    func handle(
        _ event: WorkspaceEvent,
        serverID: UUID,
        serverName: String,
        projectName: String?,
        conversationTitle: String?,
        agentName: String?,
        appIsActive: Bool
    ) {
        let eventKey = "\(serverID.uuidString):\(event.id)"
        guard remember(eventKey) else { return }
        if ["permission_resolved", "elicitation_resolved"].contains(event.kind),
           let conversationID = event.conversationID {
            scheduler.removeDeliveredNotifications(withIdentifiers: [
                notificationIdentifier(
                    serverID: serverID,
                    category: .attention,
                    conversationID: conversationID
                ),
            ])
            return
        }
        guard let category = WorkspaceNotificationCategory.classify(event),
              let projectID = event.projectID,
              let conversationID = event.conversationID
        else { return }
        let preferences = WorkspaceNotificationPreferences(defaults: defaults)
        guard preferences.shouldNotify(category: category, appIsActive: appIsActive) else { return }

        let content = UNMutableNotificationContent()
        let safeAgentName = agentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeConversationTitle = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = "\(safeAgentName?.isEmpty == false ? safeAgentName! : String(localized: "Agent")) · \(safeConversationTitle?.isEmpty == false ? safeConversationTitle! : String(localized: "Untitled Session"))"
        content.body = notificationBody(
            category: category,
            projectName: projectName?.isEmpty == false ? projectName! : serverName
        )
        if preferences.sound[category] == .system { content.sound = .default }
        content.userInfo = [
            "server_session_id": serverID.uuidString,
            "project_id": projectID,
            "conversation_id": conversationID,
        ]
        let identifier = notificationIdentifier(
            serverID: serverID,
            category: category,
            conversationID: conversationID
        )
        scheduler.removeDeliveredNotifications(withIdentifiers: [identifier])
        scheduler.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func notificationBody(
        category: WorkspaceNotificationCategory,
        projectName: String
    ) -> String {
        switch category {
        case .attention:
            String.localizedStringWithFormat(String(localized: "%@ needs your attention"), projectName)
        case .completion:
            String.localizedStringWithFormat(String(localized: "%@ finished an Agent task"), projectName)
        case .error:
            String.localizedStringWithFormat(String(localized: "%@ encountered an Agent error"), projectName)
        }
    }

    private func notificationIdentifier(
        serverID: UUID,
        category: WorkspaceNotificationCategory,
        conversationID: String
    ) -> String {
        "kubecode:\(serverID.uuidString):\(category.rawValue):\(conversationID)"
    }

    private func remember(_ key: String) -> Bool {
        guard processedEvents.insert(key).inserted else { return false }
        processedEventOrder.append(key)
        if processedEventOrder.count > Self.maximumRememberedEvents {
            processedEvents.remove(processedEventOrder.removeFirst())
        }
        return true
    }
}
