import Foundation

public enum QuickOpenIndexer {
    public static func search(
        query: String,
        visitLimit: Int = 2_000,
        resultLimit: Int = 100,
        includeHidden: Bool = false,
        includeIgnored: Bool = false,
        includeGenerated: Bool = false,
        listEntries: @Sendable (String) async throws -> [FileEntry]
    ) async throws -> [FileEntry] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty, visitLimit > 0, resultLimit > 0 else { return [] }

        var directories = [""]
        var nextDirectory = 0
        var seenDirectories: Set<String> = [""]
        var visited = 0
        var candidates: [(entry: FileEntry, score: Int)] = []

        while nextDirectory < directories.count, visited < visitLimit {
            try Task.checkCancellation()
            let directory = directories[nextDirectory]
            nextDirectory += 1

            for entry in try await listEntries(directory) {
                guard visited < visitLimit else { break }
                visited += 1

                if (!includeHidden && entry.hidden == true)
                    || (!includeIgnored && entry.ignored == true)
                    || (!includeGenerated && entry.generated == true) {
                    continue
                }
                if entry.kind == "directory" {
                    if seenDirectories.insert(entry.path).inserted {
                        directories.append(entry.path)
                    }
                    continue
                }
                if let score = matchScore(entry: entry, terms: terms) {
                    candidates.append((entry, score))
                }
            }
        }

        return candidates
            .sorted {
                if $0.score != $1.score { return $0.score < $1.score }
                return $0.entry.path.localizedStandardCompare($1.entry.path) == .orderedAscending
            }
            .prefix(resultLimit)
            .map(\.entry)
    }

    private static func matchScore(entry: FileEntry, terms: [String]) -> Int? {
        let name = entry.name.lowercased()
        let path = entry.path.lowercased()
        guard terms.allSatisfy(path.contains) else { return nil }

        return terms.reduce(into: 0) { score, term in
            if name == term { score += 0 }
            else if name.hasPrefix(term) { score += 1 }
            else if name.contains(term) { score += 2 }
            else if path.hasPrefix(term) { score += 3 }
            else { score += 4 }
        }
    }
}
