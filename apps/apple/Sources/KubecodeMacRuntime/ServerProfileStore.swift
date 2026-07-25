#if os(macOS)
import Foundation
import Observation
import Security
import KubecodeKit

public enum CredentialStoreError: Error, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status): "Keychain operation failed (status \(status))."
        }
    }
}

public protocol ServerCredentialStoring: Sendable {
    func save(_ credential: String, reference: String) throws
    func read(reference: String) throws -> String?
    func delete(reference: String) throws
}

public struct KeychainCredentialStore: ServerCredentialStoring, Sendable {
    private let service: String

    public init(service: String = "app.kubecode.desktop.server-profile") {
        self.service = service
    }

    public func save(_ credential: String, reference: String) throws {
        let query = baseQuery(reference: reference)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(credential.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public func read(reference: String) throws -> String? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
    }
}

@MainActor
@Observable
public final class ServerProfileStore {
    public private(set) var profiles: [ServerProfile]
    private let defaults: UserDefaults
    private let key = "serverProfiles.v1"
    private let credentials: any ServerCredentialStoring

    public init(
        defaults: UserDefaults = .standard,
        credentials: any ServerCredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        profiles = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([ServerProfile].self, from: $0) } ?? []
    }

    public func upsert(_ profile: ServerProfile, bearerToken: String? = nil) throws {
        var profile = profile
        if let bearerToken {
            let reference = profile.credentialReference ?? profile.id.uuidString
            try credentials.save(bearerToken, reference: reference)
            profile.credentialReference = reference
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        persist()
    }

    public func credential(for profile: ServerProfile) throws -> String? {
        guard let reference = profile.credentialReference else { return nil }
        return try credentials.read(reference: reference)
    }

    public func remove(_ profile: ServerProfile) throws {
        if let reference = profile.credentialReference { try credentials.delete(reference: reference) }
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: key)
    }
}
#endif
