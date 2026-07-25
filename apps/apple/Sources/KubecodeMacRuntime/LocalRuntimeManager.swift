#if os(macOS)
import Foundation
import Observation
import Security
import KubecodeKit

public enum RuntimeManagerState: Equatable, Sendable {
    case stopped
    case starting
    case ready(RuntimeReady)
    case failed(String)
}

public struct RuntimeLaunchConfiguration: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let stateDirectory: URL
    public let workspaceRoot: URL

    public init(executable: URL, stateDirectory: URL, workspaceRoot: URL) {
        self.executable = executable
        self.stateDirectory = stateDirectory
        self.workspaceRoot = workspaceRoot
        self.arguments = [
            "--host", "127.0.0.1",
            "--port", "0",
            "--workspace-root", workspaceRoot.path,
            "--state-dir", stateDirectory.path,
            "--api-only",
            "--access-token-stdin",
            "--ready-json",
        ]
    }
}

public enum LocalRuntimeError: Error, LocalizedError {
    case executableMissing
    case tokenGenerationFailed(OSStatus)
    case runtimeExited(Int32)
    case invalidReadyDocument(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing:
            String(localized: "The bundled Kubecode Runtime is missing. Set KUBECODE_SERVER_PATH for source development.")
        case let .tokenGenerationFailed(status):
            String.localizedStringWithFormat(
                String(localized: "Could not generate the local Runtime token (Security status %@)."),
                String(status)
            )
        case let .runtimeExited(status):
            String.localizedStringWithFormat(
                String(localized: "The Kubecode Runtime exited before it became ready (status %@)."),
                String(status)
            )
        case let .invalidReadyDocument(line):
            String.localizedStringWithFormat(
                String(localized: "The Kubecode Runtime returned an invalid readiness document: %@"),
                line
            )
        }
    }
}

@MainActor
@Observable
public final class LocalRuntimeManager {
    public private(set) var state: RuntimeManagerState = .stopped
    public private(set) var client: RuntimeClient?
    public let diagnostics: RuntimeDiagnosticLog

    private var process: Process?
    private var accessToken: String?
    private var standardErrorHandle: FileHandle?
    private var startupTask: Task<RuntimeClient, Error>?
    private let launchConfiguration: () throws -> RuntimeLaunchConfiguration

    public init(diagnostics: RuntimeDiagnosticLog = .live) {
        self.diagnostics = diagnostics
        launchConfiguration = { try Self.defaultLaunchConfiguration() }
    }

    init(
        diagnostics: RuntimeDiagnosticLog,
        launchConfiguration: @escaping () throws -> RuntimeLaunchConfiguration
    ) {
        self.diagnostics = diagnostics
        self.launchConfiguration = launchConfiguration
    }

    public func start() async throws -> RuntimeClient {
        if let client { return client }
        if let startupTask { return try await startupTask.value }
        let task = Task { try await launch() }
        startupTask = task
        defer { startupTask = nil }
        return try await task.value
    }

    private func launch() async throws -> RuntimeClient {
        if let client { return client }
        state = .starting
        appendManagerLog("manager: starting local Runtime")
        do {
            let configuration = try launchConfiguration()
            appendManagerLog("manager: resolved bundled Runtime for \(Self.runtimeArchitecture)")
            let token = try Self.generateAccessToken()
            let runtime = Process()
            let input = Pipe()
            let output = Pipe()

            try FileManager.default.createDirectory(
                at: configuration.stateDirectory,
                withIntermediateDirectories: true
            )
            try diagnostics.prepare(.local)
            let logHandle = try diagnostics.openForAppending(.local)

            runtime.executableURL = configuration.executable
            runtime.arguments = configuration.arguments
            runtime.standardInput = input
            runtime.standardOutput = output
            runtime.standardError = logHandle
            runtime.environment = Self.runtimeEnvironment(bundle: .main)

            process = runtime
            standardErrorHandle = logHandle
            try runtime.run()
            try input.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8))
            try input.fileHandleForWriting.close()

