import Foundation
import Synchronization
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(AppKit) && os(macOS)
import AppKit
#endif
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
#endif
// Blueprint: | `MacAttention.swift` | `MacAttentionSessionStore` owns driver authority, synchronous physical takeover and optional bounded view sessions; `MacDriverBinding` owns held-input release, foreground/background authority and cancellation-independent settlement under the original driver generation; session stop/expiry leaves passive observation active, explicit handback revokes control |

public struct MacAttentionSnapshot: Sendable, Equatable {
    public let sessionId: String
    public let startedAt: Date
    public let expiresAt: Date
    public let sequence: Int64
    public let observedSequence: Int64
    public let userSequence: Int64
    public let observedUserSequence: Int64
    public let counts: [MacAttentionActivityKind: Int]
    public let lastActivity: MacAttentionActivity?
    public let latestViewId: String?
    public let timedOutWaiting: Bool
    public let driverAllowed: Bool
    public let driverGeneration: UInt64

    public var yieldRequired: Bool { !driverAllowed || userSequence > observedUserSequence }
    public var refreshRequired: Bool { sequence > observedSequence }

    public func toJSON() -> JSONValue {
        var countObject: [String: JSONValue] = [:]
        for kind in MacAttentionActivityKind.allCases {
            countObject[kind.rawValue] = .int(Int64(counts[kind, default: 0]))
        }
        var object: [String: JSONValue] = [
            "active": .bool(true),
            "session": .string(sessionId),
            "started_at": .string(NativeTimestampFormat.plainZulu(startedAt)),
            "expires_at": .string(NativeTimestampFormat.plainZulu(expiresAt)),
            "sequence": .int(sequence),
            "observed_sequence": .int(observedSequence),
            "user_sequence": .int(userSequence),
            "observed_user_sequence": .int(observedUserSequence),
            "yield_required": .bool(yieldRequired),
            "refresh_required": .bool(refreshRequired),
            "counts": .object(countObject),
            "view": latestViewId.map { .string($0) } ?? .null,
            "wait_timed_out": .bool(timedOutWaiting),
            "driver": .string(driverAllowed ? "agent" : "user"),
            "driver_generation": .int(Int64(clamping: driverGeneration)),
        ]
        if let lastActivity {
            var activity: [String: JSONValue] = [
                "kind": .string(lastActivity.kind.rawValue),
                "at": .string(NativeTimestampFormat.plainZulu(lastActivity.occurredAt)),
            ]
            if let x = lastActivity.pointerX, let y = lastActivity.pointerY {
                activity["pointer"] = .object(["x": .double(x), "y": .double(y)])
            }
            object["last_activity"] = .object(activity)
        } else {
            object["last_activity"] = .null
        }
        return .object(object)
    }
}

public enum MacAttentionActionPermission: Sendable, Equatable {
    case allowed
    case refused(reason: String, current: MacAttentionSnapshot?)
}

/// Inherited by an act and all of its effects; observation cannot renew it.
public enum MacDriverContext {
    @TaskLocal public static var binding: MacDriverBinding?
    /// The admitted action runs in an app in the back: it needs none of his
    /// cursor, keys, focus or screen. Off unless the action said so.
    @TaskLocal public static var background = false
    @TaskLocal static var inputStartCount = 0
    /// A watch's own binding keeps a pressed key down across its hands, until
    /// its key-up, its end or the person's input releases it (MacScreenWatch).
    @TaskLocal static var holdsAcrossCalls = false
}

public final class MacDriverBinding: @unchecked Sendable {
    public let generation: UInt64
    private let owner: MacAttentionSessionStore
    /// She held the Mac when this act began.
    private let granted: Bool
    private let handback: UInt64
    private let lock = NSLock()
    private var cancelled = false
    private var yielded = false
    private var postedEvents = 0
    private var releases: [String: @Sendable () -> Void] = [:]

    init(owner: MacAttentionSessionStore, generation: UInt64, granted: Bool, handback: UInt64) {
        self.owner = owner
        self.generation = generation
        self.granted = granted
        self.handback = handback
    }

    private var stopped: Bool { lock.withLock { cancelled } || Task.isCancelled }

    /// Her hands on his cursor, keys, focus or screen: his own input ends it.
    public var allowsEmission: Bool {
        guard !stopped else { return false }
        if owner.permitsDriver(generation) { return true }
        lock.withLock { yielded = true }
        return false
    }

