import Foundation
import Testing
import Darwin
@testable import KubecodeMacRuntime
import KubecodeKit

@Suite(.serialized)
struct LocalRuntimeManagerTests {
    @Test @MainActor func stop_terminates_the_app_owned_runtime_process() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appending(path: "kubecode-runtime-fixture")
        let tokenFile = temporary.appending(path: "stdin-token")
        let pidFile = temporary.appending(path: "runtime-pid")
        let script = """
        #!/bin/sh
        set -eu
        IFS= read -r token
        printf '%s' "$token" >'\(tokenFile.path)'
        printf '%s' "$$" >'\(pidFile.path)'
        printf '%s\n' '{"type":"ready","protocol_version":1,"server_version":"test","instance_id":"00000000-0000-0000-0000-000000000001","origin":"http://127.0.0.1:4242","base_path":"/"}'
        exec /usr/bin/tail -f /dev/null
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configuration = RuntimeLaunchConfiguration(
            executable: executable,
            stateDirectory: temporary.appending(path: "state", directoryHint: .isDirectory),
            workspaceRoot: temporary
        )
        let diagnostics = RuntimeDiagnosticLog(directory: temporary.appending(path: "logs"))
        let manager = LocalRuntimeManager(
            diagnostics: diagnostics,
            launchConfiguration: { configuration }
        )

        _ = try await manager.start()
        let runtimePID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(runtimePID, 0) == 0)
        #expect((try String(contentsOf: tokenFile, encoding: .utf8)).count >= 32)

        manager.stop()
        for _ in 0..<100 where kill(runtimePID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(kill(runtimePID, 0) != 0)
        #expect(manager.state == .stopped)
    }

    @Test func launch_configuration_uses_random_port_and_private_desktop_protocol() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appending(path: "kubecode-server")
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let configuration = try LocalRuntimeManager.defaultLaunchConfiguration(
            environment: ["KUBECODE_SERVER_PATH": executable.path],
            home: temporary
        )

        #expect(configuration.executable == executable)
        #expect(configuration.arguments.contains("--api-only"))
        #expect(configuration.arguments.contains("--access-token-stdin"))
        #expect(configuration.arguments.contains("--ready-json"))
        let portIndex = try #require(configuration.arguments.firstIndex(of: "--port"))
        #expect(configuration.arguments[portIndex + 1] == "0")
    }

    @Test func connection_modes_are_protocol_values_not_platform_branches() {
        #expect(ServerConnectionMode.allCasesForTesting == [.localManaged, .sshManaged, .httpsAttached])
    }

    @Test func runtime_path_restores_user_tool_locations_for_launch_services() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let environment = LocalRuntimeManager.runtimeEnvironment(
            environment: ["PATH": "/usr/bin:/bin"],
            bundle: .main,
            home: home
        )
        let paths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []

        #expect(paths.prefix(2) == ["/Users/example/.local/bin", "/Users/example/.npm-global/bin"])
        #expect(paths.contains("/opt/homebrew/bin"))
        #expect(paths.contains("/usr/local/bin"))
        #expect(paths.suffix(2) == ["/usr/bin", "/bin"])
        #expect(Set(paths).count == paths.count)
        #expect(environment["KUBECODE_DISABLE_LOGIN_SHELL_DISCOVERY"] == "1")
    }
}

private extension ServerConnectionMode {
    static var allCasesForTesting: [Self] { [.localManaged, .sshManaged, .httpsAttached] }
}
