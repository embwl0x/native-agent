import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
import TriggerScheduler
@testable import NativeAgentApp

private final class MorningBriefTimeoutEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlineValues: [TimeInterval] = []
    private var markerValues: [String] = []
    private var synthesisValues: [String?] = []

    func recordDeadline(_ value: TimeInterval) {
        lock.lock()
        deadlineValues.append(value)
        lock.unlock()
    }

    func recordMarker(_ value: String) {
        lock.lock()
        markerValues.append(value)
        lock.unlock()
    }

    func recordSynthesis(_ value: String?) {
        lock.lock()
        synthesisValues.append(value)
        lock.unlock()
    }

    var deadlines: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return deadlineValues
    }

    var markers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return markerValues
    }

    var syntheses: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return synthesisValues
    }
}

private final class NeverCompletingMorningBriefTurn: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var turnContinuation: CheckedContinuation<String, Error>?

    func run(_ prompt: String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                started = true
                turnContinuation = continuation
                let waiters = startWaiters
                startWaiters.removeAll()
                lock.unlock()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let continuation = turnContinuation
        turnContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private final class MorningBriefDeadlineCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func wait() async throws {
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        } onCancel: {
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
        }
    }

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func morningBriefEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MorningBriefSynthesisTimeoutEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func morningBriefEvalBuilder(root: URL) -> TriggerContentBuilder {
    TriggerContentBuilder(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: { Date(timeIntervalSinceReferenceDate: 10_000) },
        worklogPath: root.appendingPathComponent("no-such-worklog.jsonl")
    )
}

private let morningBriefEvalRequest = MorningBriefSynthesisRequest(
    dayLabel: "Tuesday, August 26",
    deterministicSummary: "One deterministic item.",
    deterministicDetail: "## Desk\n\n- Keep the fallback true."
)

@Suite("app.background · morning brief synthesis timeout")
struct MorningBriefSynthesisTimeoutEvalTests {
    @Test("deadline cancels a wedged turn, emits the degraded marker, and preserves the deterministic brief")
    func timeoutCancelsAndFallsBackThroughTheRealBuilder() async throws {
        let root = try morningBriefEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = morningBriefEvalBuilder(root: root)
        let deterministic = await builder.morningBrief()
        let hangingTurn = NeverCompletingMorningBriefTurn()
        let evidence = MorningBriefTimeoutEvidence()
        let synthesizer = BackgroundLoopsAssembly.makeMorningBriefSynthesizer(
            runTurn: hangingTurn.run,
            deadlineSleep: { interval in
                evidence.recordDeadline(interval)
                await hangingTurn.waitUntilStarted()
            },
            failureMarker: evidence.recordMarker
        )

        let content = await builder.morningBrief(synthesizer: { request in
            let synthesis = await synthesizer(request)
            evidence.recordSynthesis(synthesis)
            return synthesis
        })

        #expect(evidence.deadlines == [120])
        #expect(hangingTurn.wasCancelled)
        #expect(evidence.syntheses.count == 1)
        #expect(evidence.syntheses[0] == nil)
        #expect(evidence.markers == [
            "[morning-brief] synthesis turn failed (\(String(describing: CancellationError()))) "
            + "— falling back to deterministic brief"
        ])
        #expect(content == deterministic)
        #expect(content.summary != "A rich synthesized lead")
    }

    @Test("a timely nonblank turn passes through and blank output becomes nil without a degraded marker")
    func timelyAndBlankResultsSettleWithoutFalseTimeoutEvidence() async {
        let timelyEvidence = MorningBriefTimeoutEvidence()
        let timelyDeadline = MorningBriefDeadlineCancellation()
        let timely = BackgroundLoopsAssembly.makeMorningBriefSynthesizer(
            runTurn: { _ in "A rich synthesized lead" },
            deadlineSleep: { interval in
                timelyEvidence.recordDeadline(interval)
                try await timelyDeadline.wait()
            },
            failureMarker: timelyEvidence.recordMarker
        )

        #expect(await timely(morningBriefEvalRequest) == "A rich synthesized lead")
        #expect(timelyEvidence.deadlines == [120])
        #expect(timelyDeadline.cancellationCount == 1)
        #expect(timelyEvidence.markers.isEmpty)

        let blankEvidence = MorningBriefTimeoutEvidence()
        let blankDeadline = MorningBriefDeadlineCancellation()
        let blank = BackgroundLoopsAssembly.makeMorningBriefSynthesizer(
            runTurn: { _ in " \n\t " },
            deadlineSleep: { interval in
                blankEvidence.recordDeadline(interval)
                try await blankDeadline.wait()
            },
            failureMarker: blankEvidence.recordMarker
        )

        #expect(await blank(morningBriefEvalRequest) == nil)
        #expect(blankEvidence.deadlines == [120])
        #expect(blankDeadline.cancellationCount == 1)
        #expect(blankEvidence.markers.isEmpty)
    }
}
