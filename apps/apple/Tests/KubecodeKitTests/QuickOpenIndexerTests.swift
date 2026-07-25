import Testing
@testable import KubecodeKit

@Suite
struct QuickOpenIndexerTests {
    @Test func search_is_bounded_by_visit_and_result_limits() async throws {
        let root = (0..<2_100).map { index in
            FileEntry(
                name: "Source\(index).swift",
                path: "Sources/Source\(index).swift",
                kind: "file",
                size: nil,
                hidden: false,
                ignored: false
            )
        }

        let results = try await QuickOpenIndexer.search(query: "source") { path in
            #expect(path.isEmpty)
            return root
        }

        #expect(results.count == 100)
        #expect(results.allSatisfy { Int($0.name.dropFirst("Source".count).dropLast(".swift".count))! < 2_000 })
    }

    @Test func search_does_not_descend_into_filtered_directories() async throws {
        actor Recorder {
            var paths: [String] = []
            func record(_ path: String) { paths.append(path) }
        }
        let recorder = Recorder()

        let results = try await QuickOpenIndexer.search(query: "keep") { path in
            await recorder.record(path)
            switch path {
            case "":
                return [
                    FileEntry(name: ".hidden", path: ".hidden", kind: "directory", size: nil, hidden: true, ignored: false),
                    FileEntry(name: "vendor", path: "vendor", kind: "directory", size: nil, hidden: false, ignored: true),
                    FileEntry(name: "node_modules", path: "node_modules", kind: "directory", size: nil, hidden: false, ignored: false, generated: true),
                    FileEntry(name: "Sources", path: "Sources", kind: "directory", size: nil, hidden: false, ignored: false),
                ]
            case "Sources":
                return [FileEntry(name: "Keep.swift", path: "Sources/Keep.swift", kind: "file", size: 10, hidden: false, ignored: false)]
            default:
                Issue.record("Unexpected traversal into \(path)")
                return []
            }
        }

        #expect(results.map(\.path) == ["Sources/Keep.swift"])
        #expect(await recorder.paths == ["", "Sources"])
    }
}
