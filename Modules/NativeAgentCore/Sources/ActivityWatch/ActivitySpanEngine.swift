import Foundation

// MARK: - Clock seam

/// The watcher's only source of "now".
///
/// Injectable because the alternative is untestable: the real capture path
/// cannot be exercised on a locked machine (no window server, no AX), so the
/// span state machine has to be drivable from a scripted timeline instead. A
/// `ManualActivityClock` plus `ActivitySpanEngine` reproduces the live spans
/// exactly, because the live watcher runs the SAME engine — not a copy of it.
public protocol ActivityClock: Sendable {
    /// Seconds since the epoch. May jump backwards (NTP, manual set).
    func wallNow() -> Double
    /// Monotonic seconds. Never jumps backwards; does NOT advance across sleep.
    func monotonicNow() -> Double
}

public struct SystemActivityClock: ActivityClock {
    public init() {}

    public func wallNow() -> Double { Date().timeIntervalSince1970 }

    public func monotonicNow() -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_absolute_time()
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }
}

/// Test/simulation clock. Wall and monotonic advance independently so a
/// backwards wall step, or a sleep (wall advances, monotonic does not), can be
/// scripted exactly.
public final class ManualActivityClock: ActivityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Double
    private var monotonic: Double

    public init(wall: Double, monotonic: Double = 0) {
        self.wall = wall
        self.monotonic = monotonic
    }

    public func wallNow() -> Double {
        lock.lock(); defer { lock.unlock() }
        return wall
    }

    public func monotonicNow() -> Double {
        lock.lock(); defer { lock.unlock() }
        return monotonic
    }

    /// Both clocks advance together — ordinary time passing.
    public func advance(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        wall += seconds
        monotonic += seconds
    }

    /// Wall only. Models a clock adjustment (positive or NEGATIVE).
    public func stepWall(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        wall += seconds
    }

    /// Wall advances, monotonic does not: the machine was asleep.
    public func sleep(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        wall += seconds
    }
}

// MARK: - Input vocabulary

/// Everything that can move the span state machine.
///
/// This is the *whole* input surface. The live watcher translates NSWorkspace
/// notifications, AX observer callbacks and its 60 s tick into exactly these
/// cases and does no span reasoning of its own; a scripted timeline builds the
/// same cases directly. That is what makes the simulation load-bearing rather
/// than decorative.
public enum ActivityInputEvent: Sendable, Equatable {
    /// Frontmost app changed (or was seeded at start / after unlock).
    case activate(bundleId: String, appName: String, at: Double)
    /// An AX focus notification on the observed app.
    case focusEvent(at: Double)
    /// The frontmost window's title changed. `raw` is the UNREDACTED AX string
    /// and this is the ONLY place one is ever accepted — it is redacted before
    /// it can reach a span, and never logged.
    case titleChange(raw: String?, at: Double)
    /// The idle deadline elapsed (the tick read `secondsSinceLastEventType`).
    case idle(at: Double)
    case lock(at: Double)
    case unlock(at: Double)
    case sleep(at: Double)
    case wake(at: Double)
    /// The observed app quit, or the watcher is shutting down cleanly.
    case terminate(at: Double)
    /// The PROCESS died without a chance to close anything. Emits no close —
    /// the open row stays open and startup reconciliation owns it.
    case crash(at: Double)
    /// The 60 s liveness tick with nothing else to report.
    case heartbeat(at: Double)

    public var timestamp: Double {
        switch self {
        case .activate(_, _, let at), .focusEvent(let at), .titleChange(_, let at),
             .idle(let at), .lock(let at), .unlock(let at), .sleep(let at),
             .wake(let at), .terminate(let at), .crash(let at), .heartbeat(let at):
            return at
        }
    }
}

/// What the engine wants written. Deliberately mirrors `ActivitySpanStore`'s
/// write API one-to-one so applying a command is mechanical.
public enum ActivityStoreCommand: Sendable, Equatable {
    case open(ActivitySpan)
    case touch(id: String, at: Double)
    case heartbeat(id: String, at: Double)
    /// The open span learned its INITIAL title. Updates the row in place — it is
    /// explicitly NOT a window change, and must never split the span. See
    /// `handleTitleChange` for why this case has to exist.
    case retitle(id: String, titleRedacted: String?, at: Double)
    case close(id: String, reason: ActivityCloseReason, at: Double)
    /// A prior process left rows open. Close them at their own `last_seen_at`.
    case reconcileAbandoned
}

// MARK: - The state machine

