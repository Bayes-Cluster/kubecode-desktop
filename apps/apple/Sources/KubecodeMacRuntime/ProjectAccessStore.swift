#if os(macOS)
import Foundation
import Observation

struct ProjectBookmarkResolution {
    let url: URL
    let isStale: Bool
}

private struct ActiveProjectAccess {
    let url: URL
    let isSecurityScoped: Bool
}

@MainActor
@Observable
public final class ProjectAccessStore {
    public private(set) var authorizedProjectIDs: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "projectAccessBookmarks.v1"
    @ObservationIgnored private let makeBookmark: (URL) throws -> Data
    @ObservationIgnored private let resolveBookmark: (Data) throws -> ProjectBookmarkResolution
    @ObservationIgnored private let startAccessing: (URL) -> Bool
    @ObservationIgnored private let stopAccessing: (URL) -> Void
    @ObservationIgnored private var bookmarks: [String: Data] = [:]
    @ObservationIgnored private var activeAccess: [String: ActiveProjectAccess] = [:]

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            makeBookmark: { url in
                try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            resolveBookmark: { data in
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return ProjectBookmarkResolution(url: url, isStale: isStale)
            },
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    init(
        defaults: UserDefaults,
        makeBookmark: @escaping (URL) throws -> Data,
        resolveBookmark: @escaping (Data) throws -> ProjectBookmarkResolution,
        startAccessing: @escaping (URL) -> Bool,
        stopAccessing: @escaping (URL) -> Void
    ) {
        self.defaults = defaults
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        restore()
    }

    public func isAuthorized(projectID: String) -> Bool {
        authorizedProjectIDs.contains(projectID)
    }

    public func authorize(projectID: String, url: URL) throws {
        let bookmark = try makeBookmark(url)
        release(projectID: projectID)
        let scoped = startAccessing(url)
        bookmarks[projectID] = bookmark
        activeAccess[projectID] = ActiveProjectAccess(url: url, isSecurityScoped: scoped)
        authorizedProjectIDs.insert(projectID)
        persist()
    }

    public func remove(projectID: String) {
        release(projectID: projectID)
        bookmarks.removeValue(forKey: projectID)
        authorizedProjectIDs.remove(projectID)
        persist()
    }

    private func restore() {
        bookmarks = defaults.data(forKey: key)
            .flatMap { try? PropertyListDecoder().decode([String: Data].self, from: $0) } ?? [:]
        var invalidIDs: [String] = []
        var refreshed = false
        for (projectID, bookmark) in bookmarks {
            do {
                let resolution = try resolveBookmark(bookmark)
                if resolution.isStale {
                    bookmarks[projectID] = try makeBookmark(resolution.url)
                    refreshed = true
                }
                let scoped = startAccessing(resolution.url)
                activeAccess[projectID] = ActiveProjectAccess(
                    url: resolution.url,
                    isSecurityScoped: scoped
                )
                authorizedProjectIDs.insert(projectID)
            } catch {
                invalidIDs.append(projectID)
            }
        }
        for projectID in invalidIDs { bookmarks.removeValue(forKey: projectID) }
        if refreshed || !invalidIDs.isEmpty { persist() }
    }

    private func release(projectID: String) {
        guard let access = activeAccess.removeValue(forKey: projectID),
              access.isSecurityScoped else { return }
        stopAccessing(access.url)
    }

    private func persist() {
        defaults.set(try? PropertyListEncoder().encode(bookmarks), forKey: key)
    }
}
#endif
