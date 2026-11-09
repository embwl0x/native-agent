import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PartTrial.swift` | `PartTrial`: the trial judge over two version tallies, decidability and the candidate test; pure, no I/O |

/// A trial is kept when its target surprise is confidently rarer than the kept self's and no reading is confidently worse.
/// Nothing expires by date: a trial without enough record stays open.
public enum PartTrial {
    /// One version's record: `runs.versions["<identity>@<v>"]` in abilities/state.json.
    public struct Tally: Sendable, Equatable {
        public var uses: Int
        /// For a part: error + cut.
        public var targetMisses: Int
        /// error + cut + every stored surprise kind.
        public var surprises: Int
        /// Model rounds of one turn that ran this version -> uses.
        public var rounds: [Int: Int]
        /// Turn-program recoveries away from this version.
        public var heals: Int
        /// An unreadable tally cannot decide a trial. Store reads report this gap before a production tally is made.
        public private(set) var accountingGap: String?

        public init(uses: Int, targetMisses: Int, surprises: Int, rounds: [Int: Int] = [:], heals: Int = 0) {
            (self.uses, self.targetMisses, self.surprises, self.rounds, self.heals) = (uses, targetMisses, surprises, rounds, heals)
        }

        /// Reads the version record's counters; a field that is absent counts nothing, a version with no record has no uses.
        public init(record: JSONValue?, heals: Int = 0) {
            guard let record else { self.init(uses: 0, targetMisses: 0, surprises: 0, heals: heals); return }
            do {
                let fields = try AbilityStore.accountingObject(record, field: "trial_tally")
                let counts = try AbilityStore.tallyCounters(fields, at: "trial_tally")
                self.init(uses: counts.uses, targetMisses: counts.misses, surprises: counts.surprises, rounds: counts.rounds, heals: heals)
            } catch {
                self.init(uses: 0, targetMisses: 0, surprises: 0, heals: heals)
                accountingGap = error.localizedDescription
            }
        }

        /// Mean model rounds over the uses that have rounds; nil when none do.
        public var meanRounds: Double? {
            guard valid else { return nil }
            let tries = rounds.values.reduce(0.0) { $0 + Double($1) }
            guard tries > 0 else { return nil }
            return rounds.reduce(0.0) { $0 + Double($1.key) * (Double($1.value) / tries) }
        }

        /// Of the uses that have rounds: how many ran more rounds than `mean`, of how many.
        func above(_ mean: Double) -> (hits: Int, tries: Int)? {
            guard valid else { return nil }
            var hits = 0, tries = 0
            for (round, uses) in rounds {
                let (next, overflow) = tries.addingReportingOverflow(uses)
                guard !overflow else { return nil }
                tries = next
                if Double(round) > mean {
                    let (next, overflow) = hits.addingReportingOverflow(uses)
                    guard !overflow else { return nil }
                    hits = next
                }
            }
            return (hits, tries)
        }
        var valid: Bool {
            guard accountingGap == nil, uses >= 0, targetMisses >= 0, targetMisses <= uses, surprises >= targetMisses, heals >= 0 else { return false }
            var total = 0
            for (round, count) in rounds {
                let (next, overflow) = total.addingReportingOverflow(count)
                guard round >= 0, count >= 0, !overflow, next <= uses else { return false }
                total = next
            }
            return true
        }
    }

    /// A lower confidence bound against the bar it must clear.
    public struct Reading: Sendable, Equatable {
        public let lower: Double
        public let bar: Double
        public var clears: Bool { lower > bar }
    }

    public struct Verdict: Sendable, Equatable {
        public enum Outcome: String, Sendable { case kept, setAside = "set_aside", open }
        public let outcome: Outcome
        /// The kept self's target miss rate; nil when the kept self has no uses (no baseline: the trial stays open).
        public let m0: Double?
        /// The trial's target hit rate against 1 - m0.
        public let target: Reading?
        /// The trial's surprise rate against the kept self's upper bound on its own.
        public let surprise: Reading?
        /// The trial's share of uses above the kept self's mean rounds against the kept self's upper bound on its own share; nil without rounds
        /// on the kept self.
        public let cost: Reading?
        public let heals: Int
    }

    public static func verdict(trial: Tally, kept: Tally) -> Verdict {
        guard trial.valid, kept.valid, kept.uses > 0 else { return Verdict(outcome: .open, m0: nil, target: nil, surprise: nil, cost: nil, heals: trial.heals) }
        let m0 = Double(kept.targetMisses) / Double(kept.uses)
        let target = Reading(lower: Expectation.lowerBound(hits: trial.uses - trial.targetMisses, tries: trial.uses), bar: 1 - m0)
        // Worse is two-sided: the trial's lower bound must clear the kept self's upper bound, since both records are samples.
        let surprise = Reading(lower: Expectation.lowerBound(hits: trial.surprises, tries: trial.uses),
                               bar: upperBound(hits: kept.surprises, tries: kept.uses))
        let cost = kept.meanRounds.flatMap { mean -> Reading? in
            guard let own = kept.above(mean), let tried = trial.above(mean) else { return nil }
            return Reading(lower: Expectation.lowerBound(hits: tried.hits, tries: tried.tries), bar: upperBound(hits: own.hits, tries: own.tries))
        }
        let worse = surprise.clears || cost?.clears == true || trial.heals > 0
        let outcome: Verdict.Outcome = worse ? .setAside : target.clears ? .kept : .open
        return Verdict(outcome: outcome, m0: m0, target: target, surprise: surprise, cost: cost, heals: trial.heals)
    }

    /// The fewest clean uses that keep a trial against miss rate `m0`: the smallest n with lowerBound(n, n) > 1 - m0.
    /// nil when no n up to `limit` decides it (m0 = 0 never does).
    public static func needed(m0: Double, limit: Int = 10_000) -> Int? {
        guard m0.isFinite, m0 > 0 else { return nil }
        func decides(_ n: Int) -> Bool { Expectation.lowerBound(hits: n, tries: n) > 1 - m0 }
        guard limit > 0, decides(limit) else { return nil }
        // lowerBound(n, n) rises with n, so the first deciding n is found by bisection.
        var low = 1, high = limit
        while low < high {
            let middle = low + (high - low) / 2
            if decides(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Wilson's upper hit-rate bound: one minus the lower bound of the misses, so both sides read through `Expectation` unchanged.
    static func upperBound(hits: Int, tries: Int) -> Double {
        1 - Expectation.lowerBound(hits: tries - min(max(0, hits), tries), tries: tries)
    }

    /// Surprise above the part's own record: the lower bound of the window's miss share clears the long-run miss rate.
    public static func rose(uses: Int, misses: Int, longRun: Double) -> Bool {
        Expectation.lowerBound(hits: misses, tries: uses) > longRun
    }
}
