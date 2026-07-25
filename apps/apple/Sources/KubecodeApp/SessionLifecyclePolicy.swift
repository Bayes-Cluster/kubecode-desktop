import Foundation
import KubecodeKit

enum SessionLifecyclePolicy {
    static func manualTitle(from input: String) -> String? {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func canDelete(_ conversation: Conversation) -> Bool {
        !["teammate", "discriminator"].contains(conversation.teamRole)
    }

    static func canFork(_ conversation: Conversation) -> Bool {
        conversation.providerSessionID != nil
    }

    static func removedConversationIDs(
        deleting conversation: Conversation,
        conversations: [Conversation]
    ) -> [String] {
        guard conversation.teamRole == "leader", let teamID = conversation.teamID else {
            return [conversation.id]
        }
        let ids = conversations
            .filter { $0.teamID == teamID }
            .map(\.id)
        return ids.isEmpty ? [conversation.id] : ids
    }
}
