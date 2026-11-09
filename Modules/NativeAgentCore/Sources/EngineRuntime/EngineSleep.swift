import Foundation
import AuthoredCapabilities
import BackgroundWork
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `EngineSleep.swift` | `EngineSleep`: evidence-based trial and candidate readings, measured costs and explicit source gaps |

/// What surprised a part is what the agent may reshape at night. A source that cannot be read is a named gap of that source.
public enum EngineSleep {
    /// A candidate must be able to decide its trial within this span at its own use rate.
    static let decisionSpan: TimeInterval = 14 * 86_400
    /// The kept turn program is read from its turns over at most this span before its trial opened.
    static let keptSpan: TimeInterval = 28 * 86_400
    /// The longest line of the night's reading.
    static let lineLimit = 280
    static let turnCountUnit = "settled_turn_union"
    static let turnBaselineEvidence = "complete_traces_and_corrections"

    /// What one reading found, before it is shaped; `said` is the line each judged trial carries, `asked` one line per candidate.
    struct Findings {
        var revision: Bool
        var trials: [JSONValue] = []
        var candidates: [JSONValue] = []
        var skipped: [String: Int] = [:]
        var gaps: [JSONValue] = []
        var said: [String: String] = [:]
        var asked: [String] = []
        /// Turn-program trials whose kept self was read from the traces this time: the night keeps that record on the trial.
        var baselines: [(part: String, version: String, kept: PartTrial.Tally)] = []
    }

