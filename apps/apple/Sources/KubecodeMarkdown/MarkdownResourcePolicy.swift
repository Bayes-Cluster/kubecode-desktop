import Foundation

public enum MarkdownResourcePolicy {
    public static let maximumRemoteImageBytes = 8 * 1_024 * 1_024
    public static let maximumDecodedImagePixels = 20_000_000

    public static func remoteImageURL(_ source: String?) -> URL? {
        guard let source,
              let components = URLComponents(string: source),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }

    public static func projectRelativeImagePath(_ source: String?) -> String? {
        guard let source, !source.isEmpty,
              !source.hasPrefix("/"),
              !source.contains("\\"),
              URLComponents(string: source)?.scheme == nil
        else { return nil }
        let path = source
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(path).removingPercentEncoding else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return components.joined(separator: "/")
    }
}
