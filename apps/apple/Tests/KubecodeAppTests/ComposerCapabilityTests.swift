import Foundation
import Testing
@testable import KubecodeApp

@Suite
struct ComposerCapabilityTests {
    @Test func provider_commands_remain_ordered_and_claude_side_question_is_capability_driven() {
        let provider = [
            NativeCommand(name: "review", description: "Review changes"),
            NativeCommand(name: "status", description: "Show status"),
        ]

        let withoutSideQuestion = ComposerCapabilityProjection.commands(
            provider: provider,
            includeClaudeSideQuestion: false
        )
        let withSideQuestion = ComposerCapabilityProjection.commands(
            provider: provider,
            includeClaudeSideQuestion: true
        )
        let providerOwnsBTW = ComposerCapabilityProjection.commands(
            provider: provider + [NativeCommand(name: "btw", description: "Provider description")],
            includeClaudeSideQuestion: true
        )

        #expect(withoutSideQuestion.map(\.name) == ["review", "status"])
        #expect(withSideQuestion.map(\.name) == ["review", "status", "btw"])
        #expect(providerOwnsBTW.map(\.name) == ["review", "status", "btw"])
        #expect(providerOwnsBTW.last?.description == "Provider description")
    }

    @Test func palette_searches_names_and_descriptions_without_losing_provider_order() {
        let commands = [
            NativeCommand(name: "review", description: "Inspect current changes"),
            NativeCommand(name: "status", description: "Show session health"),
            NativeCommand(name: "docs", description: "Write documentation"),
        ]

        #expect(ComposerCapabilityProjection.filtered(commands, query: "") == commands)
        #expect(ComposerCapabilityProjection.filtered(commands, query: "session").map(\.name) == ["status"])
        #expect(ComposerCapabilityProjection.filtered(commands, query: "DOC").map(\.name) == ["docs"])
        #expect(ComposerCapabilityProjection.includesFileReference(query: ""))
        #expect(ComposerCapabilityProjection.includesFileReference(query: "project file"))
        #expect(!ComposerCapabilityProjection.includesFileReference(query: "session"))
    }

    @Test func palette_insertion_preserves_an_existing_draft() {
        #expect(ComposerCapabilityProjection.inserting("/review", into: "") == "/review ")
        #expect(ComposerCapabilityProjection.inserting("/review", into: "Inspect first") == "Inspect first /review ")
        #expect(ComposerCapabilityProjection.inserting("@Sources/App.swift", into: "Use ") == "Use @Sources/App.swift ")
    }

    @Test func palette_selection_keeps_file_reference_first_and_maps_provider_commands_by_identity() {
        let commands = [
            NativeCommand(name: "review", description: "Review changes"),
            NativeCommand(name: "btw", description: "Ask a side question"),
        ]

        #expect(ComposerCapabilitySelection.identifiers(commands: commands) == [
            ComposerCapabilitySelection.referenceFileID,
            "command:review",
            "command:btw",
        ])
        #expect(ComposerCapabilitySelection.command(
            selectedID: "command:btw",
            commands: commands
        ) == commands[1])
        #expect(ComposerCapabilitySelection.command(
            selectedID: ComposerCapabilitySelection.referenceFileID,
            commands: commands
        ) == nil)
    }

    @Test func slash_completion_uses_only_the_leading_command_token() {
        let commands = [
            NativeCommand(name: "review", description: "Review changes"),
            NativeCommand(name: "resume", description: "Resume work"),
            NativeCommand(name: "status", description: "Show status"),
        ]

        #expect(ComposerCommandCompletion.candidates(
            in: "/re",
            caretUTF16Location: 3,
            commands: commands
        ) == ["/review", "/resume"])
        #expect(ComposerCommandCompletion.candidates(
            in: "Please /re",
            caretUTF16Location: 10,
            commands: commands
        ).isEmpty)
        #expect(ComposerCommandCompletion.candidates(
            in: "/review later",
            caretUTF16Location: 13,
            commands: commands
        ).isEmpty)
    }
}
