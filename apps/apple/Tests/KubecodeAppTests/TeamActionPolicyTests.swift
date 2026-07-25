import Foundation
import Testing
@testable import KubecodeApp
import KubecodeKit

@Suite
struct TeamActionPolicyTests {
    @Test func team_setup_requires_a_goal_criteria_and_an_allowed_agent() {
        #expect(!TeamSetupPolicy.canStart(goal: "", acceptanceCriteria: ["Tests pass"], allowedAgentIDs: [.codex]))
        #expect(!TeamSetupPolicy.canStart(goal: "Ship it", acceptanceCriteria: [], allowedAgentIDs: [.codex]))
        #expect(!TeamSetupPolicy.canStart(goal: "Ship it", acceptanceCriteria: ["Tests pass"], allowedAgentIDs: []))
        #expect(TeamSetupPolicy.canStart(
            goal: "  Ship it  ",
            acceptanceCriteria: ["  ", "Tests pass"],
            allowedAgentIDs: [.codex]
        ))
    }

    @Test func team_setup_keeps_parallelism_within_the_teammate_budget() {
        #expect(TeamSetupPolicy.parallelRuns(5, limitedBy: 3) == 3)
        #expect(TeamSetupPolicy.parallelRuns(0, limitedBy: 3) == 1)
        #expect(TeamSetupPolicy.parallelRuns(2, limitedBy: 3) == 2)
    }

    @Test func yolo_permission_labels_follow_the_runtime_owned_provider_profiles() {
        #expect(TeamSetupPolicy.nativePermissionLabel(for: .claudeCode) == "Claude Code · bypassPermissions")
        #expect(TeamSetupPolicy.nativePermissionLabel(for: .codex) == "Codex · Agent (full access)")
        #expect(TeamSetupPolicy.nativePermissionLabel(for: .opencode) == "OpenCode · allow")
    }

    @Test func leader_native_options_promote_acp_mode_and_preserve_provider_configs() throws {
        let state = try sessionState(#"""
        {
          "current_mode": {
            "currentModeId":"plan",
            "availableModes":[
              {"id":"default","name":"Manual"},
              {"id":"plan","name":"Plan Mode"}
            ]
          },
          "config_options": {
            "configOptions":[
              {
                "category":"mode","id":"mode","name":"Mode","type":"select",
                "currentValue":"plan","options":[
                  {"value":"default","name":"Manual"},
                  {"value":"plan","name":"Plan Mode"}
                ]
              },
              {
                "category":"model","id":"model","name":"Model",
                "currentValue":"sonnet","options":[
                  {"value":"sonnet","name":"Sonnet"},
                  {"value":"opus","name":"Opus"}
                ]
              },
              {"id":"fast","name":"Fast mode","type":"boolean","currentValue":true}
            ]
          },
          "mode_access":{"can_change":true}
        }
        """#)

        let controls = NativeSessionControlProjection.controls(from: state)

        #expect(controls.mode?.kind == .mode)
        #expect(controls.mode?.currentValue == .string("plan"))
        #expect(controls.mode?.choices.map(\.id) == ["default", "plan"])
        #expect(controls.configs.map(\.id) == ["model", "fast"])
        #expect(controls.configs[0].choices.map(\.id) == ["sonnet", "opus"])
        #expect(controls.configs[1].isBoolean)
        #expect(controls.configs[1].currentValue == .bool(true))
    }

    @Test func leader_native_options_use_the_config_route_for_a_fallback_mode() throws {
        let state = try sessionState(#"""
        {
          "current_mode":null,
          "config_options": {
            "configOptions":[{
              "category":"mode","id":"profile","name":"Profile","type":"select",
              "currentValue":"build","options":[
                {"value":"build","name":"Build"},
                {"value":"plan","name":"Plan"}
              ]
            }]
          },
          "mode_access":{"can_change":true}
        }
        """#)

        let controls = NativeSessionControlProjection.controls(from: state)

        #expect(controls.mode?.kind == .config)
        #expect(controls.mode?.id == "profile")
        #expect(controls.configs.isEmpty)
    }

    @Test func yolo_locks_only_the_provider_mode_replaced_by_native_permissions() {
        #expect(TeamSetupPolicy.permissionModeLocked(teamMode: "yolo", leaderAgentID: .claudeCode))
        #expect(TeamSetupPolicy.permissionModeLocked(teamMode: "yolo", leaderAgentID: .codex))
        #expect(!TeamSetupPolicy.permissionModeLocked(teamMode: "yolo", leaderAgentID: .opencode))
        #expect(!TeamSetupPolicy.permissionModeLocked(teamMode: "standard", leaderAgentID: .codex))
    }

    @Test func task_actions_are_exposed_only_in_runtime_valid_states() throws {
        let pending = try task(status: "pending", assignee: nil)
        let assigned = try task(status: "pending", assignee: "member-1")
        let running = try task(status: "in_progress", assignee: "member-1")
        let failed = try task(status: "failed", assignee: "member-1")
        let cancelled = try task(status: "cancelled", assignee: nil)
        let accepted = try task(status: "accepted", assignee: "member-1")

        #expect(TeamActionPolicy.canAssign(pending))
        #expect(!TeamActionPolicy.canAssign(assigned))
        #expect(!TeamActionPolicy.canAssign(running))
        #expect(TeamActionPolicy.canRetry(failed))
        #expect(TeamActionPolicy.canRetry(cancelled))
        #expect(!TeamActionPolicy.canRetry(accepted))
        #expect(TeamActionPolicy.canCancel(pending))
        #expect(TeamActionPolicy.canCancel(running))
        #expect(!TeamActionPolicy.canCancel(cancelled))
        #expect(!TeamActionPolicy.canCancel(accepted))
    }

    @Test func only_live_teammates_can_be_removed_or_receive_tasks() throws {
        let leader = try member(id: "leader", role: "leader", status: "idle")
        let teammate = try member(id: "member-1", role: "teammate", status: "idle")
        let removing = try member(id: "member-2", role: "teammate", status: "removing")
        let discriminator = try member(id: "reviewer", role: "discriminator", status: "idle")

        #expect(TeamActionPolicy.canRemove(teammate))
        #expect(!TeamActionPolicy.canRemove(leader))
        #expect(!TeamActionPolicy.canRemove(removing))
        #expect(TeamActionPolicy.assignmentCandidates([leader, teammate, removing, discriminator]).map(\.id) == ["member-1"])
    }

    @Test func team_snapshot_replaces_removed_members_without_reordering_other_sessions() throws {
        let solo = try conversation(id: "solo", teamID: nil, role: nil)
        let leader = try conversation(id: "leader", teamID: "team-1", role: "leader")
        let removed = try conversation(id: "removed", teamID: "team-1", role: "teammate")
        let replacement = try conversation(id: "replacement", teamID: "team-1", role: "teammate")

        let reconciled = TeamConversationProjection.reconcile(
            teamID: "team-1",
            latest: [leader, replacement],
            existing: [solo, leader, removed]
        )

        #expect(reconciled.map(\.id) == ["solo", "leader", "replacement"])
    }

    @Test func lifecycle_actions_follow_team_state_and_completion_attention() throws {
        let clear = try counters(running: 0, queued: 0, attention: 0)
        let busy = try counters(running: 1, queued: 0, attention: 0)
        let blocked = try counters(running: 0, queued: 0, attention: 1)

        #expect(TeamActionPolicy.canPause(status: "active"))
        #expect(TeamActionPolicy.canPause(status: "needs_attention"))
        #expect(!TeamActionPolicy.canPause(status: "paused"))
        #expect(TeamActionPolicy.canResume(status: "paused"))
        #expect(!TeamActionPolicy.canResume(status: "active"))
        #expect(TeamActionPolicy.canComplete(status: "active", counters: clear))
        #expect(!TeamActionPolicy.canComplete(status: "active", counters: busy))
        #expect(!TeamActionPolicy.canComplete(status: "active", counters: blocked))
        #expect(!TeamActionPolicy.canComplete(status: "completed", counters: clear))
    }

    @Test func only_needs_attention_teams_offer_the_reconfiguration_recovery_path() {
        #expect(TeamActionPolicy.canReconfigure(status: "needs_attention"))
        #expect(!TeamActionPolicy.canReconfigure(status: "draft"))
        #expect(!TeamActionPolicy.canReconfigure(status: "active"))
        #expect(!TeamActionPolicy.canReconfigure(status: "paused"))
        #expect(TeamSetupPolicy.navigationTitle(for: "draft") == "Configure Team")
        #expect(TeamSetupPolicy.confirmationTitle(for: "draft") == "Start Team")
        #expect(TeamSetupPolicy.navigationTitle(for: "needs_attention") == "Reconfigure Team")
        #expect(TeamSetupPolicy.confirmationTitle(for: "needs_attention") == "Restart Team")
    }

    @Test func permission_navigation_resolves_the_owning_member() throws {
        let first = try member(id: "member-1", role: "teammate", status: "waiting_permission")
        let second = try member(id: "member-2", role: "teammate", status: "idle")
        let permission = try JSONDecoder().decode(TeamPermissionRequest.self, from: Data(#"""
        {
          "id":"permission-1","member_id":"member-1","run_id":"run-1",
          "tool":"Bash","status":"pending","reason":"Needs network access"
        }
        """#.utf8))

        #expect(TeamActionPolicy.permissionOwner(permission, members: [second, first])?.id == first.id)
    }

    @Test func attention_navigation_resolves_the_owning_member() throws {
        let first = try member(id: "member-1", role: "teammate", status: "needs_attention")
        let second = try member(id: "member-2", role: "teammate", status: "idle")
        let attention = try JSONDecoder().decode(TeamAttention.self, from: Data(#"""
        {
          "id":"attention-1","kind":"member_attention","member_id":"member-1",
          "task_id":null,"summary":"Researcher needs input"
        }
        """#.utf8))

        #expect(TeamActionPolicy.attentionOwner(attention, members: [second, first])?.id == first.id)
    }

    @Test func lineup_proposal_members_are_projected_from_bounded_structured_json() throws {
        let proposal = try JSONDecoder().decode(TeamProposal.self, from: Data(#"""
        {
          "id":"proposal-1","summary":"Add reviewers","status":"pending",
          "members_json":"[\"Coordinator\",{\"name\":\"Reviewer\"},{\"role\":\"Implementer\"},{\"agent_id\":\"codex\"},42]"
        }
        """#.utf8))
        let malformed = try JSONDecoder().decode(TeamProposal.self, from: Data(#"""
        {
          "id":"proposal-2","summary":"Broken payload","status":"pending",
          "members_json":"not-json"
        }
        """#.utf8))

        #expect(proposal.proposedMemberNames == ["Coordinator", "Reviewer", "Implementer"])
        #expect(malformed.proposedMemberNames.isEmpty)
    }

    private func task(status: String, assignee: String?) throws -> TeamTask {
        let assigneeField = assignee.map { #", "assignee_member_id":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(TeamTask.self, from: Data(#"""
        {
          "id":"task-\#(status)","title":"Task","description":"Work",
          "status":"\#(status)","completion_required":true\#(assigneeField)
        }
        """#.utf8))
    }

    private func member(id: String, role: String, status: String) throws -> TeamMember {
        try JSONDecoder().decode(TeamMember.self, from: Data(#"""
        {
          "id":"\#(id)","name":"\#(id)","role":"\#(role)",
          "status":"\#(status)","conversation_id":"session-\#(id)"
        }
        """#.utf8))
    }

    private func conversation(id: String, teamID: String?, role: String?) throws -> Conversation {
        let teamFields = teamID.map { #", "team_id":"\#($0)""# } ?? ""
        let roleField = role.map { #", "team_role":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(Conversation.self, from: Data(#"""
        {
          "id":"\#(id)","project_id":"project-1","agent_id":"codex",
          "title":"\#(id)","execution_mode":"shared"\#(teamFields)\#(roleField)
        }
        """#.utf8))
    }

    private func counters(running: Int, queued: Int, attention: Int) throws -> TeamCounters {
        try JSONDecoder().decode(TeamCounters.self, from: Data(#"""
        {
          "running":\#(running),"queued":\#(queued),"needs_attention":\#(attention),
          "done":0,"total_tasks":1
        }
        """#.utf8))
    }

    private func sessionState(_ source: String) throws -> AgentSessionState {
        try JSONDecoder().decode(AgentSessionState.self, from: Data(source.utf8))
    }
}