            let lineData = try await Self.readFirstLine(from: output.fileHandleForReading)
            guard runtime.isRunning else { throw LocalRuntimeError.runtimeExited(runtime.terminationStatus) }
            let line = String(decoding: lineData, as: UTF8.self)
            guard let ready = try? JSONDecoder().decode(RuntimeReady.self, from: lineData),
                  ready.type == "ready"
            else { throw LocalRuntimeError.invalidReadyDocument(line) }
            guard ready.protocolVersion == 1 else {
                throw LocalRuntimeError.invalidReadyDocument(
                    "Unsupported protocol \(ready.protocolVersion) from Runtime \(ready.serverVersion)"
                )
            }

            let client = RuntimeClient(origin: ready.origin, basePath: ready.basePath, token: token)
            self.accessToken = token
            self.client = client
            self.state = .ready(ready)
            appendManagerLog("manager: Runtime ready on private loopback")
            return client
        } catch {
            if process?.isRunning == true { process?.terminate() }
            process = nil
            client = nil
            accessToken = nil
            try? standardErrorHandle?.close()
            standardErrorHandle = nil
            state = .failed(error.localizedDescription)
            appendManagerLog("manager: startup failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func stop() {
        startupTask?.cancel()
        startupTask = nil
        process?.terminate()
        process = nil
        client = nil
        accessToken = nil
        try? standardErrorHandle?.close()
        standardErrorHandle = nil
        state = .stopped
    }

    public nonisolated static func defaultLaunchConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> RuntimeLaunchConfiguration {
        let executable: URL
        if let override = environment["KUBECODE_SERVER_PATH"], !override.isEmpty {
            executable = URL(fileURLWithPath: override)
        } else if let bundled = bundle.url(
            forResource: "kubecode-server",
            withExtension: nil,
            subdirectory: "Runtime/\(runtimeArchitecture)"
        ) {
            executable = bundled
        } else {
            throw LocalRuntimeError.executableMissing
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalRuntimeError.executableMissing
        }

        let applicationSupport = try applicationSupportDirectory(home: home)
        return RuntimeLaunchConfiguration(
            executable: executable,
            stateDirectory: applicationSupport.appending(path: "Runtime", directoryHint: .isDirectory),
            workspaceRoot: home
        )
    }

    public nonisolated static var runtimeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }

    private nonisolated static func applicationSupportDirectory(home: URL) throws -> URL {
        if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return directory.appending(path: "Kubecode", directoryHint: .isDirectory)
        }
        return home.appending(path: "Library/Application Support/Kubecode", directoryHint: .isDirectory)
    }

    private func appendManagerLog(_ message: String) {
        try? diagnostics.append(message, to: .local)
    }

    private nonisolated static func generateAccessToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw LocalRuntimeError.tokenGenerationFailed(status) }
        return Data(bytes).base64EncodedString()
    }

    nonisolated static func runtimeEnvironment(
        environment sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = sourceEnvironment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let preferredDirectories = [
            home.appending(path: ".local/bin").path,
            home.appending(path: ".npm-global/bin").path,
            home.appending(path: ".npm/bin").path,
            home.appending(path: ".bun/bin").path,
            home.appending(path: ".opencode/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        var seen = Set<String>()
        environment["PATH"] = (preferredDirectories + existingPath.split(separator: ":").map(String.init))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        environment["KUBECODE_DISABLE_LOGIN_SHELL_DISCOVERY"] = "1"
        let architecture = runtimeArchitecture
        if let node = bundle.url(
            forResource: "node", withExtension: nil, subdirectory: "Runtime/\(architecture)"
        ) {
            environment["KUBECODE_NODE_PATH"] = node.path
        }
        if let claude = bundle.url(
            forResource: "claude-agent-acp", withExtension: nil, subdirectory: "Runtime/shared"
        ) {
            environment["KUBECODE_CLAUDE_ACP_PATH"] = claude.path
        }
        if let codex = bundle.url(
            forResource: "codex-acp", withExtension: nil, subdirectory: "Runtime/shared"
        ) {
            environment["KUBECODE_CODEX_ACP_PATH"] = codex.path
        }
        return environment
    }

    private nonisolated static func readFirstLine(from handle: FileHandle) async throws -> Data {
        try await Task.detached {
            var line = Data()
            while line.count < 64 * 1024 {
                guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                    throw LocalRuntimeError.invalidReadyDocument(String(decoding: line, as: UTF8.self))
                }
                if byte.first == 0x0A { return line }
                line.append(byte)
            }
            throw LocalRuntimeError.invalidReadyDocument("readiness document exceeded 64 KiB")
        }.value
    }
}
#endif