    /// Work that moves none of his cursor, keys, focus or screen — an
    /// action admitted to run in an app in the back, her own Chrome tab —
    /// goes on while he uses the Mac. Explicit handback ends it in every session.
    public var allowsBackgroundEmission: Bool {
        guard granted, !stopped else { return false }
        if owner.permitsBackground(handback) { return true }
        lock.withLock { yielded = true }
        return false
    }

    /// He took the Mac back explicitly since this act began.
    public var handedBack: Bool { !owner.permitsBackground(handback) }

    /// The permission the admitted action needs: in the back, only hers.
    public var allowsAction: Bool { MacDriverContext.background ? allowsBackgroundEmission : allowsEmission }

    /// An effect that needed his cursor, keys, focus or screen was refused
    /// because he took the Mac.
    public var yieldedToPerson: Bool { lock.withLock { yielded } }

    var inputCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return postedEvents
    }

    func notePostedEvent() {
        lock.lock()
        postedEvents += 1
        lock.unlock()
        MacWorkContinuation.current?.actionStarted()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        releaseHeldInputs()
    }

    /// Releasing what the act held runs through `settle` with its own
    /// cancellation lifetime. Keep the original authority: physical takeover,
    /// explicit handback and shutdown still revoke this generation.
    public func settlementBinding() -> MacDriverBinding {
        MacDriverBinding(owner: owner, generation: generation, granted: granted, handback: handback)
    }

    func held(_ key: String, release: (@Sendable () -> Void)?) {
        lock.lock()
        releases[key] = release
        lock.unlock()
        owner.trackHeldInputs(self)
        if stopped || !owner.permitsDriver(generation) { releaseHeldInputs() }
    }

    func releaseHeldInputs() {
        lock.lock()
        let pending = Array(releases.values)
        releases.removeAll()
        lock.unlock()
        for release in pending { release() }
    }
}

