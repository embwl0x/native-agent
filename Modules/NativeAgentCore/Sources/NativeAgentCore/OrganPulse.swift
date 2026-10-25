import Foundation
import Synchronization

// Blueprint: | `OrganPulse.swift` | `OrganPulse`: shared proof-of-pass values and installed recording hook; BackgroundLoops owns durable pulse records |

/// One organ's proof of life: when its pass last ran, what it came to, and how
/// often it promises to run. A pass that fails leaves no pulse, so its last one
/// ages until Doctor calls it overdue.
///
/// BackgroundLoops owns the record (the `pulses` key of the loop-state file).
/// Every organ reaches it through this one hook — TurnTrace sits below
/// BackgroundLoops and cannot import it — which the app installs before
/// anything can beat.
public struct OrganPulse: Sendable, Equatable {
    public enum Outcome: String, Sendable { case worked, nothing, skipped }

    public let organ: String
    public let at: Date
    public let outcome: Outcome
    public let note: String
    /// Nil for an organ that runs on events rather than a clock: it is never
    /// overdue.
    public let cadence: TimeInterval?

    public init(organ: String, at: Date, outcome: Outcome, note: String, cadence: TimeInterval?) {
        self.organ = organ
        self.at = at
        self.outcome = outcome
        self.note = note
        self.cadence = cadence
    }

    public static func record(_ organ: String, _ outcome: Outcome, note: String = "", cadence: TimeInterval? = nil) {
        let pulse = OrganPulse(organ: organ, at: Date(), outcome: outcome, note: note, cadence: cadence)
        sink.withLock { $0 }?(pulse)
    }

    /// Starts a `.skipped` note when the organ's clock stopped on purpose: such a
    /// pulse declares no cadence and is never overdue. Same words as
    /// BackgroundLoops' `LoopTickOutcome.offPrefix`, which this target cannot import.
    public static let offPrefix = "off: "

    public var isOff: Bool { outcome == .skipped && note.hasPrefix(Self.offPrefix) }

    /// Overdue once it has missed a whole beat since `launchedAt`: one beat may
    /// land late by its own pass. An organ switched off or run on events never is.
    public func isOverdue(now: Date, launchedAt: Date) -> Bool {
        guard !isOff, let cadence else { return false }
        return now.timeIntervalSince(max(at, launchedAt)) > 2 * cadence
    }

    public static func recordOff(_ organ: String, because reason: String) {
        record(organ, .skipped, note: offPrefix + reason)
    }

    /// A clocked organ's clock just started. Recorded with its cadence, so an
    /// organ that never completes a pass still goes overdue.
    public static func recordStarting(_ organ: String, cadence: TimeInterval) {
        record(organ, .skipped, note: "starting", cadence: cadence)
    }

    /// A pass that counts what it found: anything found is work done.
    public static func record(_ organ: String, found: Int, note: String, cadence: TimeInterval? = nil) {
        record(organ, found > 0 ? .worked : .nothing, note: note, cadence: cadence)
    }

    public static func install(_ receive: @escaping @Sendable (OrganPulse) -> Void) {
        sink.withLock { $0 = receive }
    }

    private static let sink = Mutex<(@Sendable (OrganPulse) -> Void)?>(nil)
}
