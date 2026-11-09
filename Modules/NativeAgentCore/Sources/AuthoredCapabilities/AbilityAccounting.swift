import CryptoKit
import Experiences
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityAccounting.swift` | Locked terminal evidence and learned-use accounting |
extension AbilityStore {
    /// Terminal accounting survives caller cancellation with its causal act. A run owns this once; projections do not manufacture run evidence.
    @concurrent public func settleRun(id: String, version: String, receipt: JSONValue, input: JSONValue?, dependencySnapshot: JSONValue? = nil,
        turn: Turn?, at: Date = Date()) async -> JSONValue {
        return await settle {
            var fields = receipt.objectValue ?? [:]
            fields["ability_run"] = .object(["id": .string(id), "version": .string(version),
                "at": .string(NativeTimestampFormat.fractionalZulu(at))])
            do {
                try Self.withLock {
                    let recorded = try accounting(id: id, turn: turn) {
                        // Observed contracts are evidence of this invocation, not a replacement for the candidate's sealed inputs.
                        if let snapshot = dependencySnapshot?.objectValue, try readFile(id: id, slot: .current) != nil,
                           let file = try [Slot.current, .previous].compactMap({ try readFile(id: id, slot: $0) }).first(where: { identity(
                               $0) == version }) {
                            let selected = version + "@" + String(file.metadata["version"]?.integer ?? 1)
                            let evidence = try readState()[id]?.objectValue?["runs"]?.objectValue?["versions"]?.objectValue?[selected]?.objectValue
                            let before = evidence?["dependencySnapshot"]?.objectValue ?? [:]
                            let sealed = file.metadata["candidate"]?.objectValue?["dependencyShapes"]?.objectValue ?? [:]
                            let changed = snapshot.keys.sorted().filter { action in
                                guard snapshot[action] != .null else { return false }
                                let prior = before[action].flatMap { $0 == .null ? nil : $0 } ?? sealed[action]
                                // No observation is not evidence that a schema changed.
                                return prior != nil && prior != .null && prior != snapshot[action]
                            }
                            fields["dependencySnapshot"] = .object(snapshot)
                            if !changed.isEmpty {
                                fields["refreshed"] = .array(changed.map { .string("""
                                    refreshed: \($0) schema changed; this ability's statically readable calls still fit; computed arguments are checked \
                                    at the door
                                    """) })
                            }
                        }
                        let recorded = try recordRunEvidence(id: id, version: version, receipt: .object(fields), input: input, nativeSense: nil, turn: turn)
                        return (recorded.written, recorded)
                    }
                    if !recorded.written {
                        fields.removeValue(forKey: "refreshed"); fields.removeValue(forKey: "dependencySnapshot")
                    }
                    if let upgrade = recorded.upgrade {
                        fields["upgrade"] = .string(upgrade)
                    }
                }
            } catch {
                fields.removeValue(forKey: "refreshed"); fields.removeValue(forKey: "dependencySnapshot")
                fields["accounting_error"] = .string(error.localizedDescription)
            }
            return .object(fields)
        }
    }
    /// The stem alone records terminal evidence, including peer-steered runs; repeated world stops signal reason@step once per upgrade.
    @discardableResult
    public func recordRun(id: String, version: String, receipt: JSONValue, input: JSONValue? = nil, nativeSense: JSONValue? = nil,
        turn: Turn?) throws -> String? {
        try accounting(id: id, turn: turn) {
            let recorded = try recordRunEvidence(id: id, version: version, receipt: receipt, input: input, nativeSense: nativeSense, turn: turn)
            return (recorded.written, recorded.upgrade)
        }
    }
    /// A turn's observed rounds count once in the histogram of the exact accounting version that ran.
    /// Not written when that version is no longer the current or previous file, or has no run evidence.
    public func recordRounds(id: String, version: String, rounds: Int, turn: Turn?) throws {
        guard rounds >= 0 else { throw Self.failure("Accounting rounds must be nonnegative for \(id)@\(version).") }
        try accounting(id: id, turn: turn) {
            try Self.withLock {
                guard let current = try readFile(id: id, slot: .current) else { return (false, ()) }
                var state = try readState(), row = state[id]?.objectValue ?? [:], runs = row["runs"]?.objectValue ?? [:]
                var versions = runs["versions"]?.objectValue ?? [:]
                guard try [current, readFile(id: id, slot: .previous)].compactMap({ $0 }).contains(where: { versionKey($0) == version }),
                      case .object(var evidence)? = versions[version] else { return (false, ()) }
                let key = version, field = "state.\(id).runs.versions.\(key).rounds"
                var histogram = try Self.accountingObject(evidence["rounds"], field: field)
                histogram[String(rounds)] = .int(try Self.increment(histogram[String(rounds)], field: field + "." + String(rounds)))
                evidence["rounds"] = .object(histogram); versions[key] = .object(evidence)
                runs["versions"] = .object(versions); row["runs"] = .object(runs); state[id] = .object(row)
                try writeState(state)
                return (true, ())
            }
        }
    }
    /// Surprise the stem attributes to a version after its run, counted by kind under that version's full key.
    public static let surpriseKinds: Set<String> = ["corrected", "slog"]
    /// Exact replay inputs, kept by the accounting owner until the night cursor durably covers them. They outlive trace/detail retention.
    public struct SurpriseWindow: Codable, Sendable, Equatable {
        public struct Fold: Codable, Sendable, Equatable {
            public let part: String
            public let version: String
            public var counts: [String: Int]
            public init(part: String, version: String, counts: [String: Int]) {
                self.part = part; self.version = version; self.counts = counts
            }
        }
        public let since: Date
        public let through: Date
        public let folds: [Fold]
        public let unattributed: [String: Int]
        public init(since: Date, through: Date, folds: [Fold], unattributed: [String: Int]) {
            self.since = since; self.through = through; self.folds = folds; self.unattributed = unattributed
        }
    }
    private var surpriseWindowURL: URL { root.appendingPathComponent(".night-fold.json") }

    public func pendingSurpriseWindow() throws -> SurpriseWindow? {
        try Self.withLock {
            let bytes: Data
            do {
                try Self.checkPath(surpriseWindowURL)
                guard let info = try Self.fileStatus(surpriseWindowURL) else { return nil }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 8 * 1_024 * 1_024 else {
                    throw Self.failure("Prepared surprise window must be a bounded regular file.")
                }
                try VerifiedPath.confirmNoSymlink(surpriseWindowURL)
                bytes = try Data(contentsOf: surpriseWindowURL)
            } catch { throw repairFailure(source: surpriseWindowURL, detail: error.localizedDescription) }
            do {
                let window = try JSONDecoder().decode(SurpriseWindow.self, from: bytes)
                guard window.since < window.through, window.since.timeIntervalSince1970.isFinite, window.through.timeIntervalSince1970.isFinite,
                      Set(window.folds.map { [$0.part, $0.version] }).count == window.folds.count,
                      window.folds.allSatisfy({ !$0.part.isEmpty && !$0.version.isEmpty && !$0.counts.isEmpty
                          && $0.counts.allSatisfy { Self.surpriseKinds.contains($0.key) && $0.value > 0 } }),
                      window.unattributed.values.allSatisfy({ $0 > 0 }) else { throw Self.failure("Invalid prepared surprise window.") }
                return window
            } catch { throw repairFailure(source: surpriseWindowURL, detail: error.localizedDescription) }
        }
    }

    public func prepareSurpriseWindow(_ window: SurpriseWindow) throws {
        try Self.withLock {
            if let pending = try pendingSurpriseWindow() {
                guard pending == window else { throw repairFailure(source: surpriseWindowURL, detail: "Another window is still owed.") }
                return
            }
            do {
                try Self.checkPath(root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let bytes = try JSONEncoder().encode(window)
                guard bytes.count <= 8 * 1_024 * 1_024 else { throw Self.failure("Prepared surprise window exceeds its byte bound.") }
                try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: surpriseWindowURL)
            } catch { throw repairFailure(source: surpriseWindowURL, detail: error.localizedDescription) }
        }
    }

    /// Called only after the durable night row covers this exact window. A failed removal leaves harmless replay inputs, never repeated counts.
    public func finishSurpriseWindow(_ window: SurpriseWindow) throws {
        try Self.withLock {
            guard let pending = try pendingSurpriseWindow() else { return }
            guard pending == window else { throw repairFailure(source: surpriseWindowURL, detail: "The prepared window changed before settlement.") }
            do { try FileManager.default.removeItem(at: surpriseWindowURL) }
            catch { throw repairFailure(source: surpriseWindowURL, detail: error.localizedDescription) }
        }
    }
    /// Fold a frozen, nonoverlapping night window into the exact version attributed at preparation. The counts and completed-through watermark
    /// commit together. Replaying a covered window writes nothing, even after that version leaves the executable slots.
    public func recordSurprises(id: String, version: String, counts: [String: Int], since: Date, through: Date, turn: Turn?) throws {
        guard since < through, !counts.isEmpty, counts.allSatisfy({ Self.surpriseKinds.contains($0.key) && $0.value > 0 }) else {
            throw Self.failure("A surprise fold needs a forward window and positive counts of corrected or slog.")
        }
        try accounting(id: id, turn: turn) {
            try Self.withLock {
                var state = try readState(), row = state[id]?.objectValue ?? [:], runs = row["runs"]?.objectValue ?? [:]
                var versions = runs["versions"]?.objectValue ?? [:]
                var evidence = try Self.accountingObject(versions[version], field: "state.\(id).runs.versions.\(version)")
                guard !evidence.isEmpty else { throw Self.failure("The prepared surprise fold's run evidence is unavailable for \(id)@\(version).") }
                if let saved = evidence["surprise_through"] {
                    guard let end = saved.stringValue.flatMap(NativeTimestampFormat.parseISO8601) else {
                        throw Self.failure("Invalid surprise watermark for \(id)@\(version).")
                    }
                    if through <= end { return (false, ()) }
                    guard since >= end else { throw Self.failure("Surprise fold overlaps a completed window for \(id)@\(version).") }
                }
                let field = "state.\(id).runs.versions.\(version).surprise"
                var surprise = try Self.accountingObject(evidence["surprise"], field: field)
                for (kind, count) in counts {
                    let prior: Int64
                    switch surprise[kind] {
                    case nil: prior = 0
                    case .int(let n)?: prior = n
                    default: throw Self.failure("Invalid surprise count at \(field).\(kind).")
                    }
                    let (next, overflow) = prior.addingReportingOverflow(Int64(count))
                    guard !overflow else { throw Self.failure("Surprise count overflow at \(field).\(kind).") }
                    surprise[kind] = .int(next)
                }
                evidence["surprise_through"] = .string(NativeTimestampFormat.plainZulu(through))
                evidence["surprise"] = .object(surprise); versions[version] = .object(evidence)
                runs["versions"] = .object(versions); row["runs"] = .object(runs); state[id] = .object(row)
                try writeState(state)
                return (true, ())
            }
        }
    }
    /// Hour buckets older than this are pruned at each run write.
    public static let hoursKept: TimeInterval = 28 * 86_400
    /// A version's accounting key: its identity (body digest when it has none) at its header version.
    public func versionKey(_ file: File) -> String {
        (identity(file) ?? file.bodyDigest) + "@" + String(file.metadata["version"]?.integer ?? 1)
    }
    /// A trial's verdicts and who reached each.
    public static let trialVerdicts: Set<String> = ["kept", "set_aside", "superseded"]
    public static let trialDeciders: Set<String> = ["agent", "person", "stem"]
    /// A trial lives while its version is current or waiting: it opens when its version is staged, and `reconcile` closes it whenever the files
    /// hold its version in neither slot. A draft that only waits changes nothing.
    public enum TrialChange: Sendable {
        /// `version` is the identity the version under trial has once kept; `kept` is the key of the version current when it opened.
        case open(version: String, kept: String, why: String, keptTurns: JSONValue? = nil)
        /// `version` was staged to set the open trial aside; the trial closes as set aside when that version becomes current.
        case settingAside(version: String, why: String?)
        /// Read the part's current and waiting files: a trial whose version is in neither closes, as set aside when its marked setting aside is
        /// current, else superseded, by `by`; a setting aside in neither slot is forgotten.
        case reconcile(by: String)
        /// The stem's own verdict on the open trial; a set aside's `why` is the closed trial's `set_aside_why`.
        case judged(verdict: String, why: String? = nil)
        /// The kept self's record as the trial of `version` read it the first time, kept on the open trial once: a turn program's turns live in
        /// traces that forget them past their horizon.
        case baseline(version: String, kept: JSONValue)
    }
    /// The stem alone writes a part's trial. Opening is refused while one is open; closing moves the open trial into `trials`, oldest first and at
    /// most inputLimit. Returns the trial as written, nil when the change did not apply (one already open, none open, or another version's).
    @discardableResult
    public func changeTrial(id: String, _ change: TrialChange, turn: Turn?) throws -> JSONValue? {
        switch change {
        case .reconcile(let by):
            guard Self.trialDeciders.contains(by) else { throw Self.failure("A trial is decided by \(Self.trialDeciders.sorted().joined(separator: ", ")).") }
        case .judged(let verdict, let why):
            guard Self.trialVerdicts.contains(verdict) else { throw Self.failure("A trial closes as \(Self.trialVerdicts.sorted().joined(separator: ", ")).") }
            guard why == nil || verdict == "set_aside" else { throw Self.failure("A judged why belongs to a set aside, not \(verdict).") }
        case .open, .settingAside, .baseline: break
        }
        return try accounting(id: id, turn: turn) {
            try Self.withLock {
                var state = try readState(), row = state[id]?.objectValue ?? [:]
                let at = NativeTimestampFormat.plainZulu(Date())
                func write(_ value: JSONValue?) throws -> (written: Bool, value: JSONValue?) {
                    state[id] = .object(row)
                    try writeState(state)
                    return (true, value)
                }
                if case .open(let version, let kept, let why, let keptTurns) = change {
                    guard row["trial"] == nil else { return (false, nil) }
                    var fields: [String: JSONValue] = ["version": .string(version), "kept": .string(kept), "why": .string(why), "opened": .string(at)]
                    fields["kept_turns"] = keptTurns
                    let trial = JSONValue.object(fields)
                    row["trial"] = trial
                    return try write(trial)
                }
                guard let open = row["trial"] else { return (false, nil) }
                guard case .object(var trial) = open, let version = trial["version"]?.stringValue else {
                    throw Self.failure("Invalid trial at state.\(id).trial.")
                }
                let aside = trial["aside"]?.objectValue
                // `why` is the set aside's reason: the stem's when it judged one, else the agent's from the marked setting aside.
                func close(_ verdict: String, by: String, why: String? = nil) throws -> (written: Bool, value: JSONValue?) {
                    let closed: [JSONValue]
                    switch row["trials"] {
                    case nil: closed = []
                    case .array(let list)?: closed = list
                    default: throw Self.failure("Invalid trials at state.\(id).trials.")
                    }
                    trial.removeValue(forKey: "aside")
                    trial["closed"] = .string(at); trial["verdict"] = .string(verdict); trial["by"] = .string(by)
                    if verdict == "set_aside", let why = why.map(JSONValue.string) ?? aside?["why"] { trial["set_aside_why"] = why }
                    row.removeValue(forKey: "trial")
                    row["trials"] = .array(Array((closed + [.object(trial)]).suffix(CapabilityLifecycle.inputLimit)))
                    return try write(.object(trial))
                }
                switch change {
                case .open: return (false, nil)
                case .settingAside(let staged, let why):
                    var marker: [String: JSONValue] = ["version": .string(staged)]
                    if let why { marker["why"] = .string(why) }
                    trial["aside"] = .object(marker); row["trial"] = .object(trial)
                    return try write(.object(trial))
                case .reconcile(let by):
                    let current = try readFile(id: id, slot: .current).flatMap(identity)
                    let live = [current, try readFile(id: id, slot: .next).flatMap(identity)].compactMap { $0 }
                    let marked = aside?["version"]?.stringValue
                    guard live.contains(version) else { return try close(marked != nil && marked == current ? "set_aside" : "superseded", by: by) }
                    guard let marked, !live.contains(marked) else { return (false, nil) }
                    trial.removeValue(forKey: "aside"); row["trial"] = .object(trial)
                    return try write(.object(trial))
                case .judged(let verdict, let why):
                    return try close(verdict, by: "stem", why: why)
                case .baseline(let of, let kept):
                    guard version == of, trial["kept_turns"] == nil else { return (false, nil) }
                    trial["kept_turns"] = kept; row["trial"] = .object(trial)
                    return try write(.object(trial))
                }
            }
        }
    }
    func accounting<T>(id: String, turn: Turn?, _ write: () throws -> (written: Bool, value: T)) throws -> T {
        let recorded: (written: Bool, value: T)
        do { recorded = try write() }
        catch {
            // Ledger failure owes the file repair without replacing the act's own outcome or remedy.
            let failure = error as? ToolFailureError
                ?? repairFailure(source: root.appendingPathComponent("state.json"), detail: error.localizedDescription)
            RepairOwed.owe(dataRoot, id: "abilities-accounting:" + UUID().uuidString.lowercased(), kind: .run,
                           cause: turn?.act.map { [$0] } ?? [], operation: "abilities.accounting",
                           owner: failure.owner ?? root.appendingPathComponent("state.json").path,
                           words: failure.message, nextCall: failure.nextCall)
            throw failure
        }
        // Only a ledger write that happened proves the ledger works again.
        if recorded.written { RepairOwed.settle(dataRoot, operation: "abilities.accounting", evidence: .init(source: "abilities/state.json", id: id)) }
        return recorded.value
    }
    /// Not written when the run's part or version is gone.
    private func recordRunEvidence(id: String, version: String, receipt: JSONValue, input: JSONValue?, nativeSense: JSONValue?, turn: Turn?) throws -> (
        written: Bool,
        upgrade: String?) {
        // Only the runner's explicit evidence proves a successful no-op. Missing evidence, failures and unknown effects still count.
        if let fields = receipt.objectValue, fields["status"] == .string("ok"), fields["effects"] == .string("none"),
           fields["calls"] == .array([]), fields["notebook_changed"] == .bool(false) { return (false, nil) }
        return try Self.withLock {
            // Native/bundled reads have a registry record but no executable file.
            guard let current = try readFile(id: id, slot: .current) ?? nativeSense.map({
                try File(id: id, kind: .sense, metadata: ["record": $0, "version": $0.objectValue?["version"] ?? .int(1)], body: "", pathExtension: "js")
            }) else { return (false, nil) }
            let previous = try readFile(id: id, slot: .previous)
            let currentIdentity = identity(current), previousIdentity = previous.flatMap(identity)
            let file: File
            if currentIdentity == version { file = current }
            else if previousIdentity == version, let previous { file = previous }
            else { return (false, nil) }
            var state = try readState(), row = state[id]?.objectValue ?? [:]
            var runs = row["runs"]?.objectValue ?? [:], versions = runs["versions"]?.objectValue ?? [:]
            let currentKey = versionKey(current), previousKey = previous.map(versionKey)
            let selected = version + "@" + String(file.metadata["version"]?.integer ?? 1)
            let now: Date
            if let run = receipt.objectValue?["ability_run"] {
                guard let fields = run.objectValue, fields["id"] == .string(id), fields["version"] == .string(version),
                      let parsed = fields["at"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601) else {
                    throw Self.failure("Invalid run time for \(id)@\(version).")
                }
                now = parsed
            } else { now = Date() }
            let at = NativeTimestampFormat.fractionalZulu(now)
            var evidence = versions[selected]?.objectValue ?? [:]
            let outcome = Self.runOutcome(receipt)
            let field = "state.\(id).runs.versions.\(selected)"
            // Existing evidence was checked by readState; only a new version starts at zero.
            let priorCount = evidence["count"] ?? .int(0)
            let count = try Self.increment(priorCount, field: field + ".count")
            evidence["count"] = .int(count)
            let lastAt = try Self.runTime(evidence["last"]?.objectValue?["at"], field: field + ".last.at")
            if lastAt == nil || lastAt.map({ $0 <= now }) == true {
                evidence["last"] = .object(["outcome": .string(outcome), "at": .string(at)])
            }
            evidence[outcome] = .int(try Self.increment(evidence[outcome], field: field + "." + outcome))
            // Each UTC hour counts the same outcome classes as the totals, so a window of the record and its totals read one unit.
            let hour = String(at.prefix(13))
            let horizon = String(NativeTimestampFormat.plainZulu(now.addingTimeInterval(-Self.hoursKept)).prefix(13))
            var hours = try Self.accountingObject(evidence["hours"], field: field + ".hours").filter { $0.key >= horizon }
            var bucket = try Self.accountingObject(hours[hour], field: field + ".hours." + hour)
            bucket[outcome] = .int(try Self.increment(bucket[outcome], field: field + ".hours.\(hour).\(outcome)"))
            hours[hour] = .object(bucket)
            evidence["hours"] = .object(hours)
            // Settlement order cannot move the first observed run forward.
            let firstAt = try Self.runTime(evidence["first_seen"], field: field + ".first_seen")
            if firstAt == nil || firstAt.map({ now < $0 }) == true { evidence["first_seen"] = .string(at) }
            let fields = Self.redactedEvidence(receipt).objectValue ?? [:]
            if let snapshot = fields["dependencySnapshot"] { evidence["dependencySnapshot"] = snapshot }
            if file.kind == .sense, outcome == "ok", fields["read"] == .bool(true) {
                evidence["reads"] = .int(try Self.increment(evidence["reads"], field: field + ".reads"))
            }
            // Only the runner supplies input: fixtures, previews and admission refusals earn no competence.
            if let input {
                let calls = (fields["calls"]?.arrayValue ?? []).map {
                    JSONValue.object(($0.objectValue ?? [:]).filter { ["call", "line", "status", "effects"].contains($0.key) })
                }
                let scope: JSONValue = .object([
                    "input_digest": .string(SHA256.hash(data: try input.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()),
                    "calls": .array(calls),
                ])
                let digest = SHA256.hash(data: try scope.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
                var operations = evidence["operations"]?.objectValue ?? [:], operation = operations[digest]?.objectValue ?? [:]
                operation["scope"] = scope
                operation["input_preview"] = .string(String(try Self.inputDescription(input).serialize(pretty: false).prefix(1024)))
                let result = outcome == "ok" ? "completed" : outcome
                operation[result] = .int(try Self.increment(operation[result], field: field + ".operations.\(digest)." + result))
                operation["at"] = .string(at); operation["last_run"] = .int(count)
                operations[digest] = .object(operation)
                // Retain recent scopes, not every distinct input. Version totals above never expire.
                if operations.count > CapabilityLifecycle.inputLimit {
                    operations = Dictionary(uniqueKeysWithValues: operations.sorted {
                        let lhs = $0.value.objectValue?["last_run"]?.integer ?? 0, rhs = $1.value.objectValue?["last_run"]?.integer ?? 0
                        let leftAt = $0.value.objectValue?["at"]?.stringValue ?? "", rightAt = $1.value.objectValue?["at"]?.stringValue ?? ""
                        return (lhs, leftAt, $0.key) < (rhs, rightAt, $1.key)
                    }.suffix(CapabilityLifecycle.inputLimit))
                }
                evidence["operations"] = .object(operations)
            }
            versions[selected] = .object(evidence)
            let owedVersions = Set(try pendingSurpriseWindow()?.folds.filter { $0.part == id }.map(\.version) ?? [])
            versions = versions.filter { $0.key == currentKey || $0.key == previousKey || owedVersions.contains($0.key) }
            runs["versions"] = .object(versions)
            // Repeated world stops at one place owe one upgrade signal.
            var upgrade: String?
            if input != nil {
                let back = fields["hand_back"]?.objectValue ?? [:]
                let place = back["step"]?.stringValue ?? (fields["stopped"]?.objectValue?["line"]?.integer).map { "line \($0)" } ?? ""
                let stops = Array(((runs["stops"]?.arrayValue ?? []) + [.string((fields["reason"]?.stringValue ?? outcome) + "@" + place)]).suffix(3))
                runs["stops"] = .array(stops)
                if let repeated = CapabilityLifecycle.repeatedStop(stops.compactMap(\.stringValue)), runs["noted"] != .string(repeated) {
                    runs["noted"] = .string(repeated); upgrade = repeated
                }
            }
            row["runs"] = .object(runs)
            row["useCount"] = .int(try Self.increment(row["useCount"], field: "state.\(id).useCount"))
            if file == current, file.kind == .sense, outcome == "ok", fields["read"] == .bool(true) {
                row["uses"] = .int(try Self.increment(row["uses"], field: "state.\(id).uses"))
            }
            let lastRunAt = try Self.runTime(row["lastRun"]?.objectValue?["at"], field: "state.\(id).lastRun.at")
            if lastRunAt == nil || lastRunAt.map({ $0 <= now }) == true {
                row["lastUsedAt"] = file.kind == .sense ? .double(now.timeIntervalSinceReferenceDate) : .string(at)
                row["lastRunVersion"] = .string(version)
                row["lastRun"] = .object(fields.filter { ["status", "effects", "version", "calls", "error", "stopped", "refreshed",
                    "reason", "reasons", "gate_reason", "not_run_status", "detail", "message", "checker", "remedy", "dispatch_receipt_id"].contains($0.key) }
                    .merging(["outcome": .string(outcome), "at": .string(at)]) { _, new in new })
            }
            if outcome == "ok" { row["lastCleanVersion"] = .string(version) }
            state[id] = .object(row); try writeState(state)
            if file.kind != .turn { turn?.abilityRounds?.ran(id: id, version: selected) }
            // Rehearsals have no input here and cannot earn or settle repair.
            if let input {
                let operation = "part." + id
                let run = "part-run:" + UUID().uuidString.lowercased()
                let remedy = fields["stopped"]?.objectValue?["remedy"] ?? fields["remedy"]
                // runOutcome classifies the cause; ledger advice does not exempt a source fault.
                if outcome == "error", !["repair", "person_decides", "correct_arguments", "inspect"].contains(remedy?.objectValue?["kind"]?.stringValue ?? "") {
                    let source = try path(id: id, slot: file == current ? .current : .previous, pathExtension: file.pathExtension).path
                    let fault = fields["error"]?.objectValue ?? fields["stopped"]?.objectValue ?? fields
                    let detail = fault["message"]?.stringValue ?? fault["detail"]?.stringValue ?? fault["reason"]?.stringValue ?? "Ability execution failed."
                    RepairOwed.owe(dataRoot, id: run, kind: .run,
                        cause: turn?.act.map { [$0] } ?? [], operation: operation,
                        owner: source + " > " + version,
                        words: TurnSecretRedactor.redactText(detail) + (file.kind == .turn
                            ? " Tell the person: NativeAgent's turn part failed; preserve its versions and reconcile prior effects."
                            : " Revise code/source in next_call through " + (file.kind == .sense ? "sense.make" : "ability.save")
                                + ", keep that version, reconcile any prior effects, then perform the failed operation again."),
                        lever: file.kind == .sense ? "sense.make" : file.kind == .part ? "ability.enable" : nil,
                        nextCall: try repairCall(file), tap: file.kind == .turn ? """
                            Report NativeAgent's turn-part execution defect at \(source), version \(version), to the person; preserve every retained version \
                            and prior effect.
                            """ : nil)
                } else if outcome == "ok" {
                    RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: "abilities/state.json", id: id + ":" + selected + ":" + String(
                        count)))
                }
            }
            return (true, upgrade)
        }
    }
    private static func runTime(_ value: JSONValue?, field: String) throws -> Date? {
        guard let value else { return nil }
        guard let at = value.stringValue.flatMap(NativeTimestampFormat.parseISO8601) else { throw failure("Invalid run time at \(field).") }
        return at
    }
    public static func runOutcome(_ receipt: JSONValue) -> String {
        let fields = receipt.objectValue ?? [:]
        if fields["status"] == .string("ok") { return "ok" }
        // The ability's returned refusal is its decision, not a thrown source or transport fault with the same reason code.
        if fields["status"] == .string("refused"), fields["returned"]?.objectValue?["status"] == .string("refused") { return "refused" }
        if fields["status"] == .string("timed_out") { return "cut" }
        let fault = fields["error"]?.objectValue ?? fields["stopped"]?.objectValue ?? fields
        let reason = fault["reason"]?.stringValue ?? fields["reason"]?.stringValue ?? ""
        if ["timeout", "resource_limit", "cancelled"].contains(reason) { return "cut" }
        if ["network", "http", "connection_failed", "connection_closed", "transport", "network_error", "http_error", "transport_error"].contains(
            reason) { return "network" }
        if ["javascript", "script_syntax", "script_name", "bad_output", "output_limit", "unreadable_return",
            "expect_failed", "expected_failure_not_seen", "expected_failure_succeeded", "validation_failed",
            "expect_fail_async", "expect_fail_nested", "expect_fail_one_call", "diverged", "script_error",
            "not_declared", "denied_in_skill", "unknown_action", "unknown_arg", "invalid_args", "missing_arg",
            "not_own_version"].contains(reason) { return "error" }
        let calls = fields["calls"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let failedCall = fault["n"]?.integer.flatMap { n in n > 0 && n <= Int64(calls.count) ? calls[Int(n) - 1] : nil }
            ?? (fields["error"] == nil ? calls.last : nil)
        if let call = failedCall, ![JSONValue.string("ok"), .string("preview"), .string("answered")].contains(call["status"] ?? .null) {
            return runOutcome(.object(call.merging(["calls": .array([])]) { _, new in new }))
        }
        if fault["origin"] == .string("javascript") || fields["status"] == .string("error") && reason.isEmpty { return "error" }
        return "refused"
    }
    /// Cache accounting only by its exact checked file identity.
    public func states() throws -> [String: JSONValue] {
        try Self.withLock { return try readState() }
    }
    public func saveState(id: String, fields: [String: JSONValue]) throws {
        try updateState(id: id) { $0 = fields }
    }
    /// Accounting mutations require the store lock.
    public func updateState(id: String, _ change: (inout [String: JSONValue]) -> Void) throws {
        try Self.withLock {
            var stats = try readState(), fields = stats[id]?.objectValue ?? [:]
            let before = stats[id]
            change(&fields); stats[id] = .object(fields)
            if stats[id] != before { try writeState(stats) }
        }
    }
}
