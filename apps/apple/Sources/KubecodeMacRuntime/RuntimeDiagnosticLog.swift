#if os(macOS)
import Darwin
import Foundation

public enum RuntimeDiagnosticSource: Hashable, Sendable {
    case local
    case profile(UUID)
}

public struct RuntimeDiagnosticLog: Sendable {
    public static let live = RuntimeDiagnosticLog(directory: defaultDirectory())

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for source: RuntimeDiagnosticSource) -> URL {
        switch source {
        case .local:
            directory.appending(path: "runtime.log")
        case let .profile(profileID):
            directory.appending(path: "profile-\(profileID.uuidString.lowercased()).log")
        }
    }

    public func prepare(
        _ source: RuntimeDiagnosticSource,
        maximumFileBytes: Int = 5 * 1_024 * 1_024,
        retainedBytes: Int = 2 * 1_024 * 1_024
    ) throws {
        try ensureExists(source)
        let logURL = url(for: source)
        let size = try logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > max(0, maximumFileBytes) else { return }
        let retained = try recentText(
            for: source,
            maxBytes: max(1, retainedBytes),
            maxLines: .max
        )
        try Data(retained.utf8).write(to: logURL, options: .atomic)
    }

    public func ensureExists(_ source: RuntimeDiagnosticSource) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = url(for: source)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
    }

    public func openForAppending(_ source: RuntimeDiagnosticSource) throws -> FileHandle {
        try ensureExists(source)
        let descriptor = url(for: source).path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public func append(_ message: String, to source: RuntimeDiagnosticSource) throws {
        let handle = try openForAppending(source)
        defer { try? handle.close() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try handle.write(contentsOf: Data("[\(timestamp)] \(Self.sanitized(message))\n".utf8))
    }

    public func recentText(
        for source: RuntimeDiagnosticSource,
        maxBytes: Int = 256 * 1_024,
        maxLines: Int = 1_000
    ) throws -> String {
        guard maxBytes > 0, maxLines > 0 else { return "" }
        let logURL = url(for: source)
        guard FileManager.default.fileExists(atPath: logURL.path) else { return "" }
        let handle = try FileHandle(forReadingFrom: logURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return "" }

        let requestedStart = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        let readStart = requestedStart > 0 ? requestedStart - 1 : 0
        try handle.seek(toOffset: readStart)
        var data = try handle.readToEnd() ?? Data()

        if requestedStart > 0, !data.isEmpty {
            let precedingByte = data.removeFirst()
            if precedingByte != 0x0A {
                guard let newline = data.firstIndex(of: 0x0A) else { return "" }
                data.removeSubrange(data.startIndex...newline)
            }
        }

        let text = String(decoding: data, as: UTF8.self)
        let endedWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endedWithNewline, lines.last?.isEmpty == true { lines.removeLast() }
        let result = lines.suffix(maxLines).joined(separator: "\n")
        return endedWithNewline && !result.isEmpty ? result + "\n" : result
    }

    private static func defaultDirectory() -> URL {
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            return library.appending(path: "Logs/Kubecode", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Kubecode", directoryHint: .isDirectory)
    }

    private static func sanitized(_ message: String) -> String {
        let replacements = [
            (#"(?i)authorization\s*[:=]\s*bearer\s+[^\s,;}]+"#, "Authorization: Bearer [REDACTED]"),
            (#"(?i)(access[_-]?token|bearer[_-]?token|token)\s*[:=]\s*[\"']?[^\s\"',;}]+"#, "$1=[REDACTED]"),
            (#"https?://[^\s,;}]+"#, "[endpoint]"),
        ]
        return replacements.reduce(message) { value, replacement in
            guard let expression = try? NSRegularExpression(pattern: replacement.0) else {
                return value
            }
            let range = NSRange(value.startIndex..., in: value)
            return expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: replacement.1
            )
        }
    }
}
#endif