/// THE span state machine. One copy, used by both the live watcher and the
/// simulator.
///
/// Invariants it exists to hold (build plan W1/W2/W3):
///
///  * every `open` has exactly one `close`, and `close_reason` says which path
///    closed it — except a `crash`, which by definition emits none and is
///    settled by `reconcileAbandoned` at next start;
///  * lock and sleep CLOSE the open span at the boundary and write NOTHING
///    until unlock/wake — while locked, AX returns plausible garbage (the P0
///    blocker), so silence is the only honest output;
///  * `last_seen_at` advances on EVERY processed event, not just the heartbeat;
///  * monotonic-safe: no emitted timestamp is ever earlier than the previous
///    one, so a backwards clock step or a sleep can neither invent nor rewind
///    duration. A new span's start is floored at the last emitted close.
///
/// It is a value type with no I/O, no AX, and no AppKit — which is why it can
/// be driven deterministically on a machine with a locked screen.
public struct ActivitySpanEngine: Sendable {
    /// Capture-thread view of the currently open span.
    public struct OpenSpan: Sendable, Equatable {
        public let id: String
        public let bundleId: String
        public let appName: String
        /// `var`, because a span's first title lands ON the span rather than
        /// splitting it (see `handleTitleChange`).
        public var titleRedacted: String?
        /// Whether this span's title has been DECIDED yet — tracked separately
        /// from the title's VALUE (gpt-5.5 BLOCKING, 2026-08-14).
        ///
        /// `titleRedacted == nil` cannot carry this, because nil is also a
        /// legitimate current title: a window with no AX title, or a title the
        /// redactor dropped entirely. Overloading it lost real window changes —
        /// "A" → nil → "B" split correctly at the nil, then treated "B" as the
        /// successor's INITIAL title and stamped it in place, mislabelling the
        /// whole nil-titled interval as "B" and swallowing the second change.
        public var titleSettled: Bool
        public let startedAt: Double
        public var lastSeenAt: Double
    }

    public private(set) var policy: ActivityPolicy
    public private(set) var openSpan: OpenSpan?
    /// True while locked, asleep, or session-inactive. Nothing is written.
    public private(set) var isGated: Bool
    /// Highest timestamp already emitted. The monotonic floor for everything.
    public private(set) var lastEmittedAt: Double
    /// Set by `.crash`; the next processed event emits `.reconcileAbandoned`.
    public private(set) var needsReconcile: Bool

    private var lockedByLock = false
    private var lockedBySleep = false
    private let tzOffsetMin: Int
    private let makeID: @Sendable () -> String

    public init(
        policy: ActivityPolicy,
        tzOffsetMin: Int = ActivitySpan.currentTZOffsetMinutes(),
        startedGated: Bool = false,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.policy = policy
        self.tzOffsetMin = tzOffsetMin
        self.openSpan = nil
        self.isGated = startedGated
        self.lockedByLock = startedGated
        self.lastEmittedAt = 0
        self.needsReconcile = false
        self.makeID = makeID
    }

    /// Swap the policy mid-flight (the user edited exclusions). If the app whose
    /// span is open just became excluded, that span closes immediately — the
    /// alternative is a row that keeps growing for an app the user just said to
    /// stop watching.
    public mutating func updatePolicy(_ next: ActivityPolicy, at: Double) -> [ActivityStoreCommand] {
        policy = next
        guard let span = openSpan else { return [] }
        if !next.allowsCapture(bundleID: span.bundleId) {
            return [closeCurrent(reason: .appChange, at: at)].compactMap { $0 }
        }
        // Titles just got switched off for this app: drop the title by closing
        // and reopening. Query-time filtering covers history; this covers now.
        if span.titleRedacted != nil, !next.allowsTitleCapture(bundleID: span.bundleId) {
            var commands: [ActivityStoreCommand] = []
            if let close = closeCurrent(reason: .windowChange, at: at) { commands.append(close) }
            // The successor's title is DECIDED by the policy that just landed:
            // it is nil, and it stays nil for as long as titles are off. A later
            // title (titles re-enabled) is therefore a genuine window change,
            // not this span learning its first title.
            commands.append(openNew(
                bundleId: span.bundleId, appName: span.appName,
                titleRedacted: nil, titleSettled: true, at: at
            ))
            return commands
        }
        return []
    }

    /// CAPTURE-TIME gate, exposed so the live watcher can ask BEFORE it makes an
    /// AX call. An excluded app's title is never read, not read-then-discarded.
    public func shouldCapture(bundleID: String) -> Bool {
        policy.allowsCapture(bundleID: bundleID)
    }

    /// Same, for the title read specifically.
    public func shouldReadTitle(bundleID: String) -> Bool {
        policy.allowsTitleCapture(bundleID: bundleID)
    }

    /// Startup: settle anything a prior process left open.
    public mutating func startupReconcile() -> [ActivityStoreCommand] {
        needsReconcile = false
        return [.reconcileAbandoned]
    }

    // MARK: Event processing

    public mutating func process(_ event: ActivityInputEvent) -> [ActivityStoreCommand] {
        var commands: [ActivityStoreCommand] = []
        if needsReconcile {
            needsReconcile = false
            commands.append(.reconcileAbandoned)
        }
        commands.append(contentsOf: handle(event))
        return commands
    }

    public mutating func process(_ events: [ActivityInputEvent]) -> [ActivityStoreCommand] {
        events.flatMap { process($0) }
    }

