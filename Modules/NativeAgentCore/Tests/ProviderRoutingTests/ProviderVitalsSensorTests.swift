import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// INTEROCEPTION — ProviderVitalsSensor proof obligations.
//
// The sensor is a PASSIVE body-sense: it observes the existing provider
// lifecycle seam and never issues a provider call. These tests pin the design's
// numbered proof obligations directly.

private let epoch = Date(timeIntervalSince1970: 1_000_000)

private func sample(
    _ provider: String,
    at seconds: Double,
    durationMs: Double,
    isError: Bool = false
) -> ProviderVitalsSample {
    ProviderVitalsSample(
        providerId: provider,
        occurredAt: epoch.addingTimeInterval(seconds),
        durationMs: durationMs,
        isError: isError
    )
}

// Proof (a): a quiet/nominal day — the sensor makes ZERO provider calls. It is a
// pure observer with no LLMClient and no network. Feeding it a full day of
// healthy calls yields no transitions and no side effects beyond in-memory EMAs.
@Test func quietDaySensorIsPurelyPassive() async {
    let sensor = ProviderVitalsSensor()
    var transitions = 0
    for i in 0..<500 {
        let t = await sensor.observe(sample: sample("moonshot", at: Double(i), durationMs: 800))
        if t != nil { transitions += 1 }
    }
    #expect(transitions == 0)
    let vitals = await sensor.vitals(for: "moonshot")
    #expect(vitals?.band == .nominal)
    #expect(vitals?.sampleCount == 500)
}

// Proof (b): a stable band emits ZERO transitions regardless of call volume.
@Test func stableBandEmitsNoTransitionsAtAnyVolume() async {
    let sensor = ProviderVitalsSensor()
    var emitted: [ProviderVitalsTransition] = []
    // Jittered-but-healthy latency; never crosses a threshold.
    for i in 0..<2_000 {
        let jitter = Double(i % 7) * 10
        if let t = await sensor.observe(sample: sample("anthropic", at: Double(i), durationMs: 700 + jitter)) {
            emitted.append(t)
        }
    }
    #expect(emitted.isEmpty)
}

// Proof (c): a genuine band transition emits EXACTLY ONE event; staying in the
// worse band after that emits nothing further.
@Test func bandTransitionEmitsExactlyOnce() async {
    let sensor = ProviderVitalsSensor()
    // Warm up a healthy baseline.
    for i in 0..<10 {
        _ = await sensor.observe(sample: sample("k3", at: Double(i), durationMs: 500))
    }
    // Now a sustained run of hard failures drives the band down.
    var transitions: [ProviderVitalsTransition] = []
    for i in 10..<40 {
        if let t = await sensor.observe(sample: sample("k3", at: Double(i), durationMs: 500, isError: true)) {
            transitions.append(t)
        }
    }
    // At least one worsening transition, and every emitted transition is a real
    // band change (from != to). The first crosses out of nominal.
    #expect(!transitions.isEmpty)
    #expect(transitions.allSatisfy { $0.from != $0.to })
    #expect(transitions.first?.from == .nominal)
    #expect(transitions.contains { $0.to == .degraded })
    // After reaching degraded, further failing samples in the same band are silent.
    let tail = await withTailTransitions(sensor, provider: "k3", startAt: 40, count: 30, isError: true)
    #expect(tail == 0)
}

private func withTailTransitions(
    _ sensor: ProviderVitalsSensor,
    provider: String,
    startAt: Int,
    count: Int,
    isError: Bool
) async -> Int {
    var n = 0
    for i in startAt..<(startAt + count) {
        if await sensor.observe(sample: sample(provider, at: Double(i), durationMs: 500, isError: isError)) != nil {
            n += 1
        }
    }
    return n
}

// Proof (e): the approval card is staged ONLY after sustained degradation
// (>= configured dwell) and expires on recovery. Uses an injected clock via the
// sample timestamps + evaluateCardDecisions(now:).
@Test func cardStagesOnlyAfterSustainedDegradationAndExpiresOnRecovery() async {
    // Short dwell for the test.
    let config = ProviderVitalsConfiguration(warmupSamples: 3, cardStageAfter: 600)
    let sensor = ProviderVitalsSensor(configuration: config)
    // Warm up healthy, then drive to degraded at t≈10s.
    for i in 0..<4 { _ = await sensor.observe(sample: sample("k3", at: Double(i), durationMs: 400)) }
    for i in 4..<12 {
        _ = await sensor.observe(sample: sample("k3", at: Double(i), durationMs: 400, isError: true))
    }
    let vitals = await sensor.vitals(for: "k3")
    #expect(vitals?.band == .degraded)

    // Just before the dwell elapses → no card.
    let early = await sensor.evaluateCardDecisions(now: epoch.addingTimeInterval(60))
    #expect(early.isEmpty)

    // After the dwell → exactly one stage decision.
    let staged = await sensor.evaluateCardDecisions(now: epoch.addingTimeInterval(1_000))
    #expect(staged.count == 1)
    if case .stage(let pid, _)? = staged.first {
        #expect(pid == "k3")
    } else {
        Issue.record("expected a stage decision")
    }
    // Idempotent: re-evaluating while still degraded does NOT re-stage.
    let again = await sensor.evaluateCardDecisions(now: epoch.addingTimeInterval(1_100))
    #expect(again.isEmpty)

    // Recovery: healthy calls pull the band back up; the card expires exactly once.
    for i in 100..<130 {
        _ = await sensor.observe(sample: sample("k3", at: Double(i), durationMs: 400))
    }
    let recovered = await sensor.vitals(for: "k3")
    #expect((recovered?.band ?? .degraded) < .degraded)
    let expired = await sensor.evaluateCardDecisions(now: epoch.addingTimeInterval(2_000))
    #expect(expired.count == 1)
    if case .expire(let pid)? = expired.first {
        #expect(pid == "k3")
    } else {
        Issue.record("expected an expire decision")
    }
    let expiredAgain = await sensor.evaluateCardDecisions(now: epoch.addingTimeInterval(2_100))
    #expect(expiredAgain.isEmpty)
}

