import AppKit
import SwiftUI

struct WorkspaceTypography: Equatable, Sendable {
    static let systemFontName = "System"
    static let systemMonospacedFontName = "System Mono"
    static let defaultPointSize: Double = 14
    static let allowedPointSizes = 12...20

    let fontName: String
    let pointSize: Double

    init(fontName: String, pointSize: Double) {
        let candidate = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fontName = candidate.isEmpty ? Self.systemFontName : candidate
        self.pointSize = Self.normalizedPointSize(pointSize)
    }

    var displayFontName: String {
        usesSystemFont || resolvedCustomFont(size: pointSize) == nil
            ? Self.systemFontName
            : fontName
    }

    var composerFont: NSFont { nsFont(for: .body) }

    func nsFont(for style: NSFont.TextStyle) -> NSFont {
        let preferredBodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        let preferredStyleSize = NSFont.preferredFont(forTextStyle: style).pointSize
        let relativeSize = preferredBodySize > 0 ? preferredStyleSize / preferredBodySize : 1
        let resolvedSize = max(8, pointSize * relativeSize)
        return resolvedCustomFont(size: resolvedSize) ?? .systemFont(ofSize: resolvedSize)
    }

    func swiftUIFont(for style: NSFont.TextStyle) -> Font {
        Font(nsFont(for: style))
    }

    static func availableFontFamilies(monospacedOnly: Bool = false) -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard monospacedOnly else { return true }
                guard let font = NSFontManager.shared.font(
                    withFamily: family,
                    traits: [],
                    weight: 5,
                    size: 13
                ) else { return false }
                return NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var usesSystemFont: Bool {
        fontName == Self.systemFontName || fontName == "System Sans"
    }

    private func resolvedCustomFont(size: CGFloat) -> NSFont? {
        guard !usesSystemFont else { return nil }
        return NSFontManager.shared.font(
            withFamily: fontName,
            traits: [],
            weight: 5,
            size: size
        ) ?? NSFont(name: fontName, size: size)
    }

    private static func normalizedPointSize(_ value: Double) -> Double {
        let rounded = value.rounded()
        guard value.isFinite,
              abs(value - rounded) < 0.001,
              allowedPointSizes.contains(Int(rounded))
        else { return defaultPointSize }
        return rounded
    }
}

private struct WorkspaceTypographyEnvironmentKey: EnvironmentKey {
    static let defaultValue = WorkspaceTypography(
        fontName: WorkspaceTypography.systemFontName,
        pointSize: WorkspaceTypography.defaultPointSize
    )
}

extension EnvironmentValues {
    var workspaceTypography: WorkspaceTypography {
        get { self[WorkspaceTypographyEnvironmentKey.self] }
        set { self[WorkspaceTypographyEnvironmentKey.self] = newValue }
    }
}

extension View {
    func workspaceTypography(_ typography: WorkspaceTypography) -> some View {
        environment(\.workspaceTypography, typography)
            .font(typography.swiftUIFont(for: .body))
    }
}
