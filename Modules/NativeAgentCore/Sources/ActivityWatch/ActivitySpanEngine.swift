import Foundation

// Blueprint: | `ActivitySpanEngine.swift` | `ActivitySpanEngine.process`: capture state transitions, policy gates, source title redaction and store commands |

// MARK: - Clock

public struct SystemActivityClock: Sendable {
    public init() {}

    public func wallNow() -> Double { Date().timeIntervalSince1970 }

    public func monotonicNow() -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_absolute_time()
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }
}

// MARK: - Input vocabulary

public enum ActivityInputEvent: Sendable, Equatable {
    case activate(bundleId: String, appName: String, at: Double)
    case focusEvent(at: Double)
    /// Accept raw titles only here, redacting before they reach a span and never logging them.
    case titleChange(raw: String?, at: Double)
    case idle(at: Double)
    case lock(at: Double)
    case unlock(at: Double)
    case sleep(at: Double)
    case wake(at: Double)
    case terminate(at: Double)
    /// Observation loss supplies no evidence for later duration.
    case observationUnavailable
    case heartbeat(at: Double)
}

/// Mirror store commands one-to-one so the watcher only forwards effects.
public enum ActivityStoreCommand: Sendable, Equatable {
    case open(ActivitySpan)
    case touch(id: String, at: Double)
    case heartbeat(id: String, at: Double)
    /// Set the initial title in place; learning it must not split the span.
    case retitle(id: String, titleRedacted: String?, at: Double)
    case close(id: String, reason: ActivityCloseReason, at: Double)
    /// Close abandoned rows at their own last observation, never at restart time.
    case reconcileAbandoned
}

// MARK: - The state machine

/// Every open has one close; crash-abandoned rows settle at the next start.
/// Lock and sleep close at the boundary; locked AX data is unreliable, so write nothing until unlock/wake.
/// Every event advances last_seen_at; heartbeat alone is not sufficient.
/// Floor timestamps at the last emitted close so clock steps cannot invent or rewind duration.
public struct ActivitySpanEngine: Sendable {
    public struct OpenSpan: Sendable, Equatable {
        public let id: String
        public let bundleId: String
        public let appName: String
        /// The first title settles on the span without splitting it.
        public var titleRedacted: String?
        /// Tracks whether the title is decided; nil is a legitimate settled value.
        public var titleSettled: Bool
        public let startedAt: Double
        public var lastSeenAt: Double
    }

    public private(set) var policy: ActivityPolicy
    public private(set) var openSpan: OpenSpan?
    /// Locked, sleeping or inactive sessions must write nothing.
    public private(set) var isGated: Bool
    /// Floor all emitted timestamps at the highest one already emitted.
    public private(set) var lastEmittedAt: Double

    private var lockedByLock = false
    private var lockedBySleep = false
    public init(policy: ActivityPolicy) {
        self.policy = policy
        self.openSpan = nil
        self.isGated = false
        self.lastEmittedAt = 0
    }

    /// A newly excluded app closes immediately so its row cannot keep growing after consent is withdrawn.
    public mutating func updatePolicy(_ next: ActivityPolicy, at: Double) -> [ActivityStoreCommand] {
        policy = next
        guard let span = openSpan else { return [] }
        if !next.allowsCapture(bundleID: span.bundleId) {
            return [closeCurrent(reason: .appChange, at: at)].compactMap { $0 }
        }
        // Close and reopen to remove current title capture; query filtering separately protects history.
        if span.titleRedacted != nil, !next.allowsTitleCapture(bundleID: span.bundleId) {
            var commands: [ActivityStoreCommand] = []
            if let close = closeCurrent(reason: .windowChange, at: at) { commands.append(close) }
            // Policy-disabled titles are settled nil; re-enabling then produces a real window change.
            commands.append(openNew(
                bundleId: span.bundleId, appName: span.appName,
                titleRedacted: nil, titleSettled: true, at: at
            ))
            return commands
        }
        return []
    }

    /// Gate before AX; read-then-discard still reads excluded content.
    public func shouldCapture(bundleID: String) -> Bool {
        policy.allowsCapture(bundleID: bundleID)
    }

    public func shouldReadTitle(bundleID: String) -> Bool {
        policy.allowsTitleCapture(bundleID: bundleID)
    }

    /// Settle rows left open by a prior process before observing new activity.
    public func startupReconcile() -> [ActivityStoreCommand] {
        [.reconcileAbandoned]
    }

    // MARK: Event processing

