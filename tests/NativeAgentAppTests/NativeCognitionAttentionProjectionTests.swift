import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

private actor PursuitProjectionLoaderProbe {
    private let state: DeskState
    private var blockAfterFirst = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(state: DeskState) {
        self.state = state
    }

    func blockSubsequentLoads() {
        blockAfterFirst = true
    }

    func load() async throws -> DeskState {
        callCount += 1
        if blockAfterFirst, callCount > 1 {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return state
    }

    func release() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

@Suite("Native cognition attention projection", .serialized)
struct NativeCognitionAttentionProjectionTests {
    @Test func deskReplayAfterInvalidationNeverBlocksTurnAttention() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let why = "keep the resident pursuit in circulation"
        let done = "finish the bounded attention projection proof"
        let pursuit = Pursuit(
            why: why,
            evidence: PromotionDossier(citations: [
                .feltSalience(dates: ["2026-07-13", "2026-07-14"]),
            ]),
            doneLooksLike: done,
            abandonCondition: "stop after the proof"
        )
        let store = SwiftNativeDeskStore(dataRoot: root)
        _ = try await store.openPursuit(
            project: "attention",
            title: "resident projection proof",
            pursuit: pursuit
        )
        let probe = PursuitProjectionLoaderProbe(state: try await store.liveState())
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(),
            pursuitStateLoaderOverride: { try await probe.load() }
        )

        await runtime.bootstrap()
        let initial = await runtime.attentionSignals(at: Date())
        #expect(initial?.activeTask == why)
        #expect(await probe.callCount == 1)

        await probe.blockSubsequentLoads()
        let opsPath = root.appendingPathComponent("desk/desk_ops.jsonl")
        StoreChangeBus.shared.emit(StoreChange(store: .desk, path: opsPath))

        // 10s deadline, not 500ms: the positive step (the replay SHOULD start)
        // only needs the deadline to exceed worst-case scheduler noise under
        // full-suite parallelism; a green run breaks at the first 10ms poll.
        for _ in 0..<1000 {
            if await probe.callCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.callCount == 2)

        let started = ProcessInfo.processInfo.systemUptime
        let whileReplayBlocked = await runtime.attentionSignals(at: Date())
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        await probe.release()

        // Invalidation clears advisory pursuit state immediately, and the
        // detached canonical replay cannot occupy the runtime actor or turn.
        #expect(whileReplayBlocked?.activeTask == nil)
        // 1s, not 50ms: the claim is "the attention read did not await the
        // indefinitely-blocked replay load" — any finite bound with headroom
        // proves that (the structural claims above and callCount below carry
        // the mechanism), while a 50ms bound loses to scheduler noise under
        // full-suite parallelism.
        #expect(elapsed < 1.0)
        #expect(await probe.callCount == 2)
    }
}
