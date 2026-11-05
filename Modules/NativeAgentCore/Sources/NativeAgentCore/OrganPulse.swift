import Foundation
import Synchronization

// Blueprint: | `OrganPulse.swift` | `OrganPulse` beats and recording hook; `OrganRecord` derives profile and deviation from the record's newest beats |

/// One beat of an organ: when its pass was judged, the outcome, note, what it yielded and its cadence. A fresh timestamp alone does not prove successful
/// work. BackgroundLoops writes beat details into the experience record and reads the newest 32 per organ. Every organ reaches it through this one hook —
/// TurnTrace sits below BackgroundLoops and cannot import it — which the app installs before anything can beat.
public struct OrganPulse: Sendable, Equatable {
    /// `held`: judged and held back (off, not due, waiting). `stopped`: the pass was cut short before it could judge (cancelled or shut down).
    public enum Outcome: String, Sendable { case worked, nothing, held, failed, stopped }

    public let organ: String
    public let at: Date
    public let outcome: Outcome
    public let note: String
    /// What the pass produced, when the organ counts it; nil when it does not.
    public let yield: Int?
    /// Nil for an organ that runs on events rather than a clock: it is never overdue.
    public let cadence: TimeInterval?

    public init(organ: String, at: Date, outcome: Outcome, note: String, yield: Int? = nil, cadence: TimeInterval?) {
        self.organ = organ
        self.at = at
        self.outcome = outcome
        self.note = note
        self.yield = yield
        self.cadence = cadence
    }

    /// A beat that repeats the organ's last beat word for word within this window is the same news seen again and writes nothing. A clocked organ's window
    /// is at most half its cadence, so its repeats still land before it could read as silent.
    public static let newsWindow: TimeInterval = 10 * 60

    public static func record(_ organ: String, _ outcome: Outcome, note: String = "", yield: Int? = nil, cadence: TimeInterval? = nil) {
        let at = Date()
        let words = [outcome.rawValue, note, yield.map(String.init) ?? ""].joined(separator: "\u{1F}")
        let window = cadence.map { min(newsWindow, $0 / 2) } ?? newsWindow
        let news = lastSaid.withLock { said in
            if let last = said[organ], last.words == words, at.timeIntervalSince(last.at) < window { return false }
            said[organ] = Said(words: words, at: at)
            return true
        }
        guard news else { return }
        let pulse = OrganPulse(organ: organ, at: at, outcome: outcome, note: note, yield: yield, cadence: cadence)
        sink.withLock { $0 }?(pulse)
    }

    private struct Said: Sendable { let words: String; let at: Date }
    private static let lastSaid = Mutex<[String: Said]>([:])

    /// Starts a `.held` note when the organ's clock stopped on purpose: such a pulse declares no cadence, is never overdue and is never felt. Same words as
    /// BackgroundLoops' `LoopTickOutcome.offPrefix`, which this target cannot import.
    public static let offPrefix = "off: "

    public var isOff: Bool { outcome == .held && note.hasPrefix(Self.offPrefix) }

    /// Overdue once it has missed a whole beat since `launchedAt`: one beat may land late by its own pass. An organ switched off or run on events never is.
    public func isOverdue(now: Date, launchedAt: Date) -> Bool {
        guard !isOff, let cadence else { return false }
        return now.timeIntervalSince(max(at, launchedAt)) > 2 * cadence
    }

    public static func recordOff(_ organ: String, because reason: String) {
        record(organ, .held, note: offPrefix + reason)
    }

    /// A clocked organ's clock just started. Recorded with its cadence, so an organ that never completes a pass still goes overdue.
    public static func recordStarting(_ organ: String, cadence: TimeInterval) {
        record(organ, .held, note: "starting", cadence: cadence)
    }

    /// A pass that counts what it found: anything found is work done, and the count is its yield.
    public static func record(_ organ: String, found: Int, note: String, cadence: TimeInterval? = nil) {
        record(organ, found > 0 ? .worked : .nothing, note: note, yield: found, cadence: cadence)
    }

    public static func install(_ receive: @escaping @Sendable (OrganPulse) -> Void) {
        sink.withLock { $0 = receive }
    }

    private static let sink = Mutex<(@Sendable (OrganPulse) -> Void)?>(nil)
}

/// One organ's record: its last beats, oldest first, and what they predict. Profile and deviation are derived from the beats on every read and never stored.
public struct OrganRecord: Sendable, Equatable {
    /// Beats kept per organ, so a busy organ never evicts another organ's beats.
    public static let capacity = 32
    /// Below this many beats an organ has no record to break: it can only be missed or fail.
    public static let precisionFloor = 5

