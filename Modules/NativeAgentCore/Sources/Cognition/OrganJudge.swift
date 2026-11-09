import BackgroundLoops
import CognitiveSubstrate
import Foundation
import NativeAgentCore

// Blueprint: | `OrganJudge.swift` | `OrganJudge` beat law for the mind's judges; organ names of the clock owners; loop-shaped passes as beats |

/// The mind's judges beat through here. Judges re-judge their organs on every source edge, so the same decision recurs; `OrganPulse.record` keeps the one
/// news law for every organ: an unchanged outcome, note, yield and cadence writes nothing; live beats still show a stuck organ's run of holds.
public enum OrganJudge {
    /// Notes are the organ's own short words; a longer why is cut here so every beat stays a line.
    static let noteLimit = 200

    public static func beat(_ organ: String, _ outcome: OrganPulse.Outcome, note: String, yield: Int? = nil, cadence: TimeInterval? = nil) {
        OrganPulse.record(organ, outcome, note: String(note.prefix(noteLimit)), yield: yield, cadence: cadence)
    }

    /// A switched-off organ is held with the off prefix and no cadence: it is never overdue and never felt.
    public static func beatOff(_ organ: String, because reason: String) {
        beat(organ, .held, note: OrganPulse.offPrefix + reason)
    }

    /// A loop-shaped pass: completed work, a skip the organ chose (off, not needed, held back) or a failure. A health-neutral skip joined another tick or
    /// backed off and decides nothing of its own, so it writes no beat.
    public static func beat(_ organ: String, tick: LoopTickOutcome, yield: Int? = nil, cadence: TimeInterval?) {
        switch tick {
        case .completed(let result):
            beat(organ, .worked, note: result ?? "completed", yield: yield, cadence: cadence)
        case .skipped(let reason, _):
            if tick.isHealthNeutralSkip { return }
            if reason.hasPrefix(LoopTickOutcome.offPrefix) {
                beatOff(organ, because: String(reason.dropFirst(LoopTickOutcome.offPrefix.count)))
            } else if reason.hasPrefix(LoopTickOutcome.notNeededPrefix) {
                beat(organ, .nothing, note: String(reason.dropFirst(LoopTickOutcome.notNeededPrefix.count)), yield: yield, cadence: cadence)
            } else {
                beat(organ, .held, note: reason, cadence: cadence)
            }
        case .failed(let error):
            beat(organ, .failed, note: error, cadence: cadence)
        }
    }
}

extension MindClockVerb {
    /// The organ each clock owner beats as; these names key the organ's record, so they never change.
    public var organ: String {
        switch self {
        case .canon: "studio_canon"
        case .horizon: "horizon_expectations"
        case .rhythm: "person_rhythm"
        case .cross: "crossing"
        case .maintenance: "cognition_maintenance"
        case .residualRepair: "residual_repair"
        }
    }
}

extension NativeCognitionRuntime {
    /// The cognition loops' interval: maintenance, replay and reflection each tick daily, so each beats at least that often.
    public static let substrateClockCadence: TimeInterval = 24 * 60 * 60

    /// The residual clock's automatic decision for one owner. A hold that only waits for its own time re-arms the clock and is no beat; an asked run
    /// beats through `recordClockRun` instead.
    func beat(_ verb: MindClockVerb, _ result: MindClockResult) {
        guard !result.waits, let outcome = result.pulseOutcome else { return }
        OrganJudge.beat(verb.organ, outcome, note: result.why, yield: result.yield)
    }

    /// Why the mind's background clock is switched off, or nil while it runs. An explicit run needs only inner life on.
    func clockOffReason(explicit: Bool) -> String? {
        let configuration = Self.loadConfiguration(defaults: preferenceDefaults, environment: configurationEnvironment)
        if !configuration.enabled { return "inner life is off" }
        if !explicit && !configuration.backgroundMicrocyclesEnabled { return "background thinking is off" }
        return nil
    }
}
