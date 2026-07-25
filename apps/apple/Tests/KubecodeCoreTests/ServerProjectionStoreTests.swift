import Testing
@testable import KubecodeCore

@Suite
@MainActor
struct ServerProjectionStoreTests {
    @Test func clearing_project_resources_preserves_server_projects_and_agents() {
        let store = ServerProjectionStore()
        store.clearProjectResources()

        #expect(store.conversations.isEmpty)
        #expect(store.teams.isEmpty)
        #expect(store.files.isEmpty)
        #expect(store.gitStatus == nil)
        #expect(store.terminals.isEmpty)
    }
}