    public mutating func process(_ event: ActivityInputEvent) -> [ActivityStoreCommand] {
        switch event {
        case .activate(let bundleId, let appName, let at):
            return handleActivate(bundleId: bundleId, appName: appName, at: at)

        case .focusEvent(let at):
            return handleTouch(at: at)

        case .titleChange(let raw, let at):
            return handleTitleChange(raw: raw, at: at)

        case .idle(let at):
            return [closeCurrent(reason: .idle, at: at)].compactMap { $0 }

        case .lock(let at):
            lockedByLock = true
            isGated = true
            return [closeCurrent(reason: .lock, at: at)].compactMap { $0 }

        case .sleep(let at):
            lockedBySleep = true
            isGated = true
            return [closeCurrent(reason: .sleep, at: at)].compactMap { $0 }

        case .unlock(let at):
            lockedByLock = false
            isGated = lockedBySleep
            // Wait for a fresh activation after unlock; guessing could resurrect an app that is no longer frontmost.
            bump(at)
            return []

        case .wake(let at):
            lockedBySleep = false
            isGated = lockedByLock
            bump(at)
            return []

        case .terminate(let at):
            return [closeCurrent(reason: .quit, at: at)].compactMap { $0 }

        case .observationUnavailable:
            guard let span = openSpan else { return [] }
            return [closeCurrent(reason: .observationUnavailable, at: span.lastSeenAt)].compactMap { $0 }

        case .heartbeat(let at):
            guard !isGated, let span = openSpan else { return [] }
            let stamp = clamp(at)
            openSpan?.lastSeenAt = stamp
            // Heartbeats prove liveness, never additional human events.
            return [.heartbeat(id: span.id, at: stamp)]
        }
    }

    private mutating func handleActivate(
        bundleId: String, appName: String, at: Double
    ) -> [ActivityStoreCommand] {
        // The boundary already closed the span; write nothing while locked or asleep.
        guard !isGated else { return [] }

        // Reject excluded apps before any capture processing.
        guard policy.allowsCapture(bundleID: bundleId) else {
            return [closeCurrent(reason: .appChange, at: at)].compactMap { $0 }
        }

        if let span = openSpan, span.bundleId == bundleId {
            // Same-app reactivation is an event, not a new span.
            return handleTouch(at: at)
        }

        var commands: [ActivityStoreCommand] = []
        if let close = closeCurrent(reason: .appChange, at: at) { commands.append(close) }
        // Activation precedes permitted AX reads, so the next title settles the initial value in place.
        commands.append(openNew(
            bundleId: bundleId, appName: appName,
            titleRedacted: nil, titleSettled: false, at: at
        ))
        return commands
    }

    private mutating func handleTouch(at: Double) -> [ActivityStoreCommand] {
        guard !isGated, let span = openSpan else { return [] }
        let stamp = clamp(at)
        openSpan?.lastSeenAt = stamp
        return [.touch(id: span.id, at: stamp)]
    }

    private mutating func handleTitleChange(raw: String?, at: Double) -> [ActivityStoreCommand] {
        guard !isGated, let span = openSpan else { return [] }

        // A disallowed title still proves an event; drop its string before any struct or log receives it.
        guard policy.allowsTitleCapture(bundleID: span.bundleId) else {
            return handleTouch(at: at)
        }

        // No raw title may cross this source-redaction boundary.
        let redacted = ActivityTitleRedaction.redact(raw)

        // Nil is a legitimate settled initial title.
        if !span.titleSettled {
            let stamp = clamp(at)
            openSpan?.titleRedacted = redacted
            openSpan?.titleSettled = true
            openSpan?.lastSeenAt = stamp
            return [.retitle(id: span.id, titleRedacted: redacted, at: stamp)]
        }

        guard redacted != span.titleRedacted else { return handleTouch(at: at) }

        var commands: [ActivityStoreCommand] = []
        if let close = closeCurrent(reason: .windowChange, at: at) { commands.append(close) }
        // A split successor already knows its title, including nil; later changes must split rather than stamp it.
        commands.append(openNew(
            bundleId: span.bundleId, appName: span.appName,
            titleRedacted: redacted, titleSettled: true, at: at
        ))
        return commands
    }

    // MARK: Span primitives

    private mutating func openNew(
        bundleId: String, appName: String, titleRedacted: String?,
        titleSettled: Bool, at: Double
    ) -> ActivityStoreCommand {
        // Floor the new start at the prior close so backwards clock steps cannot overlap spans.
        let start = clamp(at)
        let span = ActivitySpan(
            id: UUID().uuidString,
            startedAt: start,
            endedAt: nil,
            lastSeenAt: start,
            bundleId: bundleId,
            appName: appName,
            titleRedacted: titleRedacted,
            eventCount: 0,
            closeReason: nil,
            tzOffsetMin: ActivitySpan.tzOffsetMinutes(at: Date(timeIntervalSince1970: start))
        )
        openSpan = OpenSpan(
            id: span.id,
            bundleId: bundleId,
            appName: appName,
            titleRedacted: titleRedacted,
            titleSettled: titleSettled,
            startedAt: start,
            lastSeenAt: start
        )
        return .open(span)
    }

    private mutating func closeCurrent(
        reason: ActivityCloseReason, at: Double
    ) -> ActivityStoreCommand? {
        guard let span = openSpan else { return nil }
        openSpan = nil
        // Idle ends at the last input even if later heartbeats already advanced liveness.
        let stamp = reason == .idle || reason == .observationUnavailable
            ? max(span.startedAt, at) : clamp(at)
        return .close(id: span.id, reason: reason, at: stamp)
    }

    /// Except retrospective idle closure, floor emitted timestamps so backwards steps cannot fabricate duration.
    private mutating func clamp(_ at: Double) -> Double {
        var stamp = max(at, lastEmittedAt)
        if let span = openSpan { stamp = max(stamp, span.lastSeenAt) }
        lastEmittedAt = stamp
        return stamp
    }

    /// Unlock, wake and crash recovery advance the floor without emitting activity.
    private mutating func bump(_ at: Double) {
        lastEmittedAt = max(lastEmittedAt, at)
    }
}
