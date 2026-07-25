import Foundation
import Testing
@testable import KubecodeMacRuntime
import KubecodeKit

@Suite
@MainActor
struct ServerProfileStoreTests {
    @Test func profile_preferences_contain_no_bearer_value() throws {
        let suite = "ServerProfileStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reference = "profile-test-\(UUID())"
        let credentials = KeychainCredentialStore(service: "app.kubecode.desktop.tests.\(UUID())")
        defer { try? credentials.delete(reference: reference) }
        let store = ServerProfileStore(defaults: defaults, credentials: credentials)
        let profile = ServerProfile(
            name: "Research cluster",
            mode: .httpsAttached,
            url: URL(string: "https://cluster.example"),
            credentialReference: reference
        )

        try store.upsert(profile, bearerToken: "secret-token")

        let persisted = try #require(defaults.data(forKey: "serverProfiles.v1"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("secret-token"))
        #expect(store.profiles.first?.url?.scheme == "https")
        #expect(try store.credential(for: profile) == "secret-token")

        try store.remove(profile)
        #expect(try credentials.read(reference: reference) == nil)
    }
}
