import Context
import Foundation
import MemoryV2
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, rows `contextflow.frozenTurn` (:612/:621),
// `contextflow.sleepWake` (:466/:471), `contextflow.prewarm` (:626) and the
// honest-reader half of `contextflow.setMode` / `contextflow.modeStatus`
// (:444/:453/:483).
//
// The shared silent failure across all four is SILENT ZERO: every one of them
// takes the `guard let coordinator else { return nil / return }` branch when
// ContextFlow is not started, and every caller reads that as "nothing to
// report" rather than "not measured". The frozen lane is the sharpest case —
// unlike `prepareContextTurn` it does NOT call `start()` first.
@Suite("Native ContextFlow runtime lifecycle", .serialized)
struct NativeContextFlowRuntimeLifecycleTests {
    private struct FixedEmbeddingProvider: EmbeddingProvider {
        let dimensions = 8
        let modelId = "contextflow-lifecycle-test"
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { text in
                var vector = [Float](repeating: 0, count: dimensions)
                vector[text.utf8.reduce(0) { ($0 + Int($1)) % dimensions }] = 1
                return vector
            }
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextflow-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRuntime(dataRoot: URL) -> NativeContextFlowRuntime {
        NativeContextFlowRuntime(
            dataRoot: dataRoot,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(
                embedder: FixedEmbeddingProvider(),
                storage: InMemoryMemoryStorage()
            )
        )
    }

    private func request() -> ContextTurnRequest {
        ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What is still open on the eval fence?",
            personaIDHint: "Agent"
        )
    }

    @Test("the frozen lane refuses with a TYPED error and never returns an empty packet")
    func frozenTurnFailsLoudRatherThanSilently() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(dataRoot: root)

        // Unlike `prepareContextTurn` (:572) this entry point does NOT call
        // start() first, so every replay/bench caller that reaches it before
        // launch completes gets this error rather than a silently absent packet.
        #expect(await runtime.frozenContextRevision() == nil)
        await #expect(throws: ContextTurnPreparationError.coordinatorNotStarted) {
            _ = try await runtime.prepareFrozenContextTurn(request())
        }

        await runtime.start()

        // Started, but this root has no compiled generation: the error CHANGES,
        // which is the only thing that distinguishes the two states.
        await #expect(throws: ContextTurnPreparationError.generationUnavailable) {
            _ = try await runtime.prepareFrozenContextTurn(request())
        }
        // CHARACTERIZATION of the silent half (ledger `contextflow.frozenTurn`):
        // `frozenContextRevision()` reads nil in BOTH states, so a caller that
        // consults only the revision cannot tell "not started" from "started
        // with nothing to freeze". The typed error is the honest reader.
        #expect(await runtime.frozenContextRevision() == nil)
        await runtime.stop()
    }

    @Test("wake reconciliation restarts a runtime that is not running")
    func reconcileAfterWakeRecoversAStoppedRuntime() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(dataRoot: root)

        // prepareForSleep on a never-started runtime is a no-op that must not
        // start anything (it would otherwise start ContextFlow at sleep time).
        await runtime.prepareForSleep()
        #expect(await runtime.health() == nil)

        await runtime.reconcileAfterWake()
        let health = await runtime.health()
        #expect(
            health?.started == true,
            "a post-wake reconcile must recover ContextFlow — otherwise every turn for the rest of the session drops to message-only context"
        )
        await runtime.stop()
    }

    @Test("a prewarm hint before start is dropped silently and starts nothing")
    func prewarmBeforeStartIsASilentDrop() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(dataRoot: root)

        await runtime.prewarm(kind: .toolResult, id: "read_file", terms: ["read_file", "chat"])

        // Characterized, not endorsed: three separate producers spend work
        // building hints that vanish here with no counter on either side. The
        // load-bearing property is that the drop is INERT — it must never
        // start the coordinator as a side effect of a prewarm hint.
        #expect(await runtime.health() == nil)
    }

    @Test("mode status reports off when an active runtime fails closed")
    func modeStatusCannotReportAFailedStart() async throws {
        // A root that cannot be created: `ContextSQLiteStore` throws and
        // `start()` takes its fail-closed branch.
        let unusable = URL(fileURLWithPath: "/dev/null/contextflow-\(UUID().uuidString)")
        let runtime = NativeContextFlowRuntime(
            dataRoot: unusable,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(
                embedder: FixedEmbeddingProvider(),
                storage: InMemoryMemoryStorage()
            )
        )

        await runtime.start()

        #expect(
            await runtime.health() == nil,
            "health() is the only reader that can distinguish started from failed-closed"
        )
        let status = await runtime.modeStatus()
        #expect(status.effectiveMode == .off)
        #expect(status.environmentManaged == false)
    }

    @Test("mode status shares the injected environment and setup posture used by start")
    func modeStatusMatchesResolvedRuntime() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "contextflow-mode-status-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ContextFlowMode.off.rawValue, forKey: NativeContextFlowConfiguration.modeDefaultsKey)
        let identity = root
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: true)
        try "# SOUL\nContextFlow lifecycle fixture."
            .write(to: identity.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        defaults.set("Fixture", forKey: "chatPersona")
        let memory = SwiftNativeMemoryV2(
            embedder: FixedEmbeddingProvider(), storage: InMemoryMemoryStorage()
        )
        let runtime = NativeContextFlowRuntime(
            dataRoot: root,
            memoryOverride: memory,
            environmentOverride: [NativeContextFlowConfiguration.modeEnvironmentKey: "shadow"],
            defaultsOverride: SendableUserDefaults(value: defaults),
            publicSafeModeOverride: false
        )
        await runtime.start()
        let status = await runtime.modeStatus()
        #expect(status.environmentManaged)
        #expect(status.setupForcedOff == false)
        #expect(status.effectiveMode == .shadow)
        let health = try #require(await runtime.health())
        #expect(health.mode == status.effectiveMode)
        #expect(health.registeredSourceCount > 0,
                "the selected fixture persona must populate the production source registry")
        await runtime.stop()

        let forced = NativeContextFlowRuntime(
            dataRoot: root,
            memoryOverride: memory,
            environmentOverride: [NativeContextFlowConfiguration.modeEnvironmentKey: "active"],
            defaultsOverride: SendableUserDefaults(value: defaults),
            publicSafeModeOverride: true
        )
        await forced.start()
        let forcedStatus = await forced.modeStatus()
        #expect(forcedStatus.setupForcedOff)
        #expect(forcedStatus.effectiveMode == .off)
        #expect(await forced.health() == nil)
    }

    @Test("sleep wake returns to the durable generation without a pinned lease")
    func sleepWakeRoundTripUsesDurableGeneration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(dataRoot: root)
        await runtime.start()
        let before = try #require(await runtime.health())
        await runtime.prepareForSleep()
        await runtime.reconcileAfterWake()
        let after = try #require(await runtime.health())
        #expect(after.activeArenaGenerationID == after.activeStoreGenerationID)
        #expect(after.activeStoreGenerationID == before.activeStoreGenerationID)
        #expect(after.arenaMetrics.activeLeaseCount == 0)
        #expect(after.arenaMetrics.pinnedGenerations.isEmpty)
        await runtime.stop()
    }
}
