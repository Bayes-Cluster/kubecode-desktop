import Foundation
import Testing
import KubecodeCore
import KubecodeKit
@testable import KubecodeMacRuntime

private final class ProfileURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class InMemoryCredentialStore: ServerCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ credential: String, reference: String) throws {
        lock.withLock { values[reference] = credential }
    }

    func read(reference: String) throws -> String? {
        lock.withLock { values[reference] }
    }

    func delete(reference: String) throws {
        lock.withLock { values[reference] = nil }
    }
}

private actor DelayedProfileConnector {
    private let session: ServerSession
    private var requests = 0

    init(session: ServerSession) {
        self.session = session
    }

    func connect() async -> ServerSession {
        requests += 1
        try? await Task.sleep(for: .milliseconds(100))
        return session
    }

    func count() -> Int { requests }
}

@Suite(.serialized)
@MainActor
struct MacConnectionManagerTests {
    @Test func https_profile_uses_stored_bearer_for_discovery_and_resource_requests() async throws {
        let suite = "MacConnectionManagerTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = InMemoryCredentialStore()
        let profiles = ServerProfileStore(defaults: defaults, credentials: credentials)
        let profile = ServerProfile(
            name: "Kubeflow Runtime",
            mode: .httpsAttached,
            url: URL(string: "https://runtime.example"),
            basePath: "gateway/kubecode"
        )
        try profiles.upsert(profile, bearerToken: "profile-secret")
        let storedProfile = try #require(profiles.profiles.first)
        let persisted = try #require(defaults.data(forKey: "serverProfiles.v1"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("profile-secret"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileURLProtocol.self]
        ProfileURLProtocol.handler = { request in
            switch request.url?.path {
            case "/gateway/kubecode/.well-known/kubecode":
                #expect(request.url?.scheme == "https")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let body = #"{"protocol_version":1,"server_version":"0.1.1","api_base":"/api/v1","authentication":"bearer","capabilities":["projects"]}"#
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(body.utf8)
                )
            case "/gateway/kubecode/api/v1/projects":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer profile-secret")
                let body = #"[{"id":"project-1","name":"Demo","workspaces_enabled":false}]"#
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(body.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }

        let manager = MacConnectionManager(
            profiles: profiles,
            httpsSession: URLSession(configuration: configuration)
        )
        let session = try await manager.connect(storedProfile)
        let projects = try await session.listProjects()

        #expect(projects.map(\.id) == ["project-1"])
        #expect(projects.map(\.name) == ["Demo"])
        #expect(projects.map(\.workspacesEnabled) == [false])
        #expect(manager.sessions[profile.id] === session)
        #expect(manager.hasManagedRuntimeActivity == false)
    }

    @Test func https_profile_rejects_non_tls_endpoint_before_connecting() async throws {
        let profile = ServerProfile(
            name: "Unsafe Runtime",
            mode: .httpsAttached,
            url: URL(string: "http://runtime.example")
        )
        let manager = MacConnectionManager()

        await #expect(throws: ServerConnectionError.invalidEndpoint) {
            try await manager.connect(profile)
        }
    }

    @Test func profile_connection_failures_write_scoped_diagnostics_without_endpoint_data() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = RuntimeDiagnosticLog(directory: directory)
        let profile = ServerProfile(
            name: "Private Server",
            mode: .httpsAttached,
            url: URL(string: "https://secret.example/path?token=do-not-log")
        )
        let manager = MacConnectionManager(
            diagnostics: diagnostics,
            testingProfileConnector: { _ in throw URLError(.cannotConnectToHost) }
        )

        await #expect(throws: URLError.self) {
            try await manager.connect(profile)
        }
        let log = try diagnostics.recentText(for: .profile(profile.id))
        #expect(log.contains("manager: connecting https_attached profile"))
        #expect(log.contains("manager: connection failed"))
        #expect(!log.contains("secret.example"))
        #expect(!log.contains("do-not-log"))
    }

    @Test func concurrent_profile_connections_share_one_server_session() async throws {
        let profile = ServerProfile(
            name: "Remote Runtime",
            mode: .httpsAttached,
            url: URL(string: "https://runtime.example")
        )
        let expected = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token")
        )
        let connector = DelayedProfileConnector(session: expected)
        let manager = MacConnectionManager(testingProfileConnector: { _ in
            await connector.connect()
        })

        async let first = manager.connect(profile)
        async let second = manager.connect(profile)
        try await Task.sleep(for: .milliseconds(10))
        #expect(manager.hasManagedRuntimeActivity == false)
        let (firstSession, secondSession) = try await (first, second)
        #expect(await connector.count() == 1)
        #expect(firstSession === expected)
        #expect(secondSession === expected)
        #expect(manager.sessions[profile.id] === expected)
    }

    @Test func in_flight_managed_profile_requires_shutdown_confirmation() async throws {
        let profile = ServerProfile(
            name: "GPU host",
            mode: .sshManaged,
            sshHost: "gpu-from-config"
        )
        let expected = ServerSession(
            client: RuntimeClient(origin: URL(string: "https://runtime.example")!, token: "token")
        )
        let connector = DelayedProfileConnector(session: expected)
        let manager = MacConnectionManager(testingProfileConnector: { _ in
            await connector.connect()
        })

        async let session = manager.connect(profile)
        try await Task.sleep(for: .milliseconds(10))

        #expect(manager.hasManagedRuntimeActivity)
        _ = try await session
    }
}
