import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger row `substrate.observe` (fence core.substrate.field).
//
// `observe(_:)` is the CognitiveEventObserving conformance — the seam the app
// uses for wake and sleep (NativeCognitionRuntime.swift:587 and :1262). It
// discards ingest's `Bool`, so a lifecycle event rejected by the enabled /
// stakes / dedup guards leaves NO trace at all: no node, no receipt, no log.
// LIVE: exactly 1 appLifecycle node in a 256-node field, and nothing anywhere
// asserted that wake and sleep both land.
//
// It also routes to the DURABLE `ingest(_:)` rather than `ingestResident`, so
// each lifecycle event pays a synchronous SQLite write. That is a real cost,
// and it is also the guarantee — a sleep event must be on disk before the app
// dies. Both halves are pinned here, including the contrast with the deferred
// hot path, so a future "optimization" to ingestResident fails loudly instead
// of silently losing the last event before termination.
@Suite("ObserveLifecycle")
struct ObserveLifecycleTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
    }

    private func tempDataRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-observe-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Mirrors the production wake/sleep events exactly — same subject on both,
    /// which is why the live field holds ONE appLifecycle node rather than two.
    private func lifecycleEvent(
        id: String,
        kind: CognitiveEventKind,
        at when: Date
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: kind,
            subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
            sourceClass: .observed,
            occurredAt: when,
            summary: kind == .appWake ? "NativeAgent app launched or resumed" : "NativeAgent app is terminating",
            importance: 0.35
        )
    }

    @Test("wake AND sleep both land, durably, on the one app-lifecycle node")
    func wakeAndSleepBothLandDurably() async throws {
        let root = try tempDataRoot("durable")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let wakeAt = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Clock(wakeAt)
        let observer: any CognitiveEventObserving = CognitiveSubstrate(
            // backgroundMicrocyclesEnabled is ON deliberately: it is the flag
            // that would let a deferred route swallow these writes, so leaving
            // it off would make the durability assertions below pass for free.
            configuration: CognitiveConfiguration(
                enabled: true, persistenceEnabled: true, backgroundMicrocyclesEnabled: true),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }),
            store: store
        )

        await observer.observe(lifecycleEvent(id: "wake-1", kind: .appWake, at: wakeAt))

        // Durable BEFORE any microcycle runs — this is the whole point of
        // routing lifecycle through ingest rather than ingestResident.
        let afterWake = try await store.loadNodes()
        #expect(afterWake.count == 1)
        #expect(afterWake.first?.kind == .appLifecycle)
        #expect(afterWake.first?.lastActivatedAt == wakeAt)

        let sleepAt = wakeAt.addingTimeInterval(3_600)
        clock.set(sleepAt)
        await observer.observe(lifecycleEvent(id: "sleep-1", kind: .appSleep, at: sleepAt))

        let afterSleep = try await store.loadNodes()
        // Same subject → one node, re-activated. The sleep event landing is
        // observable as the advanced activation anchor; a silently rejected
        // sleep would leave the node frozen at the wake instant.
        #expect(afterSleep.count == 1)
        #expect(afterSleep.first?.lastActivatedAt == sleepAt)
        #expect(afterSleep.first?.id == afterWake.first?.id)
    }

    @Test("a replayed lifecycle event is inert")
    func replayedLifecycleEventIsInert() async throws {
        let root = try tempDataRoot("replay")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let wakeAt = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Clock(wakeAt)
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(enabled: true, persistenceEnabled: true),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }),
            store: store
        )

        let wake = lifecycleEvent(id: "wake-1", kind: .appWake, at: wakeAt)
        await substrate.observe(wake)
        clock.set(wakeAt.addingTimeInterval(600))
        await substrate.observe(wake)

        let nodes = try await store.loadNodes()
        #expect(nodes.count == 1)
        // The duplicate must not re-activate the node: dedup is supposed to be
        // inert across the whole owner, not merely at the field structure.
        #expect(nodes.first?.lastActivatedAt == wakeAt)
    }

    @Test("with cognition disabled, observe is a completely silent no-op")
    func observeIsSilentWhenDisabled() async throws {
        let root = try tempDataRoot("disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let wakeAt = Date(timeIntervalSince1970: 1_700_000_000)
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(enabled: false, persistenceEnabled: true),
            dependencies: CognitiveSubstrateDependencies(now: { wakeAt }),
            store: store
        )

        await substrate.observe(lifecycleEvent(id: "wake-1", kind: .appWake, at: wakeAt))

        // Documented, deliberate silence: observe throws away ingest's Bool, so
        // the ONLY evidence a lifecycle event was dropped is the absent node.
        #expect(try await store.loadNodes().isEmpty)
        #expect(await substrate.snapshot().nodes.isEmpty)
    }

    @Test("the resident hot path is deferred — the contrast that makes observe's durability real")
    func residentIngestDefersPersistenceUnlikeObserve() async throws {
        let root = try tempDataRoot("resident")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                backgroundMicrocyclesEnabled: true
            ),
            dependencies: CognitiveSubstrateDependencies(now: { at }),
            store: store
        )

        #expect(await substrate.ingestResident(
            lifecycleEvent(id: "wake-resident", kind: .appWake, at: at)) == true)
        // Resident admission is in memory now, on disk later (microcycle).
        #expect(await substrate.snapshot().nodes.count == 1)
        #expect(try await store.loadNodes().isEmpty)

        // observe, on the same configuration, is durable on return.
        await substrate.observe(lifecycleEvent(id: "sleep-durable", kind: .appSleep, at: at))
        #expect(try await store.loadNodes().count == 1)
    }
}