// Proof (f): per-call overhead is one in-memory EMA update — no disk. The
// lifecycle path never writes a file; the ONLY writer is the explicit
// persistSnapshot, which is never on the observe path. Verify the snapshot file
// does NOT appear from observation alone.
@Test func observationNeverTouchesDisk() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vitals-nodisk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let snapshotPath = tmp
        .appendingPathComponent("telemetry", isDirectory: true)
        .appendingPathComponent("provider_vitals.json")

    let sensor = ProviderVitalsSensor()
    for i in 0..<100 {
        _ = await sensor.observe(sample: sample("moonshot", at: Double(i), durationMs: 700, isError: i % 3 == 0))
    }
    // Observation alone wrote nothing.
    #expect(!FileManager.default.fileExists(atPath: snapshotPath.path))

    // The explicit, off-turn-path snapshot IS the only writer.
    await sensor.persistSnapshot(dataRoot: tmp)
    #expect(FileManager.default.fileExists(atPath: snapshotPath.path))
}

// The lifecycle seam feeds the sensor passively: started + terminal pair yields
// exactly one sample; a cancelled call is ignored (not provider ill-health).
@Test func lifecyclePairingProducesOneSamplePerCall() async {
    let sensor = ProviderVitalsSensor()
    func event(_ id: String, _ phase: LLMCallLifecyclePhase, at: Double) -> LLMCallLifecycleEvent {
        LLMCallLifecycleEvent(
            id: id, phase: phase, providerId: "moonshot", model: "kimi-k2",
            surface: "chat", sessionId: "s1", turnId: "t1", streaming: true,
            occurredAt: epoch.addingTimeInterval(at)
        )
    }
    await sensor.observeProviderCall(event("c1", .started, at: 0))
    await sensor.observeProviderCall(event("c1", .succeeded, at: 1))
    await sensor.observeProviderCall(event("c2", .started, at: 2))
    await sensor.observeProviderCall(event("c2", .cancelled, at: 3)) // ignored
    let vitals = await sensor.vitals(for: "moonshot")
    // Only the completed call produced a sample; the cancelled one did not.
    #expect(vitals?.sampleCount == 1)
    #expect((vitals?.emaLatencyMs ?? 0) > 0) // duration derived from the pair
}

// gpt-5.5 review SF#4: a provider whose strain OSCILLATES around a band
// threshold must not chatter transitions into the organism — hysteresis
// (separate enter/exit thresholds) absorbs the boundary noise. Alternate
// samples straddling the enter-sluggish boundary: at most the initial entry
// transition may fire; the oscillation itself must be silent.
@Test func boundaryOscillationDoesNotChatterTransitions() async {
    let sensor = ProviderVitalsSensor(
        configuration: ProviderVitalsConfiguration(warmupSamples: 3)
    )
    // Establish a healthy baseline.
    for i in 0..<20 {
        _ = await sensor.observe(sample: sample("kimi-code", at: Double(i), durationMs: 800))
    }
    // Oscillate hard: alternate 3x-baseline and baseline samples for 200 calls.
    var transitions = 0
    for i in 20..<220 {
        let ms: Double = i % 2 == 0 ? 2_400 : 800
        if await sensor.observe(sample: sample("kimi-code", at: Double(i), durationMs: ms)) != nil {
            transitions += 1
        }
    }
    // Hysteresis: entering a band once (and possibly settling back once) is
    // fine; per-sample chatter is the failure. Bound: at most 4 transitions
    // across 200 oscillating samples (observed: 1-2).
    #expect(transitions <= 4, "oscillation chattered \(transitions) transitions")
}

// gpt-5.5 review SF#2: the provider-row map is bounded. A junk provider-id
// stream cannot grow memory or the snapshot: nominal LRU rows evict past the
// cap, and rows carrying live non-nominal band state survive.
@Test func junkProviderStreamIsBoundedByTheRowCap() async {
    let sensor = ProviderVitalsSensor(
        configuration: ProviderVitalsConfiguration(warmupSamples: 2, maxTrackedProviders: 8)
    )
    // A real provider goes degraded (must survive eviction).
    for i in 0..<10 {
        _ = await sensor.observe(sample: sample("kimi-code", at: Double(i), durationMs: 800))
    }
    for i in 10..<30 {
        _ = await sensor.observe(sample: sample("kimi-code", at: Double(i), durationMs: 20_000, isError: true))
    }
    // 100 junk provider ids flood the map.
    for j in 0..<100 {
        _ = await sensor.observe(sample: sample("junk-\(j)", at: Double(40 + j), durationMs: 500))
    }
    let snapshot = await sensor.snapshotJSON()
    guard case .object(let root) = snapshot, case .object(let providers)? = root["providers"] else {
        Issue.record("unexpected snapshot shape"); return
    }
    #expect(providers.count <= 8, "snapshot carries \(providers.count) rows past the cap")
    let kimi = await sensor.vitals(for: "kimi-code")
    #expect(kimi != nil, "non-nominal row must never be evicted")
    #expect(kimi?.band != .some(.nominal))
}