    private mutating func handle(_ event: ActivityInputEvent) -> [ActivityStoreCommand] {
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
            // Deliberately opens NOTHING. The live watcher re-seeds from the
            // frontmost app after unlock, which arrives as `.activate`. Guessing
            // here would resurrect a span for an app that may no longer be front.
            bump(at)
            return []

        case .wake(let at):
            lockedBySleep = false
            isGated = lockedByLock
            bump(at)
            return []

        case .terminate(let at):
            return [closeCurrent(reason: .quit, at: at)].compactMap { $0 }

        case .crash(let at):
            // NO close command. The row stays open with its last_seen_at, and
            // startup reconciliation closes it there and marks it `abandoned`.
            bump(at)
            openSpan = nil
            needsReconcile = true
            return []

        case .heartbeat(let at):
            guard !isGated, let span = openSpan else { return [] }
            let stamp = clamp(at)
            openSpan?.lastSeenAt = stamp
            // Liveness only — a heartbeat must NOT inflate event_count.
            return [.heartbeat(id: span.id, at: stamp)]
        }
    }

    private mutating func handleActivate(
        bundleId: String, appName: String, at: Double
    ) -> [ActivityStoreCommand] {
        // Nothing is written while locked or asleep. Not even a close: the span
        // was already closed at the boundary.
        guard !isGated else { return [] }

        // CAPTURE-TIME EXCLUSION. Checked before anything else touches this app.
        guard policy.allowsCapture(bundleID: bundleId) else {
            return [closeCurrent(reason: .appChange, at: at)].compactMap { $0 }
        }

        if let span = openSpan, span.bundleId == bundleId {
            // Re-activation of the same app is an event, not a new span.
            return handleTouch(at: at)
        }

        var commands: [ActivityStoreCommand] = []
        if let close = closeCurrent(reason: .appChange, at: at) { commands.append(close) }
        // Opened by an activation: the exclusion gate runs before any AX read,
        // so this span does not know its title yet. The next title to arrive is
        // its INITIAL title, whatever its value.
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

        // Not allowed to keep the title for this app? Then the change is still
        // evidence the human was doing something — record the event, drop the
        // string. `raw` dies here having never touched a struct or a log.
        guard policy.allowsTitleCapture(bundleID: span.bundleId) else {
            return handleTouch(at: at)
        }

        // REDACT AT THE SOURCE. Past this line no un-redacted title exists.
        let redacted = ActivityTitleRedaction.redact(raw)

        // A SPAN'S FIRST TITLE IS ITS INITIAL TITLE, NOT A WINDOW CHANGE
        // (live-run defect, 2026-08-14).
        //
        // A span opens on `.activate` with no title, because the exclusion gate
        // runs before any AX read. The live watcher then reads the title
        // MICROSECONDS later and feeds it back as `.titleChange`. Treating that
        // as a window change closed the just-opened span and opened a successor,
        // so every single app switch emitted a junk ZERO-LENGTH row: a 2-minute
        // run with 6 real switches produced 16 spans, 8 of them 0 s.
        //
        // The simulation missed it only because its script separated `activate`
        // from the first `titleChange` by 90 seconds — the split was visible but
        // looked like a plausible 90 s span rather than obvious garbage.
        //
        // The test is `titleSettled`, NOT `titleRedacted == nil` (gpt-5.5
        // BLOCKING, 2026-08-14): nil is a legitimate title value, so asking the
        // value whether the title is known confuses "not decided yet" with
        // "decided, and it is nil" — and silently swallows the next real window
        // change. Only a title arriving on a span whose title is already SETTLED
        // is a genuine window change.
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
        // The successor is born KNOWING its title — that is what the split was
        // for — even when that title is nil (a window with no AX title, or one
        // the redactor dropped). Marking it settled is what keeps the NEXT
        // title change a split rather than an in-place stamp.
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
        // Floored at the last emitted timestamp: a backwards clock step must not
        // let a new span start before the close that just happened.
        let start = clamp(at)
        let span = ActivitySpan(
            id: makeID(),
            startedAt: start,
            endedAt: nil,
            lastSeenAt: start,
            bundleId: bundleId,
            appName: appName,
            titleRedacted: titleRedacted,
            eventCount: 0,
            closeReason: nil,
            tzOffsetMin: tzOffsetMin
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
        let stamp = clamp(at)
        return .close(id: span.id, reason: reason, at: stamp)
    }

    /// The monotonic floor. Every emitted timestamp goes through here, so the
    /// emitted sequence is non-decreasing no matter what the wall clock does.
    /// A backwards step degenerates to a zero-length interval — never a negative
    /// one, and never a fabricated positive one.
    private mutating func clamp(_ at: Double) -> Double {
        var stamp = max(at, lastEmittedAt)
        if let span = openSpan { stamp = max(stamp, span.lastSeenAt) }
        lastEmittedAt = stamp
        return stamp
    }

    /// Advance the floor without emitting anything (unlock/wake/crash).
    private mutating func bump(_ at: Double) {
        lastEmittedAt = max(lastEmittedAt, at)
    }
}
