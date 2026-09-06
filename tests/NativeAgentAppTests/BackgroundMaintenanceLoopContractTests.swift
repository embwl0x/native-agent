// Fence app.background — maintenance/retention loop factories.
//
// Ledger rows closed here:
//   app.background.loop.turn_trace_retention
//   app.background.loop.evolution_proposal_retention
//   app.background.loop.self_improvement_sweep
//   app.background.setting.selfImprovementEnabled
//   app.background.loop.rem_cycle  (lane RETIRED 2026-08-31 — the row is now
//     closed by the persona-resolver guard plus the retirement pin in
//     BackgroundLifecycleWiringContractTests)
//   app.background.heartbeat.intervalEnv
//
// Every one of these is a SILENT-failure surface: the loops report `.completed`
// (or `.skipped`) whether or not they did the work, so the only observable
// difference between "swept" and "silently no-opped on the wrong root" is the
// store on disk. Each test drives the APP-SIDE FACTORY (the thing that binds
// roots, gates, and injected closures) — not the Core type underneath — because
// the factory is where the wiring regressions land.

import Foundation
import Testing
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// MARK: - Helpers

private func maintenanceTempRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundMaintenance-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func dayName(_ daysAgo: Int, from now: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: day)
}

private struct ThrowingBackgroundLLM: LLMClient {
    struct Unroutable: Error, LocalizedError {
        var errorDescription: String? { "no provider is routable for this surface" }
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw Unroutable()
    }
}

/// Records whether the injected client was reached at all — the "silent zero"
/// probe: a gated-off loop must never touch the LLM, a gated-on one must.
private actor LLMCallRecorder {
    private(set) var calls = 0
    func bump() { calls += 1 }
}

private struct RecordingThrowingLLM: LLMClient {
    let recorder: LLMCallRecorder
    struct Unroutable: Error, LocalizedError {
        var errorDescription: String? { "no provider is routable for this surface" }
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        await recorder.bump()
        throw Unroutable()
    }
}

// MARK: - turn_trace_retention

@Suite("app.background maintenance loop contracts", .serialized)
struct BackgroundMaintenanceLoopContractTests {

    @Test("turn-trace retention prunes only expired day files and is idempotent")
    func turnTraceRetentionLoopPrunesExpiredDaysOnly() async throws {
        let root = try maintenanceTempRoot("turntrace")
        defer { try? FileManager.default.removeItem(at: root) }
        let traces = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)

        let now = Date()
        // Inside the 14-day window (kept) …
        let live = [dayName(0, from: now), dayName(3, from: now), dayName(13, from: now)]
        // … and outside it (pruned), one of them carrying an orphaned lock.
        let expired = [dayName(14, from: now), dayName(40, from: now)]
        for day in live + expired {
            try Data("{\"day\":\"\(day)\"}\n".utf8)
                .write(to: traces.appendingPathComponent("\(day).jsonl"))
        }
        try Data("".utf8).write(to: traces.appendingPathComponent("\(expired[0]).jsonl.lock"))
        // A non-date filename must never be guessed at.
        try Data("keep me".utf8).write(to: traces.appendingPathComponent("README.txt"))

        let before = try FileManager.default.contentsOfDirectory(atPath: traces.path).count
        #expect(before == 7)

        let loop: any LoopRunner = BackgroundLoopsAssembly.makeTurnTraceRetentionLoop(dataRoot: root)
        #expect(loop.loopId == "turn_trace_retention")
        #expect(loop.interval == 6 * 60 * 60)
        // A sweep that walks a whole traces tree must not be cancelled by the
        // scheduler's 300s default — but it must still be bounded.
        #expect(loop.tickTimeoutOverride == 60)

