import Foundation
import Testing
@testable import NativeAgentApp
import NativeAgentCore
import ProviderRouting

// INTEROCEPTION runtime notice lane (gpt-5.5 review round): the vitals card is
// an append-only INBOX NOTICE (notifications/inbox.jsonl event-log semantics),
// idempotent from DISK — restart-safe with no in-memory association — and
// ordinary lifecycle observation never writes anything.

private func makeRuntime(root: URL) -> NativeCognitionRuntime {
    NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: .allPhasesEnabled,
        organismConfigurationOverride: .disabled
    )
}

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-vitals-runtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func degradedTransition(_ providerId: String) -> ProviderVitalsTransition {
    ProviderVitalsTransition(
        providerId: providerId,
        from: .sluggish,
        to: .degraded,
        direction: .worsening,
        occurredAt: Date(),
        emaLatencyMs: 4_200,
        baselineLatencyMs: 2_000,
        emaErrorRate: 0.4,
        consecutiveFailures: 5
    )
}

private func vitalsRows(root: URL) throws -> [(kind: String, provider: String)] {
    let path = root
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    guard let data = try? Data(contentsOf: path) else { return [] }
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
                obj["source"] as? String == "provider_vitals",
                let kind = obj["providerVitalsKind"] as? String,
                let provider = obj["providerVitalsProvider"] as? String else { return nil }
            return (kind, provider)
        }
}

@Test func noticeStagingIsIdempotentAcrossRuntimeInstances() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // First runtime stages the degradation notice.
    let first = makeRuntime(root: root)
    await first.stageProviderVitalsNotice(
        providerId: "kimi-code", transition: degradedTransition("kimi-code")
    )
    #expect(try vitalsRows(root: root).map(\.kind) == ["degraded"])

    // A SECOND runtime instance (relaunch shape: fresh memory, same disk) sees
    // the open degradation on disk and stages nothing.
    let second = makeRuntime(root: root)
    await second.stageProviderVitalsNotice(
        providerId: "kimi-code", transition: degradedTransition("kimi-code")
    )
    #expect(try vitalsRows(root: root).map(\.kind) == ["degraded"],
            "relaunch duplicated the degradation notice")

    // Recovery on the second instance closes the episode the FIRST opened —
    // association derived from disk, not memory. A second recovery no-ops.
    await second.postProviderVitalsRecoveryNotice(providerId: "kimi-code")
    #expect(try vitalsRows(root: root).map(\.kind) == ["degraded", "recovered"])
    await second.postProviderVitalsRecoveryNotice(providerId: "kimi-code")
    #expect(try vitalsRows(root: root).map(\.kind) == ["degraded", "recovered"])

    // A NEW degradation episode after recovery stages a fresh notice.
    await second.stageProviderVitalsNotice(
        providerId: "kimi-code", transition: degradedTransition("kimi-code")
    )
    #expect(try vitalsRows(root: root).map(\.kind) == ["degraded", "recovered", "degraded"])
}

// 2026-08-01 concurrency fix: the idempotency check used to read the inbox
// OUTSIDE any lock, so two overlapping sweeps could both see "not degraded" and
// both append — and the recovery gate, which only ever closes the LATEST row,
// could never clear the stale one. Check + append now share one file lock.
@Test func concurrentStagingStagesExactlyOneDegradedNotice() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Separate runtime instances so actor re-entrancy is not the only
    // interleaving surface — this is the cross-process shape the flock owns.
    let runtimes = (0..<8).map { _ in makeRuntime(root: root) }
    await withTaskGroup(of: Void.self) { group in
        for runtime in runtimes {
            group.addTask {
                await runtime.stageProviderVitalsNotice(
                    providerId: "kimi-code", transition: degradedTransition("kimi-code")
                )
            }
        }
    }

    #expect(try vitalsRows(root: root).map(\.kind) == ["degraded"],
            "overlapping sweeps double-carded the provider")

    // And the single recovery closes the episode completely — no stale row left
    // behind for the latest-row gate to miss.
    await runtimes[0].postProviderVitalsRecoveryNotice(providerId: "kimi-code")
    #expect(try vitalsRows(root: root).map(\.kind) == ["degraded", "recovered"])
}

@Test func recoveryWithoutOpenDegradationIsSilent() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = makeRuntime(root: root)
    await runtime.postProviderVitalsRecoveryNotice(providerId: "kimi-code")
    #expect(try vitalsRows(root: root).isEmpty)
}

@Test func ordinaryObservationNeverWritesDisk() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = makeRuntime(root: root)

    // A healthy day of lifecycle events: starts + successes.
    for i in 0..<40 {
        let started = LLMCallLifecycleEvent(
            id: "call-\(i)", phase: .started, providerId: "kimi-code",
            model: "k3", surface: "chat", sessionId: "s", turnId: "t",
            streaming: false, occurredAt: Date()
        )
        await runtime.feedProviderVitals(started)
        await runtime.feedProviderVitals(started.terminal(.succeeded))
    }
    // Give any (incorrectly) spawned sweep a beat to run.
    try await Task.sleep(nanoseconds: 200_000_000)

    // No inbox notice and no vitals snapshot may exist from observation.
    #expect(try vitalsRows(root: root).isEmpty, "observation staged an inbox notice")
    let telemetry = root
        .appendingPathComponent("telemetry", isDirectory: true)
        .appendingPathComponent("provider_vitals.json")
    #expect(!FileManager.default.fileExists(atPath: telemetry.path),
            "observation persisted a snapshot")
}
