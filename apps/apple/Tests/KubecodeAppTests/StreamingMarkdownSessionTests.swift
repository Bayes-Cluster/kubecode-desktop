import KubecodeMarkdown
import Testing
@testable import KubecodeApp

private actor ControlledStreamingMarkdownBuilder {
    struct Invocation: Equatable, Sendable {
        let source: String
        let previousSource: String?
    }

    private struct SuspendedBuild {
        let source: String
        let previous: StreamingMarkdownDocument?
        let continuation: CheckedContinuation<StreamingMarkdownDocument, Never>
    }

    private struct InvocationWaiter {
        let expected: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var invocations: [Invocation] = []
    private var suspended: [Int: SuspendedBuild] = [:]
    private var invocationWaiters: [InvocationWaiter] = []

    func build(
        source: String,
        previous: StreamingMarkdownDocument?
    ) async -> StreamingMarkdownDocument {
        let index = invocations.count
        invocations.append(.init(source: source, previousSource: previous?.source))
        resumeSatisfiedInvocationWaiters()
        return await withCheckedContinuation { continuation in
            suspended[index] = .init(
                source: source,
                previous: previous,
                continuation: continuation
            )
        }
    }

    func resumeBuild(at index: Int) {
        guard let build = suspended.removeValue(forKey: index) else {
            Issue.record("No suspended Markdown build at index \(index)")
            return
        }
        build.continuation.resume(returning: StreamingMarkdownDocument(
            source: build.source,
            previous: build.previous
        ))
    }

    func resumeBuild(at index: Int, returningSource source: String) {
        guard let build = suspended.removeValue(forKey: index) else {
            Issue.record("No suspended Markdown build at index \(index)")
            return
        }
        build.continuation.resume(returning: StreamingMarkdownDocument(
            source: source,
            previous: build.previous
        ))
    }

    func waitForInvocationCount(_ expected: Int) async {
        if invocations.count >= expected { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(.init(expected: expected, continuation: continuation))
        }
    }

    func recordedInvocations() -> [Invocation] { invocations }

    private func resumeSatisfiedInvocationWaiters() {
        var remaining: [InvocationWaiter] = []
        for waiter in invocationWaiters {
            if invocations.count >= waiter.expected {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        invocationWaiters = remaining
    }
}

private actor RecordingStreamingMarkdownBuilder {
    private var sources: [String] = []

    func build(
        source: String,
        previous: StreamingMarkdownDocument?
    ) -> StreamingMarkdownDocument {
        sources.append(source)
        return StreamingMarkdownDocument(source: source, previous: previous)
    }

    func recordedSources() -> [String] { sources }
}

private actor ManualScheduleGate {
    private var released: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func wait(for index: Int) async {
        if released.remove(index) != nil { return }
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func release(_ index: Int) {
        if let continuation = continuations.removeValue(forKey: index) {
            continuation.resume()
        } else {
            released.insert(index)
        }
    }
}

@MainActor
private final class RecordingScheduler {
    private(set) var tasks: [Task<Void, Never>] = []

    func schedule(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let task = Task.detached { await operation() }
        tasks.append(task)
        return task
    }
}

@MainActor
private final class ManualScheduler {
    private let gate = ManualScheduleGate()
    private(set) var tasks: [Task<Void, Never>] = []

    func schedule(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let index = tasks.count
        let gate = gate
        let task = Task.detached {
            await gate.wait(for: index)
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks.append(task)
        return task
    }

    func release(_ index: Int) async {
        await gate.release(index)
    }
}

@MainActor
private final class StreamingPublicationRecorder {
    private(set) var snapshots: [StreamingMarkdownSession.PreparedSnapshot] = []

    func record(_ snapshot: StreamingMarkdownSession.PreparedSnapshot) {
        snapshots.append(snapshot)
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

@Suite
struct StreamingMarkdownSessionTests {
    @Test @MainActor func older_parse_result_cannot_overwrite_newer_generation() async {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let recorder = StreamingPublicationRecorder()
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule,
            onPublish: recorder.record
        )

        #expect(session.submit(source: "first", generation: 1) == .accepted(contentVersion: 1))
        await builder.waitForInvocationCount(1)
        #expect(session.submit(source: "newest", generation: 2) == .accepted(contentVersion: 2))

        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value
        await builder.waitForInvocationCount(2)
        #expect(recorder.snapshots.isEmpty)

        await builder.resumeBuild(at: 1)
        await scheduler.tasks[1].value

        #expect(recorder.snapshots.map(\.source) == ["newest"])
        #expect(recorder.snapshots.map(\.generation) == [2])
        #expect(recorder.snapshots.map(\.contentVersion) == [2])
    }

    @Test @MainActor func bursty_snapshots_coalesce_to_the_complete_latest_source() async {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule
        )

        #expect(session.submit(source: "snapshot-1", generation: 1) == .accepted(contentVersion: 1))
        await builder.waitForInvocationCount(1)
        for generation in 2...20 {
            #expect(session.submit(
                source: "snapshot-\(generation)",
                generation: generation
            ) == .accepted(contentVersion: generation))
        }

        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value
        await builder.waitForInvocationCount(2)
        await builder.resumeBuild(at: 1)
        await scheduler.tasks[1].value

        let invocations = await builder.recordedInvocations()
        #expect(invocations.map(\.source) == ["snapshot-1", "snapshot-20"])
        #expect(session.preparedSnapshot?.source == "snapshot-20")
        #expect(session.preparedSnapshot?.contentVersion == 20)
    }

    @Test @MainActor func pending_work_is_bounded_to_the_active_and_latest_snapshot() async {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule
        )

        _ = session.submit(source: "snapshot-1", generation: 1)
        await builder.waitForInvocationCount(1)
        for generation in 2...100 {
            _ = session.submit(source: "snapshot-\(generation)", generation: generation)
            #expect(session.activeBuildCount == 1)
            #expect(session.pendingSnapshotCount == 1)
            #expect(session.scheduledWorkCount == 2)
        }
        #expect(await builder.recordedInvocations().count == 1)

        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value
        await builder.waitForInvocationCount(2)
        #expect(session.activeBuildCount == 1)
        #expect(session.pendingSnapshotCount == 0)
        #expect(session.scheduledWorkCount == 1)

        await builder.resumeBuild(at: 1)
        await scheduler.tasks[1].value
        #expect(await builder.recordedInvocations().map(\.source) == ["snapshot-1", "snapshot-100"])
    }

    @Test @MainActor func unchanged_terminal_snapshot_reuses_content_version() async {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let recorder = StreamingPublicationRecorder()
        let source = "# Complete\n\nSame terminal source."
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule,
            onPublish: recorder.record
        )

        #expect(session.submit(source: source, generation: 41) == .accepted(contentVersion: 1))
        await builder.waitForInvocationCount(1)
        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value

        #expect(session.submit(source: "stale", generation: 41) == .rejected)
        #expect(session.submit(source: source, generation: 42) == .unchanged(contentVersion: 1))
        #expect(session.latestSubmittedGeneration == 42)
        #expect(session.latestContentVersion == 1)
        #expect(session.preparedSnapshot?.generation == 42)
        #expect(session.preparedSnapshot?.source == source)
        #expect(session.preparedSnapshot?.contentVersion == 1)
        #expect(await builder.recordedInvocations().count == 1)
        #expect(recorder.snapshots.map(\.generation) == [41])
        #expect(recorder.snapshots.map(\.contentVersion) == [1])
    }

    @Test @MainActor func failed_build_preserves_stable_prefix_and_exact_literal_tail_then_recovers() async throws {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let recorder = StreamingPublicationRecorder()
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule,
            onPublish: recorder.record
        )
        let committed = "# Stable\n\nComplete paragraph.\n\n"
        let failedSource = committed + "```swift\nlet value = 1"
        let recoveredSource = failedSource + "\n```"

        _ = session.submit(source: committed, generation: 1)
        await builder.waitForInvocationCount(1)
        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value

        _ = session.submit(source: failedSource, generation: 2)
        await builder.waitForInvocationCount(2)
        await builder.resumeBuild(at: 1, returningSource: "builder failure sentinel")
        await scheduler.tasks[1].value

        let failed = try #require(session.preparedSnapshot)
        #expect(failed.source == failedSource)
        #expect(failed.document.source == failedSource)
        #expect(failed.document.stablePrefix.map(\.plainText) == ["Stable", "Complete paragraph."])
        #expect(failed.document.mutableTail.last?.literalSource == "```swift\nlet value = 1")
        #expect(recorder.snapshots.map(\.generation) == [1, 2])

        _ = session.submit(source: recoveredSource, generation: 3)
        await builder.waitForInvocationCount(3)
        await builder.resumeBuild(at: 2)
        await scheduler.tasks[2].value

        #expect(session.preparedSnapshot?.source == recoveredSource)
        #expect(session.preparedSnapshot?.document.blocks.last?.literalSource == nil)
        #expect(session.scheduledWorkCount == 0)
    }

    @Test @MainActor func cancelled_session_does_not_publish() async {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let recorder = StreamingPublicationRecorder()
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule,
            onPublish: recorder.record
        )

        _ = session.submit(source: "will finish late", generation: 1)
        await builder.waitForInvocationCount(1)
        session.cancel()
        session.cancel()
        #expect(session.submit(source: "rejected", generation: 2) == .rejected)
        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value

        #expect(session.isCancelled)
        #expect(session.scheduledWorkCount == 0)
        #expect(session.preparedSnapshot == nil)
        #expect(recorder.snapshots.isEmpty)
    }

    @Test @MainActor func injected_builder_and_clock_make_ordering_deterministic() async {
        let builder = RecordingStreamingMarkdownBuilder()
        let scheduler = ManualScheduler()
        let recorder = StreamingPublicationRecorder()
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule,
            onPublish: recorder.record
        )

        _ = session.submit(source: "first", generation: 10)
        _ = session.submit(source: "second", generation: 11)
        #expect(await builder.recordedSources().isEmpty)
        #expect(scheduler.tasks.count == 1)

        await scheduler.release(0)
        await scheduler.tasks[0].value
        #expect(scheduler.tasks.count == 2)
        #expect(await builder.recordedSources() == ["first"])
        #expect(recorder.snapshots.isEmpty)

        await scheduler.release(1)
        await scheduler.tasks[1].value
        #expect(session.preparedSnapshot?.generation == 11)
        #expect(await builder.recordedSources() == ["first", "second"])
        #expect(recorder.snapshots.map(\.generation) == [11])
        #expect(recorder.snapshots.map(\.contentVersion) == [2])
    }

    @Test @MainActor func identical_source_retags_in_flight_work_without_rebuilding() async {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let source = "Same source before and after terminal handoff"
        let session = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule
        )

        _ = session.submit(source: source, generation: 7)
        await builder.waitForInvocationCount(1)
        #expect(session.submit(source: source, generation: 8) == .unchanged(contentVersion: 1))
        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value

        #expect(session.preparedSnapshot?.generation == 8)
        #expect(session.preparedSnapshot?.contentVersion == 1)
        #expect(await builder.recordedInvocations().count == 1)
    }

    @Test @MainActor func released_session_cannot_be_retained_or_publish_from_late_work() async {
        let builder = ControlledStreamingMarkdownBuilder()
        let scheduler = RecordingScheduler()
        let recorder = StreamingPublicationRecorder()
        var session: StreamingMarkdownSession? = StreamingMarkdownSession(
            builder: { await builder.build(source: $0, previous: $1) },
            scheduler: scheduler.schedule,
            onPublish: recorder.record
        )
        let weakSession = WeakReference(session!)

        _ = session?.submit(source: "row teardown", generation: 1)
        await builder.waitForInvocationCount(1)
        session = nil
        #expect(weakSession.value == nil)

        await builder.resumeBuild(at: 0)
        await scheduler.tasks[0].value
        #expect(recorder.snapshots.isEmpty)
    }
}
