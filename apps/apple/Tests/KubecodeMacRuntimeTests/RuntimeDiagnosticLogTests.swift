import Foundation
import Testing
@testable import KubecodeMacRuntime

@Suite
struct RuntimeDiagnosticLogTests {
    @Test func diagnostic_logs_are_scoped_to_local_or_profile_sources() {
        let directory = URL(fileURLWithPath: "/tmp/kubecode-diagnostics", isDirectory: true)
        let store = RuntimeDiagnosticLog(directory: directory)
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        #expect(store.url(for: .local).lastPathComponent == "runtime.log")
        #expect(store.url(for: .profile(first)).lastPathComponent == "profile-\(first.uuidString.lowercased()).log")
        #expect(store.url(for: .profile(first)) != store.url(for: .profile(second)))
    }

    @Test func recent_text_is_bounded_and_keeps_the_latest_complete_lines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeDiagnosticLog(directory: directory)
        let url = store.url(for: .local)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("first line\nsecond line\nthird line\nfourth line\n".utf8).write(to: url)

        #expect(try store.recentText(for: .local, maxBytes: 1_024, maxLines: 2) == "third line\nfourth line\n")
        #expect(try store.recentText(for: .local, maxBytes: 23, maxLines: 20) == "third line\nfourth line\n")
    }

    @Test func preparing_an_oversized_log_keeps_only_a_bounded_tail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeDiagnosticLog(directory: directory)
        let url = store.url(for: .local)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old\nkeep-one\nkeep-two\n".utf8).write(to: url)

        try store.prepare(.local, maximumFileBytes: 12, retainedBytes: 10)

        #expect(try String(contentsOf: url, encoding: .utf8) == "keep-two\n")
    }

    @Test func process_and_manager_handles_append_without_overwriting_each_other() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeDiagnosticLog(directory: directory)
        let processHandle = try store.openForAppending(.local)
        defer { try? processHandle.close() }

        try processHandle.write(contentsOf: Data("runtime: first\n".utf8))
        try store.append("manager: connected", to: .local)
        try processHandle.write(contentsOf: Data("runtime: second\n".utf8))

        let text = try store.recentText(for: .local)
        #expect(text.contains("runtime: first\n"))
        #expect(text.contains("manager: connected\n"))
        #expect(text.hasSuffix("runtime: second\n"))
    }

    @Test func manager_diagnostics_redact_credentials_and_endpoints() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeDiagnosticLog(directory: directory)

        try store.append(
            "failed https://runtime.example/private?token=query Authorization: Bearer secret token=another",
            to: .local
        )

        let text = try store.recentText(for: .local)
        #expect(text.contains("[endpoint]"))
        #expect(text.contains("[REDACTED]"))
        #expect(!text.contains("runtime.example"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("another"))
    }
}