/// The one ephemeral owner of driver authority and a bounded view session.
///
/// It stores no screenshots, text, key contents, history, or persona state.
/// It holds the driver generation, current session token, coarse activity
/// counters, and last fused-view id. Stop/expiry forgets the view session;
/// only an explicit physical handoff can grant driver authority again.
/// Passive driver observation deliberately outlives session stop/expiry: it
/// protects ordinary acts without a view session. Only terminal shutdown ends it.
public actor MacAttentionSessionStore {
    public static let shared = MacAttentionSessionStore(screenViewStore: .shared)

    public static let defaultDurationSeconds = 300
    public static let minimumDurationSeconds = 15
    public static let maximumDurationSeconds = 1_800
    public static let maximumWaitMilliseconds = 15_000

    private struct Session {
        let id: String
        let startedAt: Date
        let expiresAt: Date
        var sequence: Int64 = 0
        var observedSequence: Int64 = 0
        var userSequence: Int64 = 0
        var observedUserSequence: Int64 = 0
        var counts: [MacAttentionActivityKind: Int] = [:]
        var lastActivity: MacAttentionActivity?
        var latestViewId: String?
    }

    private struct Waiter {
        let after: Int64
        let continuation: CheckedContinuation<Void, Never>
        let timeoutTask: Task<Void, Never>
    }

    private let screenViewStore: MacScreenViewStore
    private var session: Session?
    private var sessionGeneration: UInt64 = 0
    private var observation: (any MacAXEffectObservation)?
    private var expiryTask: Task<Void, Never>?
    private var isShutDown = false
    private var waiters: [UUID: Waiter] = [:]
    private struct DriverState {
        var agentDriving = false
        var driverOpen = true
        var driverGeneration: UInt64 = 0
        /// Moves only on "let me take over" or a hand-back Stop, never on input.
        var handbackGeneration: UInt64 = 0
        weak var inputBinding: MacDriverBinding?
    }
    private nonisolated let driverState = Mutex(DriverState())
    private var driverObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var driverReturnWaiters: Set<UUID> = []

    public nonisolated func permitsDriver(_ generation: UInt64) -> Bool {
        driverState.withLock { $0.driverOpen && $0.agentDriving && generation == $0.driverGeneration }
    }

    nonisolated func permitsBackground(_ handback: UInt64) -> Bool {
        driverState.withLock { $0.driverOpen && handback == $0.handbackGeneration }
    }

    public nonisolated var currentDriverAllowed: Bool {
        driverState.withLock { $0.agentDriving }
    }

    nonisolated func trackHeldInputs(_ binding: MacDriverBinding) {
        driverState.withLock { $0.inputBinding = binding }
    }

    public nonisolated func takeUserControl() {
        let (changed, held) = driverState.withLock {
            let captured = ($0.agentDriving, $0.inputBinding)
            $0.agentDriving = false
            $0.driverGeneration &+= 1
            $0.inputBinding = nil
            return captured
        }
        held?.releaseHeldInputs()
        if changed { Task { await self.publishDriver() } }
    }

    public nonisolated func userHandoffGeneration() -> UInt64? {
        #if canImport(AppKit) && os(macOS)
        guard Thread.isMainThread, let event = NSApp.currentEvent,
              [.leftMouseUp, .keyDown].contains(event.type),
              let input = event.cgEvent, MacPersonInput.isPerson(input)
        else { return nil }
        return driverState.withLock { $0.driverGeneration }
        #else
        return nil
        #endif
    }

    /// Only the person's explicit UI handoff calls this, or a bind under the
    /// Full Mac they granted; never a tool or view on its own.
    public func giveAgentControl(userGeneration: UInt64) {
        ensureDriverObservation(eventSource: defaultMacAttentionEventSource())
        guard observation != nil else { return }
        let changed = driverState.withLock {
            guard $0.driverGeneration == userGeneration else { return false }
            $0.driverGeneration &+= 1
            $0.agentDriving = true
            return true
        }
        if changed { publishDriver() }
    }

    public func bindDriver(eventSource: any MacAttentionEventSource = defaultMacAttentionEventSource()) async -> MacDriverBinding {
        ensureDriverObservation(eventSource: eventSource)
        // Full Mac grants the next act; physical input revokes earlier bindings.
        // Input during the policy read prevents reacquiring foreground control;
        // background authority remains granted.
        let generation = makeDriverBinding().generation
        var granted = currentDriverAllowed
        if !granted, await Self.savedFullMac() {
            granted = true
            giveAgentControl(userGeneration: generation)
        }
        return makeDriverBinding(granted: granted)
    }

    /// Whether the composer's hand-back would change anything now: a Mac
    /// action has asked for the driver this run, the person holds it, and the
    /// posture is below Full Mac, or a turn is waiting for control to return.
    public func handoffWouldChange() async -> Bool {
        guard observation != nil, !currentDriverAllowed else { return false }
        if !driverReturnWaiters.isEmpty { return true }
        return !(await Self.savedFullMac())
    }

    private static func savedFullMac() async -> Bool {
        guard let snapshot = try? await SwiftNativeTrustCenter().loadAuthorizationSnapshotChecked(),
              let trust = MacControlPolicy.fromTrustPolicyObject(snapshot.policy).trustPolicy else { return false }
        return MacControlGate.fullMacActive(trust)
    }

    private nonisolated func makeDriverBinding(granted: Bool = false) -> MacDriverBinding {
        driverState.withLock {
            MacDriverBinding(owner: self, generation: $0.driverGeneration, granted: granted,
                             handback: $0.handbackGeneration)
        }
    }

    public func driverChanges(waitingForReturn: Bool = false) -> AsyncStream<UInt64> {
        guard !isShutDown else { return AsyncStream { $0.finish() } }
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        driverObservers[id] = continuation
        if waitingForReturn {
            driverReturnWaiters.insert(id)
            publishDriver()
        }
        continuation.yield(makeDriverBinding().generation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDriverObserver(id) }
        }
        return stream
    }

    private func removeDriverObserver(_ id: UUID) {
        driverObservers[id] = nil
        if driverReturnWaiters.remove(id) != nil { publishDriver() }
    }

    private func publishDriver() {
        guard !isShutDown else { return }
        let generation = makeDriverBinding().generation
        for observer in driverObservers.values { observer.yield(generation) }
    }

    private func ensureDriverObservation(eventSource: any MacAttentionEventSource) {
        guard !isShutDown, observation == nil, eventSource.isAvailable else { return }
        #if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)
        let coalescer = MacAttentionEventCoalescer()
        #endif
        observation = eventSource.start { [weak self] activity in
            // Revoke before hopping to the actor: a synchronous typing loop
            // must see physical input even while this actor is occupied.
            if activity.kind.isPhysicalUserInput { self?.takeUserControl() }
            #if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)
            guard coalescer.shouldEmit(kind: activity.kind, atUptime: ProcessInfo.processInfo.systemUptime) else { return }
            #endif
            Task { await self?.record(activity) }
        }
        // The first ask for the driver is news to the composer's hand-back.
        if observation != nil { publishDriver() }
    }

    public init(screenViewStore: MacScreenViewStore) {
        self.screenViewStore = screenViewStore
    }

    deinit {
        observation?.stop()
        expiryTask?.cancel()
        driverObservers.values.forEach { $0.finish() }
        for waiter in waiters.values {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    /// Terminal domain retirement, distinct from stopping a bounded view session.
    /// The engine drain owns calling this; no later bind/start reopens admission.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        driverState.withLock { $0.driverOpen = false; $0.handbackGeneration &+= 1 }
        takeUserControl()
        stopInternal()
        observation?.stop()
        observation = nil
        driverObservers.values.forEach { $0.finish() }
        driverObservers.removeAll()
        driverReturnWaiters.removeAll()
        await screenViewStore.invalidate()
    }

    @discardableResult
    public func start(
        durationSeconds: Int,
        now: Date,
        eventSource: any MacAttentionEventSource
    ) async -> MacAttentionSnapshot? {
        guard !isShutDown else { return nil }
        let startingDriverGeneration = makeDriverBinding().generation
        stopInternal()
        let startingSessionGeneration = sessionGeneration
        await screenViewStore.invalidate()
        guard sessionGeneration == startingSessionGeneration else { return nil }
        ensureDriverObservation(eventSource: eventSource)
        guard observation != nil, !Task.isCancelled,
              makeDriverBinding().generation == startingDriverGeneration else { return nil }
        let duration = max(
            Self.minimumDurationSeconds,
            min(durationSeconds, Self.maximumDurationSeconds)
        )
        let id = UUID().uuidString
        let expiresAt = now.addingTimeInterval(TimeInterval(duration))
        session = Session(id: id, startedAt: now, expiresAt: expiresAt)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self?.expire(sessionId: id)
        }
        return snapshot(timedOutWaiting: false)
    }

    public func status(now: Date) async -> MacAttentionSnapshot? {
        await expireIfNeeded(now: now)
        return snapshot(timedOutWaiting: false)
    }

    @discardableResult
    public func stopAttentionSession() async -> Bool {
        let wasActive = session != nil
        stopInternal()
        await screenViewStore.invalidate()
        return wasActive
    }

    public func revokeDriverControl() async {
        driverState.withLock { $0.handbackGeneration &+= 1 }
        takeUserControl()
        publishDriver()
        stopInternal()
        await screenViewStore.invalidate()
    }

    public func waitForActivity(
        sessionId: String,
        after sequence: Int64,
        timeoutMilliseconds: Int,
        now: Date
    ) async -> MacAttentionSnapshot? {
        await expireIfNeeded(now: now)
        guard session?.id == sessionId else { return nil }
        let waitMs = max(0, min(timeoutMilliseconds, Self.maximumWaitMilliseconds))
        var timedOut = false
        if session?.sequence ?? 0 <= sequence, waitMs > 0 {
            timedOut = await suspendUntilActivity(after: sequence, timeoutMilliseconds: waitMs)
        }
        await expireIfNeeded(now: Date())
        guard session?.id == sessionId else { return nil }
        return snapshot(timedOutWaiting: timedOut)
    }

    /// Marks one freshly captured fused view as the scene observed after all
    /// user activity up through `userSequence`.
    public func observed(
        sessionId: String,
        viewId: String,
        sequence: Int64,
        userSequence: Int64,
        now: Date
    ) async -> MacAttentionSnapshot? {
        await expireIfNeeded(now: now)
        guard var current = session, current.id == sessionId else { return nil }
        current.latestViewId = viewId
        current.observedSequence = min(current.sequence, max(0, sequence))
        current.observedUserSequence = min(current.userSequence, max(0, userSequence))
        session = current
        return snapshot(timedOutWaiting: false)
    }

    /// Rechecked before every emitted motor event. This is the effect-time
    /// human-takeover boundary, not merely a tool-entry check.
    public func permissionForAction(
        sessionId: String?,
        observedUserSequence: Int64?,
        now: Date
    ) async -> MacAttentionActionPermission {
        await expireIfNeeded(now: now)
        guard let binding = MacDriverContext.binding, binding.allowsAction else {
            return .refused(reason: Self.driverRefusal, current: snapshot(timedOutWaiting: false))
        }
        guard let current = session else { return .allowed }
        guard sessionId == current.id else {
            return .refused(
                reason: "attention_session_required: an explicit Mac attention session is active; "
                    + "act with its session and latest observed user sequence, or stop it",
                current: snapshot(timedOutWaiting: false)!
            )
        }
        // Work in the back never waits on his input (see MacDriverBinding).
        if MacDriverContext.background { return .allowed }
        if observedUserSequence != current.userSequence
            || current.observedUserSequence != current.userSequence {
            return .refused(
                reason: "human_takeover: physical user input occurred after the agent's last fused view; "
                    + "yield until the person explicitly returns Mac control",
                current: snapshot(timedOutWaiting: false)!
            )
        }
        guard current.observedSequence == current.sequence,
              current.latestViewId != nil else {
            return .refused(
                reason: "scene_changed: the active app or screen changed after the agent's last fused view; "
                    + "call mac_attention next before acting again",
                current: snapshot(timedOutWaiting: false)!
            )
        }
        return .allowed
    }

    /// Driver revocation happened synchronously at the observer. This actor
    /// projects the pulse into the current optional view session.
    func record(_ activity: MacAttentionActivity) async {
        await screenViewStore.invalidate()
        guard var current = session else { return }
        if activity.occurredAt >= current.expiresAt {
            stopInternal()
            await screenViewStore.invalidate()
            return
        }
        current.sequence += 1
        if activity.kind.isPhysicalUserInput { current.userSequence += 1 }
        current.counts[activity.kind, default: 0] += 1
        current.lastActivity = activity
        session = current

        // The frozen marks no longer describe the same scene. Physical input
        // additionally invokes human takeover; app activation requires a
        // refresh without falsely claiming the human caused it.
        await screenViewStore.invalidate()
        guard session?.id == current.id else { return }
        resumeReadyWaiters(sequence: current.sequence)
    }

    private func snapshot(timedOutWaiting: Bool) -> MacAttentionSnapshot? {
        guard let current = session else { return nil }
        let driver = makeDriverBinding()
        return MacAttentionSnapshot(
            sessionId: current.id,
            startedAt: current.startedAt,
            expiresAt: current.expiresAt,
            sequence: current.sequence,
            observedSequence: current.observedSequence,
            userSequence: current.userSequence,
            observedUserSequence: current.observedUserSequence,
            counts: current.counts,
            lastActivity: current.lastActivity,
            latestViewId: current.latestViewId,
            timedOutWaiting: timedOutWaiting,
            driverAllowed: driver.allowsEmission,
            driverGeneration: driver.generation
        )
    }

    /// Returns true when the wait ended only because the deadline elapsed.
    private func suspendUntilActivity(after sequence: Int64, timeoutMilliseconds: Int) async -> Bool {
        let id = UUID()
        let before = session?.sequence ?? sequence
        let owner = self
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if session == nil || (session?.sequence ?? 0) > sequence {
                    continuation.resume()
                    return
                }
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                        try Task.checkCancellation()
                    } catch { return }
                    await self?.resumeWaiter(id: id)
                }
                waiters[id] = Waiter(after: sequence, continuation: continuation, timeoutTask: timeoutTask)
            }
        } onCancel: {
            Task { await owner.resumeWaiter(id: id) }
        }
        return (session?.sequence ?? before) <= sequence
    }

    private func resumeWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume()
    }

    private func resumeReadyWaiters(sequence: Int64) {
        let ids = waiters.compactMap { id, waiter in waiter.after < sequence ? id : nil }
        for id in ids { resumeWaiter(id: id) }
    }

    private func expire(sessionId: String) async {
        guard session?.id == sessionId else { return }
        stopInternal()
        await screenViewStore.invalidate()
    }

    private func expireIfNeeded(now: Date) async {
        guard let current = session, now >= current.expiresAt else { return }
        stopInternal()
        await screenViewStore.invalidate()
    }

    private func stopInternal() {
        // Also supersede a start still awaiting screen invalidation.
        sessionGeneration &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        session = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    public static let driverRefusal = "human_takeover: the person used the Mac, so this action stopped. Under Full Mac, your next action reacquires control; otherwise ask them to use NativeAgent Mac chat > composer controls > Let [agent name] use the Mac."
}
