import Foundation

public struct TerminalServerEvent: Decodable, Sendable {
    public let type: String
    public let data: String?
    public let cursor: Int?
    public let truncated: Bool?
    public let status: String?
    public let exitCode: Int?
    public let signal: String?

    enum CodingKeys: String, CodingKey {
        case type, data, cursor, truncated, status, signal
        case exitCode = "exit_code"
    }
}

public final class TerminalConnection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let decoder = JSONDecoder()

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func events() -> AsyncThrowingStream<TerminalServerEvent, Error> {
        task.resume()
        return AsyncThrowingStream { continuation in
            let receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case let .string(value): data = Data(value.utf8)
                        case let .data(value): data = value
                        @unknown default: continue
                        }
                        continuation.yield(try decoder.decode(TerminalServerEvent.self, from: data))
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in receiveTask.cancel() }
        }
    }

    public func send(input: String) async throws {
        try await send(["type": "input", "data": input])
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await send(["type": "resize", "cols": cols, "rows": rows])
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ value: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
