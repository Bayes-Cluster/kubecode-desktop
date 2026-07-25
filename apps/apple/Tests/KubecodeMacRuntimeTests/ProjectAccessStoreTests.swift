import Foundation
import Testing
@testable import KubecodeMacRuntime

@Suite
@MainActor
struct ProjectAccessStoreTests {
    @Test func stale_bookmark_refresh_failure_does_not_publish_authorized_state() throws {
        let suite = "ProjectAccessStoreStaleTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(fileURLWithPath: "/Users/example/Project", isDirectory: true)
        let initial = ProjectAccessStore(
            defaults: defaults,
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { _ in ProjectBookmarkResolution(url: url, isStale: false) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        try initial.authorize(projectID: "project-stale", url: url)

        let restored = ProjectAccessStore(
            defaults: defaults,
            makeBookmark: { _ in throw CocoaError(.fileWriteUnknown) },
            resolveBookmark: { _ in ProjectBookmarkResolution(url: url, isStale: true) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        #expect(!restored.isAuthorized(projectID: "project-stale"))
    }

    @Test func system_security_scoped_bookmarks_round_trip_for_a_directory() throws {
        let suite = "ProjectAccessStoreSystemTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectAccessStore(defaults: defaults)
        try store.authorize(projectID: "project-system", url: directory)
        let restored = ProjectAccessStore(defaults: defaults)

        #expect(store.isAuthorized(projectID: "project-system"))
        #expect(restored.isAuthorized(projectID: "project-system"))
    }

    @Test func bookmarks_restore_before_runtime_launch_and_release_on_removal() throws {
        let suite = "ProjectAccessStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let projectURL = URL(fileURLWithPath: "/Users/example/Downloads/Project", isDirectory: true)
        var started: [URL] = []
        var stopped: [URL] = []
        let makeBookmark: (URL) throws -> Data = { Data($0.path.utf8) }
        let resolveBookmark: (Data) throws -> ProjectBookmarkResolution = { data in
            ProjectBookmarkResolution(
                url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true),
                isStale: false
            )
        }

        let store = ProjectAccessStore(
            defaults: defaults,
            makeBookmark: makeBookmark,
            resolveBookmark: resolveBookmark,
            startAccessing: { started.append($0); return true },
            stopAccessing: { stopped.append($0) }
        )
        try store.authorize(projectID: "project-1", url: projectURL)

        #expect(store.isAuthorized(projectID: "project-1"))
        #expect(started == [projectURL])

        let restored = ProjectAccessStore(
            defaults: defaults,
            makeBookmark: makeBookmark,
            resolveBookmark: resolveBookmark,
            startAccessing: { started.append($0); return true },
            stopAccessing: { stopped.append($0) }
        )
        #expect(restored.isAuthorized(projectID: "project-1"))
        #expect(started == [projectURL, projectURL])

        restored.remove(projectID: "project-1")
        #expect(!restored.isAuthorized(projectID: "project-1"))
        #expect(stopped == [projectURL])
    }
}