    public let organ: String
    public let beats: [OrganPulse]
    public let latest: OrganPulse

    /// Nil for an empty ring: an organ with no beat has no record.
    public init?(organ: String, beats: [OrganPulse]) {
        guard let latest = beats.last else { return nil }
        self.organ = organ
        self.beats = beats
        self.latest = latest
    }

    /// What the record predicts: the interval it keeps, its usual outcomes and its usual yield when it works.
    public struct Profile: Sendable, Equatable {
        /// Median seconds between beats; nil with fewer than two beats.
        public let medianInterval: TimeInterval?
        public let outcomes: [OrganPulse.Outcome: Int]
        /// Median yield of worked beats that counted one; nil when none did.
        public let medianYield: Double?
    }

    public var profile: Profile {
        let intervals = zip(beats.dropFirst(), beats).map { $0.at.timeIntervalSince($1.at) }
        return Profile(medianInterval: Self.median(intervals),
                       outcomes: beats.reduce(into: [:]) { $0[$1.outcome, default: 0] += 1 },
                       medianYield: Self.median(Self.workedYields(beats)))
    }

    /// A beat the record did not predict, with its why in the words the agent feels. `since` and `size` name it: one deviation keeps its onset while it
    /// lasts, and its size grows with it (beats in the run, or whole cadences of silence).
    public struct Deviation: Sendable, Equatable {
        public enum Kind: String, Sendable, Codable { case missed, failed, stuck, offRecord }
        public let kind: Kind
        public let why: String
        public let since: Date
        public let size: Int
    }

    /// Nil when the body matches its record. An organ switched off is never felt.
    public func deviation(now: Date, launchedAt: Date) -> Deviation? {
        if latest.isOff { return nil }
        if latest.isOverdue(now: now, launchedAt: launchedAt), let cadence = latest.cadence {
            return Deviation(kind: .missed, why: "silent since \(Self.clock(latest.at, now: now)); it beats every \(Self.span(cadence))",
                             since: latest.at, size: Int(now.timeIntervalSince(max(latest.at, launchedAt)) / cadence))
        }
        if latest.outcome == .failed {
            let run = trailingRun { $0.outcome == .failed }
            return Deviation(kind: .failed, why: "failed \(Self.times(run, since: now)): \(latest.note)", since: run[run.startIndex].at, size: run.count)
        }
        guard beats.count >= Self.precisionFloor else { return nil }
        let held = trailingRun { $0.outcome == .held && !$0.isOff && $0.note == latest.note }
        if latest.outcome == .held, held.count >= 3 {
            return Deviation(kind: .stuck, why: "held \(Self.times(held, since: now)): \(latest.note)", since: held[held.startIndex].at, size: held.count)
        }
        guard let lastWorked = beats.lastIndex(where: { $0.outcome == .worked }), beats[lastWorked].yield == 0 else { return nil }
        let before = Self.workedYields(beats[..<lastWorked])
        guard before.count >= Self.precisionFloor, let usual = Self.median(before), usual > 0 else { return nil }
        return Deviation(kind: .offRecord, why: "produced nothing at \(Self.clock(beats[lastWorked].at, now: now)); it usually produces "
            + (usual.rounded() == usual ? String(Int(usual)) : String(format: "%.1f", usual)), since: beats[lastWorked].at, size: 1)
    }

    /// The newest beats that all match, oldest first.
    private func trailingRun(_ matches: (OrganPulse) -> Bool) -> ArraySlice<OrganPulse> {
        beats[(beats.lastIndex { !matches($0) }.map { $0 + 1 } ?? 0)...]
    }

    private static func workedYields(_ beats: some Sequence<OrganPulse>) -> [Double] {
        beats.compactMap { $0.outcome == .worked ? $0.yield.map(Double.init) : nil }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// "at 11:54" for one beat, "twice since 11:54" or "4 times since 11:54" for a run.
    private static func times(_ run: ArraySlice<OrganPulse>, since now: Date) -> String {
        guard let first = run.first else { return "" }
        let at = clock(first.at, now: now)
        switch run.count {
        case 1: return "at \(at)"
        case 2: return "twice since \(at)"
        default: return "\(run.count) times since \(at)"
        }
    }

    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    static func span(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<120: "\(Int(seconds)) seconds"
        case ..<7_200: "\(Int(seconds / 60)) minutes"
        case ..<172_800: "\(Int(seconds / 3_600)) hours"
        default: "\(Int(seconds / 86_400)) days"
        }
    }
}
