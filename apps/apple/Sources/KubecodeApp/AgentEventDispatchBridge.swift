import Foundation
import KubecodeKit

actor AgentEventDispatchBridge {
    typealias Handler = @MainActor @Sendable ([AgentEvent]) async -> Void

    private enum Constants {
        static let baseInterval = Duration.milliseconds(33)
        static let burstInterval = Duration.milliseconds(50)
        static let burstByteThreshold = 4_096
        static let burstItemThreshold = 8
        static let maximumBatchSize = 192
        static let deliveryChunkSize = 64
    }

    private struct DeltaKey: Hashable {
        let runID: String
        let kind: String
        let messageID: String
    }

    private let handler: Handler
    private var pending: [AgentEvent] = []
    private var flushTask: Task<Void, Never>?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func enqueue(_ event: AgentEvent) async {
        if mergeWithLast(event) {
            scheduleFlush()
            return
        }
        if isImmediate(event) {
            await flushNow()
            await deliver([event])
            return
        }
        pending.append(event)
        if pending.count >= Constants.maximumBatchSize {
            await flushNow()
        } else {
            scheduleFlush()
        }
    }

    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        await deliver(batch)
    }

    func stop(discardPending: Bool) async {
        flushTask?.cancel()
        flushTask = nil
        if discardPending {
            pending.removeAll(keepingCapacity: false)
        } else {
            await flushNow()
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let interval = isBursting ? Constants.burstInterval : Constants.baseInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            await self.flushNow()
        }
    }

    private var isBursting: Bool {
        pending.count > Constants.burstItemThreshold
            || pending.reduce(0) { $0 + ($1.payload["text"]?.stringValue?.utf8.count ?? 0) }
                > Constants.burstByteThreshold
    }

    private func mergeWithLast(_ event: AgentEvent) -> Bool {
        guard let index = pending.indices.last,
              deltaKey(for: pending[index]) == deltaKey(for: event),
              var text = pending[index].payload["text"]?.stringValue,
              let delta = event.payload["text"]?.stringValue
        else { return false }
        text.append(delta)
        var payload = event.payload
        payload["text"] = .string(text)
        pending[index] = AgentEvent(
            runID: event.runID,
            sequence: event.sequence,
            kind: event.kind,
            payload: payload,
            createdAt: event.createdAt
        )
        return true
    }

    private func deltaKey(for event: AgentEvent) -> DeltaKey? {
        guard event.kind == "text_delta" || event.kind == "thinking_delta" else { return nil }
        let messageID = event.payload["message_id"]?.stringValue
            ?? event.payload["messageId"]?.stringValue
            ?? "default"
        return DeltaKey(runID: event.runID, kind: event.kind, messageID: messageID)
    }

    private func isImmediate(_ event: AgentEvent) -> Bool {
        !["text_delta", "thinking_delta", "tool_updated"].contains(event.kind)
    }

    private func deliver(_ events: [AgentEvent]) async {
        var start = events.startIndex
        while start < events.endIndex {
            let end = min(start + Constants.deliveryChunkSize, events.endIndex)
            await handler(Array(events[start..<end]))
            start = end
            if start < events.endIndex { await Task.yield() }
        }
    }
}
