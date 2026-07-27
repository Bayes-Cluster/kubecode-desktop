import AppKit
import SwiftUI
import KubecodeKit

struct AgentIcon: View {
    let agentID: AgentID
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Self.image(for: agentID) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }

    static func image(for agentID: AgentID) -> NSImage? {
        let url = Bundle.module.url(
            forResource: agentID.resourceName,
            withExtension: "svg",
            subdirectory: "AgentIcons"
        ) ?? Bundle.module.url(forResource: agentID.resourceName, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}

struct AgentIdentityLabel: View {
    let agentID: AgentID
    var iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(agentID: agentID, size: iconSize)
            Text(verbatim: agentID.displayName)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension AgentID {
    var resourceName: String {
        switch self {
        case .claudeCode: "claude-code"
        case .codex: "codex"
        case .opencode: "opencode"
        }
    }
}
