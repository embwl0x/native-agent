import Agents
import BackgroundLoops
import ChatToolRuntime
import Cognition
import CognitiveSubstrate
import ContextFlow
import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `EngineMind.swift` | `MindLifetime`: the body's one mind, absent until setup; one serial owner of start, reset and close |

/// The agent's mind, owned by the body. Before setup has finished there is no mind: no runtime, no attention, no nerve, no stream, none of its
/// sources or clocks. One serial owner decides: a start makes the mind once and opens it whole; a reset closes it whole (stopping and joining
/// everything the start attached) before the identity is removed; every decision rechecks setup. Holders keep this owner, never a runtime: it
/// forwards turn cognition, provider evidence and inner-state reads to the running mind at use, and reads as no mind when none runs. `changes()`
/// runs across absence and presence (`mind:opened`, `mind:closed`, and the running mind's own changes between).
public final class MindLifetime: @unchecked Sendable {
    public let dataRoot: URL
    /// The one journal bus every mind of this body listens on, so tool clients made before a mind keep reaching the running one.
    public let journal = StudioJournalCognitiveBus()
    private let host: any CognitionHost
    private let contextFlow: NativeContextFlowRuntime
    private let lock = NSLock()
    private var present: (runtime: NativeCognitionRuntime, stream: MindStream)?
    private var makeStream: (@Sendable () -> MindStream)?
    /// Launch has brought the body up (the helpers' provider check is installed), so the mind's clocks may attach.
    private var bodyUp = false
    /// Quit has begun: no mind starts after this.
    private var ended = false
    /// Helpers attach and part times are followed once per process; the deliveries are attached and released with each mind.
    private var clockRegistered = false
    /// Start, reset and close run one at a time, in the order they were asked.
    private var last: Task<Void, Never>?
    private var watchers: [UUID: AsyncStream<NativeCognitionRuntimeChange>.Continuation] = [:]
    private var relay: Task<Void, Never>?
    private var revision: UInt64 = 0

    init(dataRoot: URL, host: any CognitionHost, contextFlow: NativeContextFlowRuntime) {
        self.dataRoot = dataRoot
        self.host = host
        self.contextFlow = contextFlow
    }

    /// The running mind, or nil: before setup has finished, while it opens, and after a reset closed it.
    public var runtime: NativeCognitionRuntime? { lock.withLock { present?.runtime } }
    /// The running mind's stream of thoughts and its night.
    var stream: MindStream? { lock.withLock { present?.stream } }

    /// The engine supplies the stream's contact clients once they exist; the body is made before them.
    func attach(stream: @escaping @Sendable () -> MindStream) { lock.withLock { makeStream = stream } }