        let outcome = await loop.tickOutcome()
        guard case .completed = outcome else {
            Issue.record("first tick was not .completed: \(outcome)")
            return
        }

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: traces.path))
        // Strictly decreased, and by exactly the expired set + its lock.
        #expect(after.count == 4)
        for day in live {
            #expect(after.contains("\(day).jsonl"), "live day \(day) must survive the sweep")
        }
        for day in expired {
            #expect(!after.contains("\(day).jsonl"), "expired day \(day) must be removed")
        }
        #expect(!after.contains("\(expired[0]).jsonl.lock"), "the orphaned lock sidecar must go with its day")
        #expect(after.contains("README.txt"), "an unparseable filename is never guessed at")

        // Idempotence: a second tick removes nothing more — and says so.
        // (Sweep FIX 4: a no-op sweep is `.skipped`, never `.completed`; the
        // old `.completed` advanced the dormancy clock on every idle tick.)
        let second = await loop.tickOutcome()
        guard case .skipped(let reason, _) = second else {
            Issue.record("second tick was not .skipped: \(second)")
            return
        }
        #expect(reason.contains("nothing past any retention cutoff"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: traces.path)) == after)
    }

    @Test("turn-trace retention is bound to the passed root, not the default one")
    func turnTraceRetentionLoopIsRootScoped() async throws {
        // The whole silent-failure mode is "wrong root → clean success, nothing
        // pruned". An empty temp root has no turn_traces dir at all: the tick
        // must run without reaching for any other root, and report the honest
        // no-op (`.skipped`) rather than claiming a sweep it did not do.
        let root = try maintenanceTempRoot("turntrace-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let loop: any LoopRunner = BackgroundLoopsAssembly.makeTurnTraceRetentionLoop(dataRoot: root)
        let outcome = await loop.tickOutcome()
        guard case .skipped = outcome else {
            Issue.record("empty-root tick was not .skipped: \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("turn_traces").path))
    }

    // MARK: - evolution_proposal_retention

    @Test("evolution retention drops only expired terminal rows and preserves live ones")
    func evolutionProposalRetentionPrunesTerminalRowsOnly() async throws {
        let root = try maintenanceTempRoot("evolution")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("evolution", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        let old = iso.string(from: Date().addingTimeInterval(-60 * 24 * 3600))
        let recent = iso.string(from: Date().addingTimeInterval(-2 * 24 * 3600))

        func row(_ id: String, _ status: String, _ updatedAt: String) -> [String: Any] {
            [
                "id": id,
                "source": "weekly",
                "title": "title-\(id)",
                "evidence": "evidence-\(id)",
                "status": status,
                "createdAt": old,
                "updatedAt": updatedAt,
                "receipts": [],
            ]
        }

        // 2 expired terminal (must go), 1 recent terminal (stays — inside the
        // window), 1 expired NON-terminal (stays — never swept).
        let seeded: [[String: Any]] = [
            row("expired-verified", "verified", old),
            row("expired-denied", "denied", old),
            row("recent-reverted", "reverted", recent),
            row("expired-live", "proposed", old),
        ]
        try JSONSerialization.data(withJSONObject: seeded, options: [])
            .write(to: dir.appendingPathComponent("proposals.json"))

        let loop = BackgroundLoopsAssembly.makeEvolutionProposalRetentionLoop(dataRoot: root)
        #expect(loop.loopId == "evolution_proposal_retention")
        #expect(loop.interval == 7 * 24 * 60 * 60)

        let outcome = await loop.tickOutcome()
        guard case .completed(let result) = outcome else {
            Issue.record("first tick was not .completed: \(outcome)")
            return
        }
        // The count is the ONLY observable the receipt carries; pin it, otherwise
        // "swept 0" and "swept 2" are indistinguishable downstream.
        #expect(result == "evolution proposal sweep removed 2")

        let raw = try Data(contentsOf: dir.appendingPathComponent("proposals.json"))
        let parsed = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]] ?? []
        let ids = Set(parsed.compactMap { $0["id"] as? String })
        #expect(ids == ["recent-reverted", "expired-live"])
        // Live rows survive with their payload intact, not just their id.
        let live = parsed.first { $0["id"] as? String == "expired-live" }
        #expect(live?["evidence"] as? String == "evidence-expired-live")
        #expect(live?["status"] as? String == "proposed")

        // Idempotent re-tick: nothing left to remove, so the lane says it did
        // nothing (sweep FIX 4) instead of booking a success for "removed 0".
        let second = await loop.tickOutcome()
        guard case .skipped(let reason, _) = second else {
            Issue.record("second tick was not .skipped: \(second)")
            return
        }
        #expect(reason.contains("no terminal proposals"))
    }

    // MARK: - self_improvement_sweep + its enable gate

    @Test("the self-improvement key the loop reads is the key the settings switch writes")
    func selfImprovementGateKeyMatchesTheOnlyWriter() throws {
        // A rename on either side is completely silent: the loop just never
        // runs again. Pin the literal on both sides.
        let factory = try AppSourceScraping.appSource("BackgroundLoopsAssembly+Maintenance.swift")
        let view = try AppSourceScraping.appSource("SelfImprovementView.swift")
        #expect(factory.contains("UserDefaults.standard.bool(forKey: \"selfImprovementEnabled\")"))
        #expect(view.contains("@AppStorage(\"selfImprovementEnabled\")"))
        // And the writers of that key are exactly the audited surfaces. 2026-09-06:
        // 7531524f gave Setup a per-feature switch card that binds the SAME
        // literal on purpose ("Same keys the Subconscious section and the
        // Observatory bind, so no two surfaces can show different truth",
        // SetupFeatureRows.swift:19). The pin still fails on a rename (a drifted
        // key drops that file out of the set) and on an unaudited new writer.
        let appRoot = try AppSourceScraping.appSourcesRoot()
        let writers = try AppSourceScraping.swiftSourceContents(under: appRoot)
            .filter { $0.source.contains("@AppStorage(\"selfImprovementEnabled\")") }
            .map(\.file)
            .sorted()
        #expect(writers == ["SelfImprovementView.swift", "SetupFeatureRows.swift"],
                "found unexpected writers: \(writers)")
    }

    @Test("self-improvement sweep: gate off never calls the LLM, gate on surfaces a provider failure")
    func selfImprovementSweepGateAndFailurePropagation() async throws {
        let key = "selfImprovementEnabled"
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        // (a) gate OFF → skipped, and the LLM is never reached.
        let offRoot = try maintenanceTempRoot("selfimp-off")
        defer { try? FileManager.default.removeItem(at: offRoot) }
        defaults.set(false, forKey: key)
        let offRecorder = LLMCallRecorder()
        let offLoop = BackgroundLoopsAssembly.makeWeeklySelfImprovementLoop(
            dataRoot: offRoot,
            llm: RecordingThrowingLLM(recorder: offRecorder)
        )
        #expect(offLoop.loopId == "self_improvement_sweep")
        // A weekly LLM pass must not die on the scheduler's 300s default.
        #expect(offLoop.tickTimeoutOverride == 3600)
        let offOutcome = await offLoop.tickOutcome()
        guard case .skipped = offOutcome else {
            Issue.record("gate-off tick was not .skipped: \(offOutcome)")
            return
        }
        let offCalls = await offRecorder.calls
        #expect(offCalls == 0, "a disabled sweep must never reach the provider")

        // (b) gate ON with an unroutable provider → .failed, NOT a swallowed
        // .completed. This is the exact live regression the row names: a
        // mis-wired client fails every week with no card.
        let onRoot = try maintenanceTempRoot("selfimp-on")
        defer { try? FileManager.default.removeItem(at: onRoot) }
        defaults.set(true, forKey: key)
        let onRecorder = LLMCallRecorder()
        let onLoop = BackgroundLoopsAssembly.makeWeeklySelfImprovementLoop(
            dataRoot: onRoot,
            llm: RecordingThrowingLLM(recorder: onRecorder)
        )
        let onOutcome = await onLoop.tickOutcome()
        let onCalls = await onRecorder.calls
        #expect(onCalls == 1, "an enabled sweep must call the INJECTED client")
        guard case .failed(let message) = onOutcome else {
            Issue.record("gate-on tick with a throwing provider was not .failed: \(onOutcome)")
            return
        }
        #expect(!message.isEmpty)
        // The failed pass must roll its weekly marker back so the next tick
        // retries instead of silently consuming the week.
        let marker = onRoot.appendingPathComponent("self_improvement/last_weekly_run")
        let stamp = try? String(contentsOf: marker, encoding: .utf8)
        #expect((stamp ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "a failed pass must not leave a committed weekly stamp behind")
    }

    // MARK: - REM persona root (the `rem_cycle` loop was retired 2026-08-31)

    @Test("REM binds the resolved persona root, never a <dataRoot>/persona hardcode")
    func remUsesTheCanonicalPersonaResolver() throws {
        // The documented bug (NativeAgentPaths.swift) is REM mutating a phantom
        // persona dir the reader never reads. The durable guard is that the
        // resolver really diverges from <dataRoot>/persona when the env pins it
        // elsewhere, and that the REM owner feeds itself from the resolver.
        //
        // The app-side `makeREMCycleLoop` factory this used to scrape is GONE:
        // weekly REM has one owner now, the `nativeagent-weekly-rem`
        // TriggerScheduler job → NativeClient.runRem → SwiftNativeDreamREMCycle,
        // which resolves the persona root itself (DreamREMCycle.swift:486).
        // The app half that remains scrapable is that runRem never introduces a
        // persona path literal of its own.
        let dataRoot = try maintenanceTempRoot("rem-data")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let personaRoot = try maintenanceTempRoot("rem-persona")
        defer { try? FileManager.default.removeItem(at: personaRoot) }

        let env = ["NATIVE_AGENT_PERSONA_ROOT": personaRoot.path]
        let resolved = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot, environment: env)
        #expect(resolved.resolvingSymlinksInPath().standardizedFileURL.path
                == personaRoot.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(resolved.standardizedFileURL.path != dataRoot.appendingPathComponent("persona").path)
        // NativeAgentPaths delegates to the same resolver — one precedence chain.
        #expect(NativeAgentPaths.resolvePersonaRoot(dataRoot: dataRoot, env: env).standardizedFileURL.path
                == resolved.standardizedFileURL.path)

        let assembly = try AppSourceScraping.appSource("BackgroundLoopsAssembly+DreamsMemory.swift")
        #expect(!assembly.contains("static func makeREMCycleLoop"),
                "the duplicate rem_cycle lane is retired — reinstating it needs a fresh decision")
        let dream = try AppSourceScraping.appSource("NativeClient+DreamActions.swift")
        let runRem = try AppSourceScraping.functionBody(named: "runRem", in: dream)
        #expect(!runRem.contains("appendingPathComponent(\"persona\")"),
                "REM must never hardcode <dataRoot>/persona — that is the phantom-write bug")
    }

    // MARK: - heartbeat interval env

    @Test("heartbeat interval env: default when unset/invalid, honoured when valid, floored at 1s")
    func heartbeatIntervalEnvIsParsedWithABusyLoopFloor() async throws {
        let root = try maintenanceTempRoot("heartbeat")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "NATIVE_AGENT_HEARTBEAT_INTERVAL_SECONDS"
        let saved = ProcessInfo.processInfo.environment[key]
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
        }

        func interval(env value: String?) -> TimeInterval {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
            return BackgroundLoopsAssembly.makeHeartbeatLoop(
                dataRoot: root, llm: ThrowingBackgroundLLM()
            ).interval
        }

        #expect(interval(env: nil) == HeartbeatLoop.defaultInterval)
        #expect(interval(env: "60") == 60)
        #expect(interval(env: "1") == 1)
        // Below the floor / non-finite / unparseable all fall back rather than
        // producing a Task.sleep(0) busy loop hammering the LLM.
        #expect(interval(env: "0") == HeartbeatLoop.defaultInterval)
        #expect(interval(env: "0.5") == HeartbeatLoop.defaultInterval)
        #expect(interval(env: "-30") == HeartbeatLoop.defaultInterval)
        #expect(interval(env: "inf") == HeartbeatLoop.defaultInterval)
        #expect(interval(env: "twice daily") == HeartbeatLoop.defaultInterval)
        #expect(interval(env: "") == HeartbeatLoop.defaultInterval)
    }
}
