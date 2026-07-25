import Foundation

@MainActor
final class SessionDraftStore {
    static let relaunchPersistencePreferenceKey = "privacy.restoreSessionDrafts"
    static let persistencePreferenceDidChange = Notification.Name(
        "SessionDraftStore.persistencePreferenceDidChange"
    )

    private static let storagePrefix = "session.draft.v1."
    private let defaults: UserDefaults
    private var memory: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(windowID: String, sessionID: String) -> String {
        let key = storageKey(windowID: windowID, sessionID: sessionID)
        if let draft = memory[key] { return draft }
        guard defaults.bool(forKey: Self.relaunchPersistencePreferenceKey),
              let draft = defaults.string(forKey: key)
        else { return "" }
        memory[key] = draft
        return draft
    }

    func save(_ draft: String, windowID: String, sessionID: String) {
        let key = storageKey(windowID: windowID, sessionID: sessionID)
        if draft.isEmpty {
            memory.removeValue(forKey: key)
            defaults.removeObject(forKey: key)
            return
        }
        memory[key] = draft
        if defaults.bool(forKey: Self.relaunchPersistencePreferenceKey) {
            defaults.set(draft, forKey: key)
        }
    }

    func clear(windowID: String, sessionID: String) {
        save("", windowID: windowID, sessionID: sessionID)
    }

    static func setRelaunchPersistenceEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: relaunchPersistencePreferenceKey)
        if !enabled {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(storagePrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        NotificationCenter.default.post(name: persistencePreferenceDidChange, object: nil)
    }

    private func storageKey(windowID: String, sessionID: String) -> String {
        Self.storagePrefix + encodedKeyPart(windowID) + "." + encodedKeyPart(sessionID)
    }

    private func encodedKeyPart(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
