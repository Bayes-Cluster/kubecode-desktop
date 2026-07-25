#if os(macOS)
import Darwin
import Foundation
import Observation
import Security
import KubecodeKit

public enum SSHRuntimeError: Error, LocalizedError {
    case missingHost
    case tokenGenerationFailed(OSStatus)
    case invalidReadyDocument(String)
    case tunnelFailed
    case localPortUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingHost:
            String(localized: "The SSH profile requires a host from SSH config.")
        case let .tokenGenerationFailed(status):
            String.localizedStringWithFormat(
                String(localized: "Could not generate an SSH Runtime token (status %@)."),
                String(status)
            )
        case let .invalidReadyDocument(value):
            String.localizedStringWithFormat(
                String(localized: "The SSH Runtime returned invalid readiness data: %@"),
                value
            )
        case .tunnelFailed:
            String(localized: "The SSH loopback tunnel exited before the Runtime became reachable.")
        case .localPortUnavailable:
            String(localized: "Could not allocate a local loopback port for the SSH tunnel.")
        }
    }
}

public struct SSHLaunchPlan: Equatable, Sendable {
    public let host: String
    public let remoteCommand: String

    public static func make(profile: ServerProfile) throws -> SSHLaunchPlan {
        guard let host = profile.sshHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            throw SSHRuntimeError.missingHost
        }
        let executable = profile.remoteExecutable?.isEmpty == false
            ? profile.remoteExecutable! : "kubecode-server"
        let workspace = profile.remoteWorkspaceRoot?.isEmpty == false
            ? profile.remoteWorkspaceRoot! : "."
        let arguments = [
            executable,
            "--host", "127.0.0.1",
            "--port", "0",
            "--workspace-root", workspace,
            "--state-dir", ".local/share/kubecode",
            "--api-only",
            "--access-token-stdin",
            "--ready-json",
        ]
        return SSHLaunchPlan(host: host, remoteCommand: arguments.map(shellQuote).joined(separator: " "))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class SSHRuntimeHandle {
    let runtime: Process
    let tunnel: Process
    let logHandle: FileHandle

    init(runtime: Process, tunnel: Process, logHandle: FileHandle) {
        self.runtime = runtime
        self.tunnel = tunnel
        self.logHandle = logHandle
    }

    func stop() {
        if tunnel.isRunning { tunnel.terminate() }
        if runtime.isRunning { runtime.terminate() }
        try? logHandle.close()
    }
}

@MainActor
@Observable
public final class SSHRuntimeManager {
    public private(set) var connectedProfileIDs: Set<UUID> = []
    public let diagnostics: RuntimeDiagnosticLog
    private var handles: [UUID: SSHRuntimeHandle] = [:]
    private let sshExecutable: URL
    private let tunnelStartupDelay: Duration

    public init(
        diagnostics: RuntimeDiagnosticLog = .live,
        sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        tunnelStartupDelay: Duration = .milliseconds(250)
    ) {
        self.diagnostics = diagnostics
        self.sshExecutable = sshExecutable
        self.tunnelStartupDelay = tunnelStartupDelay
    }

    public func start(profile: ServerProfile) async throws -> RuntimeClient {
        let plan = try SSHLaunchPlan.make(profile: profile)
        let source = RuntimeDiagnosticSource.profile(profile.id)
        try? diagnostics.append("ssh: starting managed Runtime", to: source)
        try diagnostics.prepare(source)
        let logHandle = try diagnostics.openForAppending(source)
        let token = try Self.generateToken()
        let remote = Process()
        var tunnel: Process?
        let input = Pipe()
        let output = Pipe()
        do {
            remote.executableURL = sshExecutable
            remote.arguments = ["-T", plan.host, plan.remoteCommand]
            remote.standardInput = input
            remote.standardOutput = output
            remote.standardError = logHandle
            try remote.run()
            try input.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8))
            try input.fileHandleForWriting.close()

            let readyData = try await Self.readFirstLine(from: output.fileHandleForReading)
            guard let ready = try? JSONDecoder().decode(RuntimeReady.self, from: readyData),
                  ready.type == "ready",
                  let remotePort = ready.origin.port
            else {
                throw SSHRuntimeError.invalidReadyDocument(String(decoding: readyData, as: UTF8.self))
            }

            let localPort = try Self.availableLoopbackPort()
            let tunnelProcess = Process()
            tunnel = tunnelProcess
            tunnelProcess.executableURL = sshExecutable
            tunnelProcess.arguments = [
                "-N", "-T",
                "-o", "ExitOnForwardFailure=yes",
                "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
                plan.host,
            ]
            tunnelProcess.standardError = logHandle
            try tunnelProcess.run()
            try await Task.sleep(for: tunnelStartupDelay)
            guard tunnelProcess.isRunning else { throw SSHRuntimeError.tunnelFailed }

            handles[profile.id] = SSHRuntimeHandle(
                runtime: remote,
                tunnel: tunnelProcess,
                logHandle: logHandle
            )
            connectedProfileIDs.insert(profile.id)
            try? diagnostics.append("ssh: Runtime and loopback tunnel ready", to: source)
            return RuntimeClient(
                origin: URL(string: "http://127.0.0.1:\(localPort)")!,
                basePath: ready.basePath,
                token: token
            )
        } catch {
            if tunnel?.isRunning == true { tunnel?.terminate() }
            if remote.isRunning { remote.terminate() }
            try? logHandle.close()
            try? diagnostics.append("ssh: startup failed: \(error.localizedDescription)", to: source)
            throw error
        }
    }

    public func stop(profileID: UUID) {
        handles.removeValue(forKey: profileID)?.stop()
        connectedProfileIDs.remove(profileID)
        try? diagnostics.append("ssh: stopped managed Runtime", to: .profile(profileID))
    }

    public func stopAll() {
        let profileIDs = Array(handles.keys)
        handles.values.forEach { $0.stop() }
        handles.removeAll()
        connectedProfileIDs.removeAll()
        for profileID in profileIDs {
            try? diagnostics.append("ssh: stopped managed Runtime", to: .profile(profileID))
        }
    }

    private nonisolated static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw SSHRuntimeError.tokenGenerationFailed(status) }
        return Data(bytes).base64EncodedString()
    }

    private nonisolated static func readFirstLine(from handle: FileHandle) async throws -> Data {
        try await Task.detached {
            var line = Data()
            while line.count < 64 * 1024 {
                guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                    throw SSHRuntimeError.invalidReadyDocument(String(decoding: line, as: UTF8.self))
                }
                if byte.first == 0x0A { return line }
                line.append(byte)
            }
            throw SSHRuntimeError.invalidReadyDocument("readiness document exceeded 64 KiB")
        }.value
    }

    private nonisolated static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SSHRuntimeError.localPortUnavailable }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SSHRuntimeError.localPortUnavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw SSHRuntimeError.localPortUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }
}
#endif