    /// Changes that outlive any one mind: a watcher subscribed before setup sees the mind open, its changes, and its close.
    public func changes() -> AsyncStream<NativeCognitionRuntimeChange> {
        let id = UUID()
        let pair = AsyncStream<NativeCognitionRuntimeChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock { watchers[id] = pair.continuation }
        pair.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = lock.withLock { watchers.removeValue(forKey: id) }
        }
        return pair.stream
    }

    /// Launch: the body is up. From here the mind starts as soon as setup has finished.
    func bodyIsUp() async {
        lock.withLock { bodyUp = true }
        await reconcile()
    }

    /// The one decision, asked by launch once the body is up and by every setup transition (the shared refresh hook), always rechecking setup:
    /// setup finished with a mind running refreshes it; setup finished with none starts one (once launch has brought the body up); setup not
    /// finished closes a running mind.
    public func reconcile() async {
        await inTurn { [self] in await decide() }
    }

    /// A reset, in turn with every other decision: the running mind closes before `removeIdentity` runs, and the decision after it rechecks setup,
    /// so a reset that did not complete starts a new mind and a completed one leaves none.
    public func reset<T: Sendable>(_ removeIdentity: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome: Result<T, any Error> = await inTurn { [self] in
            _ = await drain()
            let outcome: Result<T, any Error>
            do { outcome = .success(try await removeIdentity()) } catch { outcome = .failure(error) }
            await decide()
            return outcome
        }
        return try outcome.get()
    }

    /// Quit: the running mind closes and no mind starts after it. With none running there is nothing to save.
    func end() async -> NativeCognitionSleepOutcome {
        lock.withLock { ended = true }
        return await inTurn { [self] in await drain() }
    }

    private func decide() async {
        let setupFinished = NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot)
        if let runtime {
            if setupFinished { _ = await runtime.refreshAfterOnboardingTransition() } else { _ = await drain() }
            return
        }
        guard setupFinished, let makeStream = lock.withLock({ bodyUp && !ended ? self.makeStream : nil }) else { return }
        await start(stream: makeStream())
    }

    private func start(stream: MindStream) async {
        let runtime = NativeCognitionRuntime(dataRoot: dataRoot, host: host, contextFlow: contextFlow, studioJournalBus: journal)
        // Subscribe before opening so the opening's own changes reach the watchers.
        let changes = await runtime.changes()
        await runtime.bootstrap()
        lock.withLock {
            present = (runtime, stream)
            relay = Task { [weak self] in
                for await change in changes { self?.tell(change) }
            }
        }
        tell(reason: "mind:opened")
        // Sources attach once the mind is there to take them: part wake's first presence edge (the person here or away now) reaches the rhythm,
        // which counts the person absent until an edge says otherwise.
        await attachSources()
        let nerve = BodyNerve(dataRoot: dataRoot)
        BackgroundLoopLifetimes.shared.receiveOrganPulses(felt: { await nerve.feel($0) })
        // One intake: every happening posted from here on is taken by this mind; the stream opens on what was owed meanwhile.
        Attention.install(runtime)
        let root = dataRoot
        await stream.open(attention: runtime, night: { attended in
            _ = await NativeAgentEngine.sleep(dataRoot: root, attended: attended)
        })
    }

    private func drain() async -> NativeCognitionSleepOutcome {
        guard let mind = lock.withLock({
            defer { present = nil }
            return present
        }) else { return .noMind }
        Attention.install(nil)
        BackgroundLoopLifetimes.shared.receiveOrganPulses()
        await mind.stream.close()
        await detachSources()
        let slept = await mind.runtime.sleep()
        // Entries filed while no mind runs stay durable in the journal; there is no mind to tell.
        await journal.install { _ in }
        lock.withLock {
            relay?.cancel()
            relay = nil
        }
        tell(reason: "mind:closed")
        return slept
    }

    private func attachSources() async {
        let root = dataRoot
        let first = lock.withLock { () -> Bool in
            defer { clockRegistered = true }
            return !clockRegistered
        }
        await EnginePartWake.shared.start(dataRoot: root)
        if first { await NativeAgentEngine.registerClockOwners(dataRoot: root) } else { await NativeAgentEngine.handleClockOwners(dataRoot: root) }
        await MainActor.run { EngineFrontSense.shared.start(dataRoot: root) }
    }

    private func detachSources() async {
        await EnginePartWake.shared.stop(forGood: false)
        await NativeAgentEngine.releaseClockOwners(dataRoot: dataRoot)
        await (await MainActor.run { EngineFrontSense.shared.detach() }).value
    }

    private func inTurn<T: Sendable>(_ step: @escaping @Sendable () async -> T) async -> T {
        let task: Task<T, Never> = lock.withLock {
            let previous = last
            let task = Task { () -> T in
                await previous?.value
                return await step()
            }
            last = Task { _ = await task.value }
            return task
        }
        return await task.value
    }

    private func tell(reason: String) {
        let change: NativeCognitionRuntimeChange = lock.withLock {
            revision &+= 1
            return NativeCognitionRuntimeChange(revision: revision, occurredAt: Date(), reason: reason)
        }
        tell(change)
    }

    private func tell(_ change: NativeCognitionRuntimeChange) {
        for watcher in lock.withLock({ Array(watchers.values) }) { watcher.yield(change) }
    }
}

/// Clients made at any time hold the owner and reach whichever mind runs when they act; with none running they read as no mind.
extension MindLifetime: CognitiveRuntimeProviding, LLMCallLifecycleObserving, InnerStateProviding {
    public func observe(_ event: CognitiveEvent) async {
        await runtime?.observe(event)
    }

    public func prepareTurnProjection(_ request: CognitiveCapsuleRequest, turn: Turn) async -> CognitionAtTurn {
        guard let runtime else { return CognitionAtTurn(fixedAt: Date(), capsule: nil, posture: nil) }
        return await runtime.prepareTurnProjection(request, turn: turn)
    }

    public func commitTurnProjection(_ projection: CognitionAtTurn, request: CognitiveCapsuleRequest, turn: Turn) async {
        await runtime?.commitTurnProjection(projection, request: request, turn: turn)
    }

    public func commitReplyFeeling(_ projection: CognitionAtTurn, request: CognitiveCapsuleRequest) async {
        await runtime?.commitReplyFeeling(projection, request: request)
    }

    public func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? {
        await runtime?.attentionSignals(at: date)
    }

    public func observeProviderCall(_ event: LLMCallLifecycleEvent) async {
        await runtime?.observeProviderCall(event)
    }

    public func innerStateReading(windowHours: Double, detail: CognitiveInnerStateReading.Detail, surface: String) async
        -> CognitiveInnerStateReading {
        guard let runtime else { return .unavailable(at: Date(), windowHours: windowHours, detail: detail) }
        return await runtime.innerStateReading(windowHours: windowHours, detail: detail, surface: surface)
    }

    public func nextNight() async throws -> JSONValue {
        guard let runtime else { throw PersistenceCoreError.ioFailure("The mind starts when setup finishes; there is no night to read yet.") }
        return try await runtime.nextNight()
    }
}
