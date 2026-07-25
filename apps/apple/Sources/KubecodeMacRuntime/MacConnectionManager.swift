#if os(macOS)
import Foundation
import Observation
import KubecodeCore
import KubecodeKit

private struct ProfileConnectionLoad {
    let id = UUID()
    let mode: ServerConnectionMode
    let task: Task<ServerSession, Error>
}

public enum ServerConnectionError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case missingCredential
    case unsupportedProtocol(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            String(localized: "The Server profile requires a valid HTTPS endpoint.")
        case .missingCredential:
            String(localized: "The Server profile has no bearer credential in Keychain.")
        case let .unsupportedProtocol(version):
            String.localizedStringWithFormat(
                String(localized: "The Server uses unsupported protocol version %lld."),
                version
            )
        }
    }
}

@MainActor
@Observable
public final class MacConnectionManager {
    typealias ProfileConnector = @MainActor @Sendable (ServerProfile) async throws -> ServerSession

    public let localRuntime: LocalRuntimeManager
    public let profiles: ServerProfileStore
    public let sshRuntime: SSHRuntimeManager
    public let projectAccess: ProjectAccessStore
    public let diagnostics: RuntimeDiagnosticLog
    public private(set) var localSession: ServerSession?
    public private(set) var sessions: [UUID: ServerSession] = [:]
    private var localConnectionTask: Task<ServerSession, Error>?
    private var profileConnectionTasks: [UUID: ProfileConnectionLoad] = [:]
    private let testingProfileConnector: ProfileConnector?
    private let httpsSession: URLSession

    public var hasManagedRuntimeActivity: Bool {
        if localConnectionTask != nil || localRuntime.state != .stopped {
            return true
        }
        if !sshRuntime.connectedProfileIDs.isEmpty {
            return true
        }
        return profileConnectionTasks.values.contains { $0.mode != .httpsAttached }
    }

    public init(
        localRuntime: LocalRuntimeManager? = nil,
        profiles: ServerProfileStore = ServerProfileStore(),
        sshRuntime: SSHRuntimeManager? = nil,
        projectAccess: ProjectAccessStore = ProjectAccessStore(),
        diagnostics: RuntimeDiagnosticLog = .live,
        httpsSession: URLSession = .shared
    ) {
        self.diagnostics = diagnostics
        self.localRuntime = localRuntime ?? LocalRuntimeManager(diagnostics: diagnostics)
        self.profiles = profiles
        self.sshRuntime = sshRuntime ?? SSHRuntimeManager(diagnostics: diagnostics)
        self.projectAccess = projectAccess
        self.httpsSession = httpsSession
        testingProfileConnector = nil
    }

    init(
        localRuntime: LocalRuntimeManager? = nil,
        profiles: ServerProfileStore = ServerProfileStore(),
        sshRuntime: SSHRuntimeManager? = nil,
        projectAccess: ProjectAccessStore = ProjectAccessStore(),
        diagnostics: RuntimeDiagnosticLog = .live,
        httpsSession: URLSession = .shared,
        testingProfileConnector: @escaping ProfileConnector
    ) {
        self.diagnostics = diagnostics
        self.localRuntime = localRuntime ?? LocalRuntimeManager(diagnostics: diagnostics)
        self.profiles = profiles
        self.sshRuntime = sshRuntime ?? SSHRuntimeManager(diagnostics: diagnostics)
        self.projectAccess = projectAccess
        self.httpsSession = httpsSession
        self.testingProfileConnector = testingProfileConnector
    }

    public func connectLocal() async throws -> ServerSession {
        if let localSession { return localSession }
        if let localConnectionTask { return try await localConnectionTask.value }
        let task = Task { [localRuntime] in
            ServerSession(client: try await localRuntime.start())
        }
        localConnectionTask = task
        do {
            let session = try await task.value
            localSession = session
            localConnectionTask = nil
            return session
        } catch {
            localConnectionTask = nil
            throw error
        }
    }

    public func connect(_ profile: ServerProfile) async throws -> ServerSession {
        if let existing = sessions[profile.id] { return existing }
        if let load = profileConnectionTasks[profile.id] {
            do {
                let session = try await load.task.value
                if profileConnectionTasks[profile.id]?.id == load.id {
                    sessions[profile.id] = session
                    profileConnectionTasks[profile.id] = nil
                }
                return sessions[profile.id] ?? session
            } catch {
                if profileConnectionTasks[profile.id]?.id == load.id {
                    profileConnectionTasks[profile.id] = nil
                }
                throw error
            }
        }
        let load = ProfileConnectionLoad(
            mode: profile.mode,
            task: Task { try await self.establishSession(for: profile) }
        )
        profileConnectionTasks[profile.id] = load
        do {
            let session = try await load.task.value
            if profileConnectionTasks[profile.id]?.id == load.id {
                sessions[profile.id] = session
                profileConnectionTasks[profile.id] = nil
            }
            return sessions[profile.id] ?? session
        } catch {
            if profileConnectionTasks[profile.id]?.id == load.id {
                profileConnectionTasks[profile.id] = nil
            }
            throw error
        }
    }

    private func establishSession(for profile: ServerProfile) async throws -> ServerSession {
        let source = RuntimeDiagnosticSource.profile(profile.id)
        try? diagnostics.append(
            "manager: connecting \(profile.mode.rawValue) profile",
            to: source
        )
        do {
            if let testingProfileConnector {
                let session = try await testingProfileConnector(profile)
                try? diagnostics.append("manager: profile connected", to: source)
                return session
            }
            let session: ServerSession
            switch profile.mode {
            case .localManaged:
                session = try await connectLocal()
            case .httpsAttached:
                guard let url = profile.url, url.scheme == "https" else {
                    throw ServerConnectionError.invalidEndpoint
                }
                guard let token = try profiles.credential(for: profile), !token.isEmpty else {
                    throw ServerConnectionError.missingCredential
                }
                session = ServerSession(client: RuntimeClient(
                    origin: url,
                    basePath: profile.basePath,
                    token: token,
                    session: httpsSession
                ))
            case .sshManaged:
                session = ServerSession(client: try await sshRuntime.start(profile: profile))
            }
            let discovery = try await session.discovery()
            guard discovery.protocolVersion == 1 else {
                throw ServerConnectionError.unsupportedProtocol(discovery.protocolVersion)
            }
            try? diagnostics.append("manager: profile connected with protocol 1", to: source)
            return session
        } catch {
            try? diagnostics.append(
                "manager: connection failed: \(error.localizedDescription)",
                to: source
            )
            throw error
        }
    }

    public func stopAll() {
        localConnectionTask?.cancel()
        localConnectionTask = nil
        profileConnectionTasks.values.forEach { $0.task.cancel() }
        profileConnectionTasks.removeAll()
        localRuntime.stop()
        sshRuntime.stopAll()
        localSession = nil
        sessions.removeAll()
    }
}
#endif