    /// Overnight revision is on unless the person turned it off.
    static var revision: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "selfImprovementEnabled") == nil || defaults.bool(forKey: "selfImprovementEnabled")
    }

    public static func read(dataRoot: URL, since: Date, through: Date) async throws -> JSONValue {
        guard since < through else {
            throw ToolFailureError("The night's window must start before it ends.", argumentPath: "since",
                accepted: "An ISO time before now.", effects: .none)
        }
        let window = await SurpriseReading.read(dataRoot: dataRoot, since: since, through: through)
        let found = await Self.findings(dataRoot: dataRoot, since: since, through: through, window: window)
        return .object(Self.reading(since: since, through: through, found))
    }

    /// The reading of one window over the traces already read for it.
    static func findings(dataRoot: URL, since: Date, through: Date, window: SurpriseReading) async -> Findings {
        var found = Findings(revision: Self.revision)
        func noteGaps(_ reading: SurpriseReading, _ span: String) {
            for gap in reading.gaps {
                var fields: [String: JSONValue] = ["source": .string(gap.source), "reading": .string(span)]
                if let unreadable = gap.unreadable { fields["unreadable"] = .int(Int64(unreadable)) }
                found.gaps.append(.object(fields))
            }
        }
        noteGaps(window, "window")
        let store = AbilityStore(dataRoot: dataRoot)
        let catalog: (files: [AbilityStore.File], retained: [AbilityStore.Slot: [String: AbilityStore.File]], states: [String: JSONValue])
        do { catalog = try store.catalog() } catch {
            found.gaps.append(Self.gap("abilities", reason: error.localizedDescription))
            return found
        }
        let current = catalog.retained[.current] ?? [:]

        for (id, value) in catalog.states.sorted(by: { $0.key < $1.key }) {
            guard let row = value.objectValue, let trial = row["trial"]?.objectValue else { continue }
            guard let version = trial["version"]?.stringValue, let keptKey = trial["kept"]?.stringValue else {
                found.gaps.append(Self.gap("trial", reason: "The saved trial lacks its version, kept version or opening time.", part: id))
                continue
            }
            var entry: [String: JSONValue] = ["part": .string(id), "version": .string(version), "kept": .string(keptKey)]
            entry["opened"] = trial["opened"]
            let versions = row["runs"]?.objectValue?["versions"]?.objectValue ?? [:]
            if let file = current[id], store.identity(file) == version {
                entry["kind"] = .string(file.kind.rawValue)
                let tried: PartTrial.Tally, kept: PartTrial.Tally
                if file.kind == .turn {
                    // The turn program is judged per turn from the traces: the trial's turns since it opened, the kept self's before it.
                    guard let opened = trial["opened"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601), opened < through,
                          let at = keptKey.firstIndex(of: "@") else {
                        found.gaps.append(Self.gap("trial", reason: "The saved trial lacks its version, kept version or opening time.", part: id))
                        continue
                    }
                    let born = versions[keptKey]?.objectValue?["first_seen"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601)
                    let from = born.map { max($0, opened.addingTimeInterval(-Self.keptSpan)) }
                    let sinceOpened = await SurpriseReading.read(dataRoot: dataRoot, since: opened, through: through)
                    noteGaps(sinceOpened, "trial")
                    // The kept self's turns are read from the traces once, while they still hold them, and kept on the trial by the night.
                    // A kept self first seen once its trial opened has no turns before it: no baseline, and the trial stays open.
                    let frozen = trial["kept_turns"]?.objectValue
                    if trial["kept_turns"] != nil, frozen == nil {
                        found.gaps.append(.object(["source": .string("trial_baseline"), "part": .string(id),
                            "reason": .string("frozen_turn_evidence_unknown")]))
                        entry["verdict"] = .string("unread")
                        found.trials.append(.object(entry))
                        continue
                    }
                    var before: SurpriseReading?
                    if frozen == nil, from == nil {
                        found.gaps.append(Self.gap("trial_baseline",
                            reason: "The kept version has no first_seen provenance.", part: id))
                        entry["verdict"] = .string("unread")
                        found.trials.append(.object(entry))
                        continue
                    }
                    if frozen == nil, let from, from < opened {
                        let read = await SurpriseReading.read(dataRoot: dataRoot, since: from, through: opened)
                        noteGaps(read, "kept_record")
                        before = read
                    }
                    guard !Self.unread(sinceOpened), !(before.map(Self.unread) ?? false) else {
                        entry["verdict"] = .string("unread")
                        found.trials.append(.object(entry))
                        continue
                    }
                    tried = Self.turnTally(sinceOpened, .turnProgram(version))
                    if let frozen {
                        guard frozen["counting"] == .string(Self.turnCountUnit),
                              frozen["evidence"] == .string(Self.turnBaselineEvidence),
                              let uses = frozen["uses"]?.exactIntegerValue, uses >= 0,
                              let misses = frozen["target_misses"]?.exactIntegerValue, (0...uses).contains(misses),
                              let surprises = frozen["surprises"]?.exactIntegerValue, (misses...uses).contains(surprises) else {
                            found.gaps.append(.object(["source": .string("trial_baseline"), "part": .string(id),
                                "reason": .string("frozen_turn_evidence_unknown")]))
                            entry["verdict"] = .string("unread")
                            found.trials.append(.object(entry))
                            continue
                        }
                        kept = PartTrial.Tally(uses: uses, targetMisses: misses, surprises: surprises)
                    } else {
                        kept = before.map { Self.turnTally($0, .turnProgram(String(keptKey[..<at]))) }
                            ?? PartTrial.Tally(uses: 0, targetMisses: 0, surprises: 0)
                        found.baselines.append((id, version, kept))
                    }
                } else {
                    do {
                        tried = try Self.partTally(versions[store.versionKey(file)])
                        kept = try Self.partTally(versions[keptKey])
                    } catch {
                        found.gaps.append(Self.accountingGap(id, error))
                        entry["verdict"] = .string("unread")
                        found.trials.append(.object(entry))
                        continue
                    }
                }
                let verdict = PartTrial.verdict(trial: tried, kept: kept)
                entry["verdict"] = .string(verdict.outcome.rawValue)
                entry["trial_record"] = Self.tally(tried)
                entry["kept_record"] = Self.tally(kept)
                entry["m0"] = verdict.m0.map(JSONValue.double)
                entry["target"] = verdict.target.map(Self.bound)
                entry["surprise"] = verdict.surprise.map(Self.bound)
                entry["cost"] = verdict.cost.map(Self.bound)
                entry["heals"] = .int(Int64(verdict.heals))
                found.said[id] = Self.said(id, verdict, tried: tried, kept: kept)
            } else if let next = catalog.retained[.next]?[id], store.identity(next) == version {
                entry["verdict"] = .string("waiting")
            } else {
                entry["verdict"] = .string("superseded")
            }
            found.trials.append(.object(entry))
        }
        guard found.revision else { return found }

        var debts = Set<String>()
        do {
            for debt in try await ExperienceStore.at(dataRoot).open() where RepairOwed.isOwed(debt) {
                if let operation = RepairDebt(debt).operation, operation.hasPrefix("part."), operation.count > 5 {
                    debts.insert(String(operation.dropFirst(5)))
                }
            }
        } catch { found.gaps.append(Self.gap("repair_owed", reason: error.localizedDescription)) }

        func runs(_ id: String) -> [String: JSONValue] {
            catalog.states[id]?.objectValue?["runs"]?.objectValue?["versions"]?.objectValue ?? [:]
        }
        // An ability is read from its record alone: the window is its current version's hours, in the record's own outcome classes.
        var considered = debts
        for (id, file) in current where file.kind != .turn {
            do {
                if try Self.hours(runs(id)[store.versionKey(file)], from: since, to: through).misses > 0 { considered.insert(id) }
            } catch { found.gaps.append(Self.accountingGap(id, error)) }
        }
        // The turn program's own kinds are read from the traces, per settled turn.
        let traced = !Self.unread(window)
        if let turn = current.values.first(where: { $0.kind == .turn }), window.misses(.turnProgram(store.identity(turn))) > 0 {
            considered.insert(turn.id)
        }
        var candidates: [(owed: Bool, rounds: Double?, id: String, value: JSONValue, line: String)] = []
        var span: SurpriseReading?
        for id in considered.sorted() {
            do {
            if catalog.states[id]?.objectValue?["trial"]?.objectValue != nil { found.skipped["open_trial", default: 0] += 1; continue }
            guard let file = current[id] else { found.skipped["gone", default: 0] += 1; continue }
            let key = store.versionKey(file), evidence = runs(id)[key]
            let record = try Self.partTally(evidence)
            let owner: SurpriseReading.Owner = file.kind == .turn ? .turnProgram(store.identity(file)) : .ability(id)
            let uses: Int, misses: Int, expected: Int
            // The record outside the window: what the window is compared against, in the same unit.
            let rest: (uses: Int, misses: Int)
            if file.kind == .turn {
                guard traced else { found.skipped["unread", default: 0] += 1; continue }
                guard let born = evidence?.objectValue?["first_seen"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601) else {
                    found.gaps.append(Self.gap("turn_provenance", reason: "The turn version has no first_seen provenance.", part: id))
                    continue
                }
                // The turn program's surprise is per turn: its version's turns before the window.
                let life = await SurpriseReading.read(dataRoot: dataRoot, since: born, through: since)
                noteGaps(life, "turn_program_record")
                guard !Self.unread(life) else { found.skipped["unread", default: 0] += 1; continue }
                if span == nil {
                    let read = await SurpriseReading.read(dataRoot: dataRoot, since: through.addingTimeInterval(-Self.decisionSpan), through: through)
                    noteGaps(read, "decision_span")
                    span = read
                }
                guard let decision = span, !Self.unread(decision) else { found.skipped["unread", default: 0] += 1; continue }
                (uses, misses, expected) = (window.uses[owner] ?? 0, window.misses(owner), decision.uses[owner] ?? 0)
                rest = (life.uses[owner] ?? 0, life.misses(owner))
            } else {
                (uses, misses) = try Self.hours(evidence, from: since, to: through)
                rest = (record.uses - uses, record.targetMisses - misses)
                // The part's own use rate: its current and previous versions' runs in the span.
                let from = through.addingTimeInterval(-Self.decisionSpan)
                let previous = try catalog.retained[.previous]?[id].map { try Self.hours(runs(id)[store.versionKey($0)], from: from, to: through).uses }
                expected = try Self.countSum(Self.hours(evidence, from: from, to: through).uses, previous ?? 0)
            }
            let longRun: Double? = rest.uses > 0 ? Double(rest.misses) / Double(rest.uses) : nil
            let owed = debts.contains(id)
            if !owed {
                guard let longRun else { found.skipped["no_baseline", default: 0] += 1; continue }
                guard PartTrial.rose(uses: uses, misses: misses, longRun: longRun) else { continue }
            }
            // Decidable only: the trial must be able to decide within the span at the part's own rates.
            let total = file.kind == .turn
                ? (uses: try Self.countSum(rest.uses, uses), misses: try Self.countSum(rest.misses, misses))
                : (uses: record.uses, misses: record.targetMisses)
            guard total.uses > 0, let needed = PartTrial.needed(m0: Double(total.misses) / Double(total.uses)), expected >= needed else {
                found.skipped["undecidable", default: 0] += 1; continue
            }
            let rounds = record.meanRounds.map { Double(misses) * $0 }
            var fields: [String: JSONValue] = [
                "part": .string(id), "kind": .string(file.kind.rawValue), "version": .string(key),
                "reason": .string(owed ? "repair_owed" : "surprise"),
                "uses": .int(Int64(uses)), "misses": .int(Int64(misses)),
                "lower": .double(Expectation.lowerBound(hits: misses, tries: uses)),
                "rounds_spent": rounds.map(JSONValue.double) ?? .null, "expected_uses": .int(Int64(expected)), "needed_uses": .int(Int64(needed)),
            ]
            // Corrections are a surprise kind of their own, read from the traces; an unread window reports none rather than zero.
            if traced { fields["corrected"] = .int(Int64(window.count(owner, kind: "corrected"))) }
            fields["long_run"] = longRun.map(JSONValue.double)
            let reason = owed ? "is owed a repair" : "surprised more than its record"
            let rate = longRun.map { "a long-run \(Self.percent($0)) miss rate" } ?? "no long-run record"
            let spent = rounds.map { String(format: "%.1f", $0) + " rounds" } ?? "unmeasured rounds"
            let line = "\(id) \(reason): \(misses) of \(uses) uses missed in this window against \(rate); the misses spent \(spent); "
                + "\(expected) uses expected within 14 days, \(needed) needed to decide a trial."
            candidates.append((owed, rounds, id, .object(fields), line))
            } catch { found.gaps.append(Self.accountingGap(id, error)) }
        }
        candidates.sort { left, right in
            if left.owed != right.owed { return left.owed }
            switch (left.rounds, right.rounds) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.id < right.id
            }
        }
        found.candidates = candidates.map(\.value)
        found.asked = candidates.map(\.line)
        return found
    }

    /// The turn program's tally from the traces, per settled turn: corrections are surprise, heals away from it count; cost is not judged.
    static func turnTally(_ reading: SurpriseReading, _ owner: SurpriseReading.Owner) -> PartTrial.Tally {
        let misses = reading.misses(owner)
        return PartTrial.Tally(uses: reading.uses[owner] ?? 0, targetMisses: misses, surprises: reading.surprisedUses(owner),
                               heals: reading.count(owner, kind: "healed"))
    }

    /// The line a judged trial carries: kept, with its record against the kept self's; set aside, with what is worse and the save that does it.
    static func said(_ id: String, _ verdict: PartTrial.Verdict, tried: PartTrial.Tally, kept: PartTrial.Tally) -> String? {
        switch verdict.outcome {
        case .kept:
            return "Kept \(id): \(max(0, tried.uses - tried.targetMisses)) of \(tried.uses) uses clean since its trial opened; "
                + "the kept self missed \(kept.targetMisses) of \(kept.uses)."
        case .setAside:
            var worse: [String] = []
            if verdict.surprise?.clears == true {
                worse.append("\(tried.surprises) surprises in \(tried.uses) uses against the kept self's \(kept.surprises) in \(kept.uses)")
            }
            if verdict.cost?.clears == true { worse.append("more of its uses ran past the kept self's mean rounds") }
            if verdict.heals > 0 { worse.append("\(verdict.heals) heals away from it") }
            return "Your trial of \(id) is confidently worse: " + worse.joined(separator: "; ")
                + ". To set it aside: ability.save {id:\"\(id)\", set_aside:true, why}."
        case .open:
            return nil
        }
    }

    /// The night's reading in the agent's words, numbers and part ids only: each trial closed tonight, each open trial judged set aside,
    /// each candidate, and one line for the gaps.
    static func lines(_ found: Findings, closed: [JSONValue]) -> [String] {
        var lines: [String] = []
        for case .object(let close) in closed {
            guard let part = close["part"]?.stringValue, let verdict = close["verdict"]?.stringValue else { continue }
            switch verdict {
            case "kept": if let line = found.said[part] { lines.append(line) }
            case "set_aside": lines.append("Closed the trial of \(part) as set aside: the kept self saved forward is its current version.")
            default: lines.append("Closed the trial of \(part) as \(verdict): its version under trial is no longer current or waiting.")
            }
        }
        for case .object(let entry) in found.trials where entry["verdict"]?.stringValue == "set_aside" {
            if let part = entry["part"]?.stringValue, let line = found.said[part] { lines.append(line) }
        }
        lines += found.asked
        var sources: [String] = []
        for case .object(let gap) in found.gaps {
            if let source = gap["source"]?.stringValue, !sources.contains(source) { sources.append(source) }
        }
        if !sources.isEmpty { lines.append("Unread tonight: " + sources.joined(separator: ", ") + "; what they hold is unknown, not zero.") }
        return lines.map { $0.count <= Self.lineLimit ? $0 : String($0.prefix(Self.lineLimit - 1)) + "…" }
    }

    static func percent(_ rate: Double) -> String { String(Int((rate * 100).rounded())) + "%" }

    /// Each part's folded surprise by kind; `unattributed` counts surprise no retained version was first seen by.
    static func folded(_ folded: [String: [String: Int]]) -> JSONValue {
        var parts: [String: JSONValue] = [:]
        for (part, counts) in folded {
            var fields: [String: JSONValue] = ["corrected": .int(Int64(counts["corrected"] ?? 0)), "slog": .int(Int64(counts["slog"] ?? 0))]
            if let unattributed = counts["unattributed"] { fields["unattributed"] = .int(Int64(unattributed)) }
            parts[part] = .object(fields)
        }
        return .object(parts)
    }

    /// The night's reading: the window's reading with whether the agent attends, its lines, the trials closed and the surprise folded.
    static func night(_ found: Findings, since: Date, through: Date, closed: [JSONValue], folded: [String: [String: Int]], attend: Bool) -> JSONValue {
        var fields = Self.reading(since: since, through: through, found)
        fields["attend"] = .bool(attend)
        fields["lines"] = .array(Self.lines(found, closed: closed).map(JSONValue.string))
        fields["closed"] = .array(closed)
        fields["folded"] = Self.folded(folded)
        return .object(fields)
    }

    /// Completed UTC hours only. The bucket containing `to` waits for the following window, whose lower boundary includes it in full.
    static func completedHour(_ at: Date) -> Date {
        Date(timeIntervalSince1970: floor(at.timeIntervalSince1970 / 3_600) * 3_600)
    }

    static func gap(_ source: String, reason: String, part: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["source": .string(source), "reason": .string(reason)]
        if let part { fields["part"] = .string(part) }
        return .object(fields)
    }

    static func accountingGap(_ part: String, _ error: Error) -> JSONValue {
        .object(["source": .string("part_accounting"), "part": .string(part), "reason": .string(error.localizedDescription)])
    }

    /// Store-owned validation keeps the saved failure on the non-throwing tally; the night must report it before using its counts.
    static func partTally(_ evidence: JSONValue?) throws -> PartTrial.Tally {
        let tally = PartTrial.Tally(record: evidence)
        if let gap = tally.accountingGap { throw accountingFailure(gap) }
        return tally
    }

    static func accountingFailure(_ words: String) -> ToolFailureError {
        ToolFailureError(words, effects: .none, code: "part_accounting_gap",
            instruction: "Read the named version's accounting and repair its cause without replacing the saved evidence.", recovery: .repair)
    }

    /// Window and cross-version totals are computed here; version evidence is validated by AbilityStore.
    static func countSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw accountingFailure("Accounting count overflow.") }
        return sum
    }

    static func hours(_ evidence: JSONValue?, from: Date, to: Date) throws -> (uses: Int, misses: Int) {
        _ = try partTally(evidence)
        let from = completedHour(from), to = completedHour(to)
        var total = (uses: 0, misses: 0)
        for (hour, bucket) in evidence?.objectValue?["hours"]?.objectValue ?? [:] {
            guard let start = NativeTimestampFormat.parseISO8601(hour + ":00:00Z"), let counts = bucket.objectValue else {
                throw accountingFailure("Unreadable accounting hour.")
            }
            guard start >= from, start < to else { continue }
            for (outcome, value) in counts {
                guard let n = value.exactIntegerValue, n >= 0 else { throw accountingFailure("Unreadable hourly count.") }
                total.uses = try countSum(total.uses, n)
                if ["error", "cut"].contains(outcome) { total.misses = try countSum(total.misses, n) }
            }
        }
        return total
    }

    /// Any missing trace detail or correction evidence leaves the comparison incomplete, never a verdict or a frozen baseline.
    static func unread(_ reading: SurpriseReading) -> Bool {
        reading.gaps.contains { $0.source == "turn_traces" || $0.source == "correction_ledger" }
    }

    static func tally(_ tally: PartTrial.Tally, counting: String? = nil, evidence: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["uses": .int(Int64(tally.uses)), "target_misses": .int(Int64(tally.targetMisses)),
            "surprises": .int(Int64(tally.surprises)), "mean_rounds": tally.meanRounds.map(JSONValue.double) ?? .null]
        if let counting { fields["counting"] = .string(counting) }
        if let evidence { fields["evidence"] = .string(evidence) }
        return .object(fields)
    }

    static func bound(_ reading: PartTrial.Reading) -> JSONValue {
        .object(["lower": .double(reading.lower), "bar": .double(reading.bar)])
    }

    /// Silence is a reading of every source: a named gap is never a quiet night.
    static func silent(_ found: Findings) -> Bool {
        found.gaps.isEmpty && found.candidates.isEmpty
            && found.trials.allSatisfy { ["open", "waiting"].contains($0.objectValue?["verdict"]?.stringValue ?? "") }
    }

    static func reading(since: Date, through: Date, _ found: Findings) -> [String: JSONValue] {
        [
            "since": .string(NativeTimestampFormat.plainZulu(since)), "through": .string(NativeTimestampFormat.plainZulu(through)),
            "parts_since": .string(NativeTimestampFormat.plainZulu(Self.completedHour(since))),
            "parts_through": .string(NativeTimestampFormat.plainZulu(Self.completedHour(through))),
            "revision": .string(found.revision ? "on" : "off"), "trials": .array(found.trials), "candidates": .array(found.candidates),
            "skipped": .object(found.skipped.mapValues { .int(Int64($0)) }), "gaps": .array(found.gaps), "silent": .bool(Self.silent(found)),
        ]
    }
}
