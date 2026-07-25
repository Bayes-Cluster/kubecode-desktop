import Foundation
import Testing
import Darwin
import KubecodeCore
@testable import KubecodeMacRuntime
import KubecodeKit

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

@Suite(.serialized)
struct SSHRuntimeManagerTests {
    @Test func launch_plan_uses_ssh_config_host_and_quotes_remote_values() throws {
        let profile = ServerProfile(
            name: "GPU host",
            mode: .sshManaged,
            sshHost: "euler-gpu",
            remoteExecutable: "/opt/Kubecode Runtime/bin/kubecode-server",
            remoteWorkspaceRoot: "/work/user's project"
        )

        let plan = try SSHLaunchPlan.make(profile: profile)

        #expect(plan.host == "euler-gpu")
        #expect(plan.remoteCommand.contains("'/opt/Kubecode Runtime/bin/kubecode-server'"))
        #expect(plan.remoteCommand.contains("'/work/user'\\''s project'"))
        #expect(plan.remoteCommand.contains("'--access-token-stdin'"))
        #expect(!plan.remoteCommand.contains("Bearer"))
    }

    @Test @MainActor func managed_profile_launches_runtime_tunnel_and_discovers_protocol() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appending(path: "ssh-fixture")
        let runtimeArguments = temporary.appending(path: "runtime-arguments")
        let tunnelArguments = temporary.appending(path: "tunnel-arguments")
        let tokenFile = temporary.appending(path: "stdin-token")
        let runtimePIDFile = temporary.appending(path: "runtime-pid")
        let discovery = #"{"protocol_version":1,"server_version":"test","api_base":"/api/v1","authentication":"bearer","capabilities":["projects"]}"#
        let script = """
        #!/bin/sh
        set -eu
        if [ "$1" = "-T" ]; then
          printf '%s\n' "$@" >\(shellQuote(runtimeArguments.path))
          IFS= read -r token
          printf '%s' "$token" >\(shellQuote(tokenFile.path))
          printf '%s' "$$" >\(shellQuote(runtimePIDFile.path))
          printf '%s\n' '{"type":"ready","protocol_version":1,"server_version":"test","instance_id":"00000000-0000-0000-0000-000000000001","origin":"http://127.0.0.1:4242","base_path":"/"}'
          exec /usr/bin/tail -f /dev/null
        fi
        printf '%s\n' "$@" >\(shellQuote(tunnelArguments.path))
        forward=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-L" ]; then
            shift
            forward="$1"
          fi
          shift
        done
        local_port="$(printf '%s' "$forward" | /usr/bin/awk -F: '{print $2}')"
        body='\(discovery)'
        length="$(printf '%s' "$body" | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
        {
          printf 'HTTP/1.1 200 OK\r\n'
          printf 'Content-Type: application/json\r\n'
          printf 'Content-Length: %s\r\n' "$length"
          printf 'Connection: close\r\n\r\n'
          printf '%s' "$body"
        } | /usr/bin/nc -l 127.0.0.1 "$local_port" >/dev/null
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let diagnostics = RuntimeDiagnosticLog(directory: temporary.appending(path: "logs"))
        let sshRuntime = SSHRuntimeManager(
            diagnostics: diagnostics,
            sshExecutable: executable,
            tunnelStartupDelay: .milliseconds(50)
        )
        let manager = MacConnectionManager(sshRuntime: sshRuntime, diagnostics: diagnostics)
        let profile = ServerProfile(
            name: "GPU host",
            mode: .sshManaged,
            sshHost: "gpu-from-config",
            remoteExecutable: "/opt/kubecode server",
            remoteWorkspaceRoot: "/work/project"
        )

        let session = try await manager.connect(profile)

        #expect(manager.sessions[profile.id] === session)
        #expect(sshRuntime.connectedProfileIDs == [profile.id])
        #expect(manager.hasManagedRuntimeActivity)
        let token = try String(contentsOf: tokenFile, encoding: .utf8)
        #expect(token.count >= 32)
        let runtimeCommand = try String(contentsOf: runtimeArguments, encoding: .utf8)
        #expect(runtimeCommand.contains("gpu-from-config"))
        #expect(runtimeCommand.contains("'/opt/kubecode server'"))
        #expect(!runtimeCommand.contains(token))
        let tunnelCommand = try String(contentsOf: tunnelArguments, encoding: .utf8)
        #expect(tunnelCommand.contains("-L"))
        #expect(tunnelCommand.contains(":127.0.0.1:4242"))
        #expect(tunnelCommand.contains("gpu-from-config"))

        let runtimePID = try #require(Int32(String(
            contentsOf: runtimePIDFile,
            encoding: .utf8
        )))
        manager.stopAll()
        #expect(manager.hasManagedRuntimeActivity == false)
        #expect(sshRuntime.connectedProfileIDs.isEmpty)
        for _ in 0..<100 where kill(runtimePID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(runtimePID, 0) != 0)
    }
}
