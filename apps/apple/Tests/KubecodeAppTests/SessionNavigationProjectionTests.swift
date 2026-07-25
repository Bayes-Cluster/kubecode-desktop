import Foundation
import Testing
@testable import KubecodeApp
import KubecodeKit

@Suite
struct SessionNavigationProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_790_154_000) // 2026-09-23 12:00:00 UTC

    @Test func sections_prioritize_attention_and_running_then_group_by_activity() throws {
        let conversations = try [
            conversation("attention", status: "waiting_permission", updatedAt: "2026-09-23T08:00:00Z"),
            conversation("running", status: "running", updatedAt: "2026-09-23T07:00:00Z"),
            conversation("today", updatedAt: "2026-09-23 06:00:00"),
            conversation("week", updatedAt: "2026-09-20T06:00:00Z"),
            conversation("older", updatedAt: "2026-08-01T06:00:00Z"),
            conversation("archived", archived: true, updatedAt: "2026-09-22T06:00:00Z"),
        ]

        let hidden = SessionNavigationProjection.sections(
            conversations,
            preferences: .default,
            now: now
        )
        let shown = SessionNavigationProjection.sections(
            conversations,
            preferences: SessionNavigationPreferences(showArchived: true),
            now: now
        )

        #expect(hidden.map(\.id) == [.attention, .running, .today, .week, .older])
        #expect(shown.map(\.id) == [.attention, .running, .today, .week, .older, .archived])
        #expect(shown.last?.roots.map(\.conversation.id) == ["archived"])
    }

    @Test func relationship_children_nest_under_visible_parents_without_crossing_archive_boundaries() throws {
        let conversations = try [
            conversation("parent", title: "Main", updatedAt: "2026-09-23T08:00:00Z"),
            conversation(
                "branch",
                title: "Experiment",
                updatedAt: "2026-09-23T09:00:00Z",
                parentID: "parent",
                relationship: "branch"
            ),
            conversation(
                "archived-fork",
                archived: true,
                updatedAt: "2026-09-22T09:00:00Z",
                parentID: "parent",
                relationship: "fork"
            ),
        ]

        let sections = SessionNavigationProjection.sections(
            conversations,
            preferences: SessionNavigationPreferences(showArchived: true),
            now: now
        )

        let today = try #require(sections.first { $0.id == .today })
        #expect(today.roots.map(\.conversation.id) == ["parent"])
        #expect(today.roots[0].children.map(\.conversation.id) == ["branch"])
        let archived = try #require(sections.first { $0.id == .archived })
        #expect(archived.roots.map(\.conversation.id) == ["archived-fork"])
    }

    @Test func filtering_out_a_parent_keeps_the_matching_child_navigable() throws {
        let conversations = try [
            conversation("codex-parent", agentID: "codex", updatedAt: "2026-09-23T08:00:00Z"),
            conversation(
                "claude-child",
                agentID: "claude_code",
                updatedAt: "2026-09-23T09:00:00Z",
                parentID: "codex-parent",
                relationship: "subagent"
            ),
        ]
        let preferences = SessionNavigationPreferences(agentID: .claudeCode, sort: .title)

        let sections = SessionNavigationProjection.sections(
            conversations,
            preferences: preferences,
            now: now
        )

        #expect(sections.count == 1)
        #expect(sections[0].roots.map(\.conversation.id) == ["claude-child"])
    }

    private func conversation(
        _ id: String,
        title: String? = nil,
        agentID: String = "codex",
        status: String? = nil,
        archived: Bool = false,
        updatedAt: String,
        parentID: String? = nil,
        relationship: String? = nil
    ) throws -> Conversation {
        let data: [String: Any?] = [
            "id": id,
            "project_id": "project-1",
            "agent_id": agentID,
            "title": title ?? id,
            "execution_mode": "shared",
            "archived": archived,
            "latest_run_status": status,
            "created_at": updatedAt,
            "updated_at": updatedAt,
            "parent_conversation_id": parentID,
            "relationship": relationship,
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: data.compactMapValues { $0 },
            options: [.sortedKeys]
        )
        return try JSONDecoder().decode(Conversation.self, from: encoded)
    }
}
