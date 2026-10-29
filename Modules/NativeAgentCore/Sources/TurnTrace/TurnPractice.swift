import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `TurnPractice.swift` | `TurnPractice`: each agent's practice as the night reads it (AGENT_IS_THE_APP "Practice compiles"): its turns' top-level `app` calls from `tool.dispatch` end rows (a nested call is its part's), recurring successful sequences of two or more operations nominated against what the parts' own frequencies give by chance (exact Poisson tail at `VectorMath.chanceBar`'s attention tail among the sequences tested; closed sequences only), the per-agent ledger and its recording set, bounded redacted tape rows for nominated operations only that keep what is exact (arguments and outer operational options when unchanged, the result path by path, left-out paths named and absent from the replayed reply, never reconstructed; a replay verifies the calls alone), each row carrying its call-end sequence (`nextSequence`, taken on the dispatch path) and appended at once, the trim ordering by it, occurrences joined to the tape by receipt id with honest coverage, and the value-flow map (a constant, an earlier result's or arguments' path, or judgment) the compile filter and their packet read; `turn_traces/practice/` |

/// What the night learns from: each agent's own practice, kept beside the
/// traces it comes from (docs/AGENT_IS_THE_APP.md, "Practice compiles").
///
/// An agent is whoever's model made the call: the resident, or one of her
/// helpers (each its own). A turn steered by another agent is still her
/// practice; its steer rides every tape row as provenance, so what the night
/// compiles from it is never her own trusted work.
public enum TurnPractice {
    static let diagnostics = ModuleLog(category: "TurnPractice")

    /// `turn_traces/practice/`: one ledger and one tape per agent. Derived from
    /// the traces and the calls after nomination, so it shares their privacy.
    public static func folder(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("turn_traces", isDirectory: true).appendingPathComponent("practice", isDirectory: true)
    }

    /// The resident, or a helper by its exact id (StandingBots owns the
    /// session locator that names it; callers pass what it parsed).
    public static func principal(helper: UUID?) -> String {
        helper.map { "helper-" + $0.uuidString.lowercased() } ?? "resident"
    }

    // MARK: - Calls

    /// A call as a part makes it and its replay names it (`OwnedProgramFixtures`):
    /// `app.<action>`, a page read `read`, a find `find`. Nil for what a part
    /// cannot make as one call: another tool, a script, a batch.
    public static func operation(tool: String, keys: Set<String>, action: String?) -> String? {
        let keys = keys.filter { !$0.hasPrefix("__") }
        guard tool == "app", keys.isDisjoint(with: ["script", "actions"]) else { return nil }
        if keys.contains("action") {
            guard keys.isSubset(of: ["action", "args", "preview", "expected_version"]) else { return nil }
            guard let action = action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !action.isEmpty else { return nil }
            return "app." + action
        }
        // Authored reads can express page/item or find only. An extra read
        // argument (including args.limit) is a gap, never a lossy replay.
        guard keys.isSubset(of: ["page", "item", "find", "preview", "expected_version"]) else { return nil }
        if keys.contains("find"), !keys.isSubset(of: ["find", "preview", "expected_version"]) { return nil }
        return keys.contains("find") ? "find" : "read"
    }

    /// The arguments a replay matches for that operation: an action's args, or
    /// every operational read field, including ones not yet expressible by a part.
    public static func arguments(_ operation: String, input: [String: JSONValue]) -> JSONValue {
        operation.hasPrefix("app.") ? input["args"] ?? .object([:])
            : .object(input.filter { !$0.key.hasPrefix("__") && !["preview", "expected_version"].contains($0.key) })
    }

    public static func options(_ input: [String: JSONValue]) -> JSONValue {
        .object(input.filter { ["preview", "expected_version"].contains($0.key) })
    }

    public static func operation(ofSymbol symbol: String) -> String {
        guard let mark = symbol.lastIndex(of: "#") else { return symbol }
        return String(symbol[..<mark])
    }

    /// One top-level call: its receipt, `operation#resultClass` (nil when no
    /// part makes it as one call) and when it began.
    public struct Call: Sendable, Equatable {
        public let receipt: String
        public let symbol: String?
        public let at: Date
    }

    public struct Turn: Sendable, Equatable {
        public let id: String
        public let calls: [Call]
    }

    /// Each agent's turns from retained `tool.dispatch` end rows, the calls in
    /// the order they began. `principal` names the agent of a row's session.
    public static func turns(_ events: [TurnTraceEvent], principal: (String?) -> String) -> [String: [Turn]] {
        var calls: [String: [Call]] = [:], owner: [String: String] = [:]
        var incomplete: Set<String> = []
        for (turn, rows) in Dictionary(grouping: events, by: \.turnId) {
            let dispatches = rows.filter { $0.kind == "tool.dispatch" }
            let terminal = rows.filter { $0.kind == "tool.dispatch.closed" }
            let marks = (dispatches + terminal).compactMap { $0.payload.objectValue?["dispatchCoverage"]?.objectValue }
            let ordinals = dispatches.compactMap { $0.payload.objectValue?["dispatchCoverage"]?.objectValue?["ordinal"]?.integerValue }.sorted()
            let lives = Set(marks.compactMap { $0["life"]?.stringValue })
            let last = terminal.first?.payload.objectValue?["dispatchCoverage"]?.objectValue?["ordinal"]?.integerValue
            if terminal.count != 1 || marks.count != dispatches.count + 1 || lives.count != 1
                || !marks.allSatisfy({ $0["life"]?.stringValue?.isEmpty == false })
                || last != Int64(exactly: dispatches.count)
                || ordinals.count != dispatches.count || !ordinals.enumerated().allSatisfy({ Int64(exactly: $0.offset) == $0.element }) {
                incomplete.insert(turn)
            }
            var began: Set<String> = [], ended: Set<String> = []
            for event in dispatches {
                guard let payload = event.payload.objectValue, payload["parentId"] == nil, payload["automaticOrigin"] == nil else { continue }
                guard let id = payload["receipt"]?.objectValue?["id"]?.stringValue else { incomplete.insert(turn); continue }
                switch payload["phase"] {
                case .string("begin"): if !began.insert(id).inserted { incomplete.insert(turn) }
                case .string("end"): if !ended.insert(id).inserted { incomplete.insert(turn) }
                default: incomplete.insert(turn)
                }
            }
            if began != ended { incomplete.insert(turn) }
        }
        for event in events where event.kind == "tool.dispatch" {
            guard case .object(let payload) = event.payload else { incomplete.insert(event.turnId); continue }
            guard payload["phase"] == .string("end"), payload["parentId"] == nil, payload["automaticOrigin"] == nil else { continue }
            guard
                  case .object(let receipt)? = payload["receipt"], case .string(let id)? = receipt["id"],
                  case .string(let tool)? = payload["name"] else {
                incomplete.insert(event.turnId)
                continue
            }
            var keys: Set<String> = []
            if case .array(let list)? = payload["argKeys"] {
                for case .string(let key) in list { keys.insert(key) }
                if keys.count != list.count { incomplete.insert(event.turnId) }
            } else { incomplete.insert(event.turnId) }
            let action: String? = if case .string(let text)? = receipt["action"] { text } else { nil }
            guard case .string(let result)? = receipt["resultClass"], case .int(let ms)? = payload["durationMs"], ms >= 0 else {
                incomplete.insert(event.turnId); continue
            }
            let took = Double(ms) / 1000
            let symbol = TurnPractice.operation(tool: tool, keys: keys, action: action).map { $0 + "#" + result }
            calls[event.turnId, default: []].append(Call(receipt: id, symbol: symbol, at: event.ts.addingTimeInterval(-took)))
            if owner[event.turnId] == nil { owner[event.turnId] = principal(event.sessionId) }
        }
        var turns: [String: [Turn]] = [:]
        for (id, list) in calls {
            // A gap remains a gap; no two retained neighbors become a route.
            let sequence = incomplete.contains(id) ? [Call(receipt: "", symbol: nil, at: list.first?.at ?? .distantPast)] : list.sorted { $0.at < $1.at }
            turns[owner[id] ?? principal(nil), default: []].append(Turn(id: id, calls: sequence))
        }
        return turns.mapValues { list in list.sorted { ($0.calls.first?.at ?? .distantPast) < ($1.calls.first?.at ?? .distantPast) } }
    }

    // MARK: - Nomination

    public struct Nominee: Sendable, Equatable {
        public let symbols: [String]
        /// Turns it occurs in, once per turn.
        public let count: Int
        /// Turns it would occur in by chance, from the agent's own call frequencies.
        public let expected: Double
        /// The chance of at least `count` such turns by chance alone.
        public let tail: Double
    }

    /// The longest sequence counted: a resource bound, it decides nothing (a
    /// longer route still shows as its overlapping parts).
    public static let longest = 4

    /// Recurring sequences beyond chance, for one agent. A sequence is two to
    /// `longest` contiguous calls of one turn, counted once per turn, every
    /// call `succeeded` (a route is the calls that worked) and more than one
    /// operation (one call repeated is a loop, which `{again}` carries).
    ///
    /// Null, stated: each call drawn independently from the agent's own call
    /// frequencies (order 0), so a sequence of probability p appears in a turn
    /// of n calls with chance min(1, (n - k + 1) p); the count over turns is
    /// taken as Poisson with that sum E. Bar, stated: the exact Poisson tail
    /// P(X >= count | E) must be no larger than the Gaussian tail beyond
    /// `VectorMath.chanceBar(.attention, among: M)`, M the sequences tested
    /// (those seen in two or more turns, since one example identifies nothing):
    /// the one law every attention decision clears, with the statistic that
    /// fits counts. Nomination acts on nothing; it only starts the recording,
    /// and the examples that compile are the ones recorded after it.
    /// Kept closed: a sequence whose every occurrence lies inside a longer
    /// nominated one is that one.
    public static func nominate(_ turns: [Turn], succeeded: String) -> (nominees: [Nominee], tested: Int, bar: Double) {
        var frequency: [String: Int] = [:], total = 0
        for turn in turns { for call in turn.calls { if let symbol = call.symbol { frequency[symbol, default: 0] += 1; total += 1 } } }
        guard total > 0 else { return ([], 0, 0) }
        var counts: [[String]: Int] = [:]
        for turn in turns {
            let row = turn.calls.map(\.symbol)
            var seen: Set<[String]> = []
            for length in 2...longest where row.count >= length {
                for start in 0...(row.count - length) {
                    let window = row[start..<(start + length)].compactMap { $0 }
                    guard window.count == length, window.allSatisfy({ $0.hasSuffix("#" + succeeded) }),
                          Set(window.map { TurnPractice.operation(ofSymbol: $0) }).count > 1, seen.insert(window).inserted else { continue }
                    counts[window, default: 0] += 1
                }
            }
        }
        let tested = counts.filter { $0.value >= 2 }
        guard !tested.isEmpty else { return ([], 0, 0) }
        let bar = VectorMath.chanceBar(.attention, among: tested.count)
        let alpha = 0.5 * erfc(bar / 2.0.squareRoot())
        var nominees: [Nominee] = []
        for (window, count) in tested {
            let p = window.reduce(1.0) { $0 * Double(frequency[$1] ?? 0) / Double(total) }
            let expected = turns.reduce(0.0) { $0 + min(1, Double(max(0, $1.calls.count - window.count + 1)) * p) }
            let tail = poissonTail(count, expected)
            if tail <= alpha { nominees.append(Nominee(symbols: window, count: count, expected: expected, tail: tail)) }
        }
        let closed = nominees.filter { shorter in
            !nominees.contains { longer in
                longer.symbols.count > shorter.symbols.count && longer.count == shorter.count && TurnPractice.appears(shorter.symbols, in: longer.symbols)
            }
        }
        return (closed.sorted { ($0.tail, TurnPractice.key($0.symbols)) < ($1.tail, TurnPractice.key($1.symbols)) }, tested.count, bar)
    }

    public static func key(_ symbols: [String]) -> String { symbols.joined(separator: " > ") }

    /// P(X >= count) for X ~ Poisson(expected), summed upward from `count`.
    static func poissonTail(_ count: Int, _ expected: Double) -> Double {
        guard expected > 0 else { return count > 0 ? 0 : 1 }
        guard count > 0 else { return 1 }
        let ln = log(expected)
        var term = -expected + Double(count) * ln - lgamma(Double(count) + 1)
        var sum = 0.0, i = count
        while i < count + 100_000 {
            let value = exp(term)
            sum += value
            if Double(i) > expected, value <= sum * 1e-15 { break }
            i += 1
            term += ln - log(Double(i))
        }
        return min(1, sum)
    }

    static func appears(_ shorter: [String], in longer: [String]) -> Bool {
        guard shorter.count <= longer.count else { return false }
        return (0...(longer.count - shorter.count)).contains { Array(longer[$0..<($0 + shorter.count)]) == shorter }
    }

    // MARK: - Ledger

    /// One nominated sequence and where it stands. `state` is the practice side
    /// of its lifecycle: `nominated` (recording), `blocked` (its arguments are
    /// mostly judgment, or its examples are too large for one packet),
    /// `declined` (she kept nothing; offered again at twice the examples),
    /// `staged` (she saved it; replay next), `failed` (its replay failed;
    /// offered again at twice the examples), `verified` (replayed exactly),
    /// `waiting_owner` (keeping it is the owner's card), `admitted` (kept and
    /// on), `off` (kept, then switched off), `revised` (another version of that
    /// ability is selected or waiting now).
    /// Standing is never kept here: it is earned by the ability's live record.
    public struct Candidate: Codable, Sendable, Equatable {
        public var key: String
        public var symbols: [String]
        public var count: Int
        public var expected: Double
        public var tail: Double
        public var nominatedAt: Date
        public var state: String
        public var detail: String?
        public var ability: String?
        public var version: String?
        /// Occurrences since nomination, and how many of them the tape holds
        /// replayably (every call's arguments exact); `partial`, how many of
        /// those have results with paths left out.
        public var seen: Int
        public var examples: Int
        public var partial: Int?
        /// Exact examples when it was last offered to her.
        public var offeredAt: Int?
        /// The exact evidence that blocked it; a changed packet is reconsidered.
        public var blockedEvidence: String?
        public var updatedAt: Date

        public init(_ nominee: Nominee, at: Date) {
            key = TurnPractice.key(nominee.symbols); symbols = nominee.symbols
            count = nominee.count; expected = nominee.expected; tail = nominee.tail
            nominatedAt = at; state = "nominated"; seen = 0; examples = 0; updatedAt = at
        }

        /// Still learning from new examples: its tape keeps recording.
        public var records: Bool { ["nominated", "blocked", "declined", "failed"].contains(state) }
        public var operations: [String] { symbols.map(TurnPractice.operation(ofSymbol:)) }
    }

    public struct Ledger: Codable, Sendable, Equatable {
        public var principal: String
        public var updatedAt: Date?
        public var turns: Int = 0
        public var tested: Int = 0
        public var bar: Double = 0
        public var candidates: [Candidate] = []
        /// Actual keep offers, independent of candidates that nomination may
        /// retire. Absent on ledgers written before offer times were recorded.
        public var offerTimes: [Date]?
        /// The operations the tape keeps: those of every candidate still recording.
        public var recording: [String] {
            Array(Set(candidates.filter(\.records).flatMap(\.operations))).sorted()
        }

        public init(principal: String) { self.principal = principal }

        /// One night spans local noon to the next local noon: midnight cannot
        /// replenish the allowance around the scheduled early-morning dream.
        /// Calendar arithmetic preserves that boundary across clock changes.
        public func offersThisNight(at now: Date) throws -> Int {
            let calendar = Calendar.current
            guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now),
                  let start = now < noon ? calendar.date(byAdding: .day, value: -1, to: noon) : noon,
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                throw PersistenceCoreError.ioFailure("Practice night could not be resolved for \(now).")
            }
            return (offerTimes ?? []).filter { $0 >= start && $0 < end }.count
        }

        /// Tonight's nominees merged in: a known sequence keeps its state and
        /// gains tonight's counts; a new one starts recording; one no longer
        /// beyond chance leaves unless it is already her ability's.
        public mutating func merge(_ nominees: [Nominee], tested: Int, bar: Double, turns: Int, at: Date) {
            var kept: [Candidate] = []
            for nominee in nominees {
                if var known = candidates.first(where: { $0.key == TurnPractice.key(nominee.symbols) }) {
                    known.count = nominee.count; known.expected = nominee.expected; known.tail = nominee.tail
                    kept.append(known)
                } else { kept.append(Candidate(nominee, at: at)) }
            }
            for candidate in candidates where !kept.contains(where: { $0.key == candidate.key })
                && ["staged", "verified", "waiting_owner", "admitted", "off"].contains(candidate.state) {
                kept.append(candidate)
            }
            candidates = kept
            self.tested = tested; self.bar = bar; self.turns = turns; updatedAt = at
        }
    }

    static func file(_ dataRoot: URL, _ principal: String, _ suffix: String) -> URL {
        let safe = String(principal.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return folder(dataRoot).appendingPathComponent(safe + suffix)
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// Missing is a first night; unreadable throws (the night names it and
    /// leaves the bytes for repair rather than starting over silently).
    public static func ledger(_ dataRoot: URL, principal: String) throws -> Ledger {
        let url = file(dataRoot, principal, ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Ledger(principal: principal) }
        let ledger = try coder().1.decode(Ledger.self, from: Data(contentsOf: url))
        func require(_ valid: Bool, _ field: String) throws {
            guard valid else { throw PersistenceCoreError.ioFailure("Invalid practice accounting at \(url.path):\(field); bytes preserved.") }
        }
        try require(ledger.turns >= 0, "turns")
        try require(ledger.tested >= 0, "tested")
        try require(ledger.bar.isFinite && ledger.bar >= 0, "bar")
        for candidate in ledger.candidates {
            let field = "candidates.\(candidate.key)."
            for (name, count) in [("count", candidate.count), ("seen", candidate.seen), ("examples", candidate.examples),
                                  ("partial", candidate.partial ?? 0), ("offeredAt", candidate.offeredAt ?? 0)] {
                try require(count >= 0, field + name)
            }
            try require(candidate.examples <= candidate.seen, field + "examples/seen")
            try require((candidate.partial ?? 0) <= candidate.examples, field + "partial/examples")
            try require(candidate.expected.isFinite && candidate.expected >= 0, field + "expected")
            try require(candidate.tail.isFinite && (0...1).contains(candidate.tail), field + "tail")
        }
        return ledger
    }

    public static func save(_ ledger: Ledger, dataRoot: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(try coder().0.encode(ledger), to: file(dataRoot, ledger.principal, ".json"))
    }

    /// Every agent with a ledger.
    public static func principals(_ dataRoot: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(dataRoot).path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private static let recordingCache = OSAllocatedUnfairLock<[String: (stamp: SnapshotTailOpLog.FileStamp, operations: Set<String>)]>(initialState: [:])

    /// Whether this agent's tape keeps this operation now: one stat of its
    /// ledger per call, decoded again only when the ledger changed.
    public static func records(_ operation: String, principal: String, dataRoot: URL) -> Bool {
        let url = file(dataRoot, principal, ".json")
        guard let stamp = SnapshotTailOpLog.fileStamp(url), stamp != .absent else { return false }
        if let hit = recordingCache.withLock({ $0[url.path] }), hit.stamp == stamp { return hit.operations.contains(operation) }
        guard let ledger = try? ledger(dataRoot, principal: principal) else { return false }
        let operations = Set(ledger.recording)
        recordingCache.withLock { $0[url.path] = (stamp, operations) }
        return operations.contains(operation)
    }

    // MARK: - Tape

    /// One recorded call: what of it is exact, kept exactly, and what is not,
    /// named. Its arguments are kept when redaction left them unchanged and
    /// they fit the row bound; without them the call cannot be matched, so the
    /// row keeps nothing else and is never replayed. Its result keeps every
    /// field, recursively by path, that redaction left unchanged and that fits
    /// what remains of the bound, smallest first (so an act's small receipt
    /// survives the screen it returns); a list is kept whole or not at all,
    /// since a partial list would move its items. Each path left out is named
    /// with why (`redacted` or `over_bound`), or counted in a coarsened notice
    /// when the names exceed the full row bound; nothing is reconstructed.
    public struct TapeRow: Sendable, Equatable {
        public struct Omission: Sendable, Equatable {
            public let path: String
            public let reason: String
        }
        public let receipt: String
        public let turn: String
        public let operation: String
        public let resultClass: String
        /// Nil when they were not exact: the row cannot replay.
        public private(set) var args: JSONValue?
        /// Outer operational options, exact as called. Old action rows did
        /// not record them and cannot prove replay equivalence.
        public private(set) var options: JSONValue?
        /// The kept part of the result; nil when none of it is kept.
        public private(set) var result: JSONValue?
        /// Result paths left out (`""` the whole result), or `args`.
        public private(set) var omitted: [Omission]
        public let steer: [String]
        public let model: String?
        public let at: Date
        /// Its call-end order (`nextSequence`); a row from before it had one orders by `at`.
        public let sequence: UInt64

        /// The call can be matched and answered: its arguments are exact.
        public var replayable: Bool { args != nil && options != nil }
        /// Nothing of it was left out.
        public var exact: Bool { replayable && omitted.isEmpty }

        /// The value-flow packet includes operational choices as well as args.
        var flowArguments: JSONValue {
            var fields: [String: JSONValue] = ["args": args ?? .null]
            if let options, options != .object([:]) { fields["options"] = options }
            return .object(fields)
        }

        /// `args`/`result` as the call went and came back; `redactedArgs`/
        /// `redactedResult` as redaction left them. Only what the two agree on is kept.
        public init(receipt: String, turn: String, operation: String, resultClass: String,
                    args: JSONValue, redactedArgs: JSONValue, options: JSONValue, redactedOptions: JSONValue,
                    result: JSONValue, redactedResult: JSONValue,
                    steer: [String], model: String?, at: Date, sequence: UInt64) {
            self.receipt = receipt; self.turn = turn; self.operation = operation; self.resultClass = resultClass
            self.steer = steer; self.model = model; self.at = at; self.sequence = sequence
            let argsBytes = TurnPractice.bytes(args), optionsBytes = TurnPractice.bytes(options)
            guard args == redactedArgs, options == redactedOptions,
                  optionsBytes <= TurnPractice.rowBytes, argsBytes <= TurnPractice.rowBytes - optionsBytes else {
                self.args = nil; self.result = nil
                self.options = nil
                self.omitted = [Omission(path: "args/options", reason: args == redactedArgs && options == redactedOptions ? "over_bound" : "redacted")]
                return
            }
            var budget = TurnPractice.rowBytes - argsBytes - optionsBytes, omitted: [Omission] = []
            self.args = args
            self.options = options
            self.result = TurnPractice.kept(result, redactedResult, path: "", budget: &budget, omitted: &omitted)
            self.omitted = omitted
            // Budget the serialized envelope, escaped keys, omissions and
            // newline too. Halving bounds rebuilding to logarithmic work.
            while TurnPractice.bytes(value) >= TurnPractice.rowBytes, budget > 0 {
                budget /= 2
                var remaining = budget, leftOut: [Omission] = []
                self.result = TurnPractice.kept(result, redactedResult, path: "", budget: &remaining, omitted: &leftOut)
                self.omitted = leftOut
                if TurnPractice.bytes(value) >= TurnPractice.rowBytes, !leftOut.isEmpty {
                    self.omitted = [Omission(path: "(\(leftOut.count) omitted result paths)", reason: "redacted_or_over_bound")]
                }
            }
            if TurnPractice.bytes(value) >= TurnPractice.rowBytes {
                self.args = nil; self.options = nil; self.result = nil
                self.omitted = [Omission(path: "args/options/result", reason: "over_bound")]
            }
        }

        init?(_ value: JSONValue) {
            guard case .object(let fields) = value, case .string(let receipt)? = fields["receipt"], case .string(let turn)? = fields["turn"],
                  case .string(let operation)? = fields["operation"], case .string(let resultClass)? = fields["class"],
                  case .string(let at)? = fields["at"], let date = ISO8601DateFormatter().date(from: at) else { return nil }
            self.receipt = receipt; self.turn = turn; self.operation = operation; self.resultClass = resultClass
            self.options = fields["options"] ?? (operation.hasPrefix("app.") ? nil : .object([:]))
            var omitted: [Omission] = []
            if case .array(let list)? = fields["omitted"] {
                for case .object(let entry) in list {
                    if case .string(let path)? = entry["path"], case .string(let reason)? = entry["reason"] { omitted.append(Omission(path: path, reason: reason)) }
                }
            }
            // A row from before paths were kept: exact whole, or nothing kept.
            if fields["omitted"] == nil, fields["exact"] != .bool(true) || fields["args"] == nil || fields["result"] == nil {
                self.args = nil; self.result = nil; self.omitted = [Omission(path: "args", reason: "redacted")]
            } else {
                self.args = fields["args"]; self.result = fields["result"]
                self.omitted = fields["args"] == nil && omitted.isEmpty ? [Omission(path: "args", reason: "redacted")] : omitted
            }
            var steer: [String] = []
            if case .array(let list)? = fields["steer"] { for case .string(let peer) in list { steer.append(peer) } }
            self.steer = steer
            if case .string(let model)? = fields["model"] { self.model = model } else { self.model = nil }
            self.at = date
            if case .int(let seq)? = fields["seq"], seq >= 0 { self.sequence = UInt64(seq) }
            else {
                guard let sequence = UInt64(exactly: max(0, date.timeIntervalSince1970 * 1_000_000).rounded(.towardZero)) else { return nil }
                self.sequence = sequence
            }
        }

        var value: JSONValue {
            var fields: [String: JSONValue] = ["receipt": .string(receipt), "turn": .string(turn), "operation": .string(operation),
                "class": .string(resultClass), "exact": .bool(exact), "steer": .array(steer.map(JSONValue.string)),
                "omitted": .array(omitted.map { .object(["path": .string($0.path), "reason": .string($0.reason)]) }),
                "at": .string(ISO8601DateFormatter().string(from: at)), "seq": .int(Int64(clamping: sequence))]
            if let args { fields["args"] = args }
            if let options { fields["options"] = options }
            if let result { fields["result"] = result }
            if let model { fields["model"] = .string(model) }
            return .object(fields)
        }

        /// The call as a fixture replays it (`OwnedProgramFixtures`): its exact
        /// arguments, and its result as kept, a left-out path simply absent.
        /// Verification is the calls: a part must make exactly the recorded
        /// calls (operation and arguments) in order and consume the whole
        /// tape. A part that read an absent value and still made identical
        /// calls did not depend on it; one that depended on it makes different
        /// calls and fails. Its own returned value is not evidence and is not
        /// compared: it goes to the model, not to an effect.
        public var fixtureCall: JSONValue? {
            guard let args, let options else { return nil }
            return .object(["operation": .string(operation), "args": args, "options": options, "result": result ?? .object([:])])
        }
    }

    static func bytes(_ value: JSONValue) -> Int {
        (try? value.serializedData(pretty: false).count) ?? Int.max
    }

    /// What of `raw` is exact: all of it when redaction left it unchanged and it
    /// fits; else, for an object of the same keys, each field in turn, smallest
    /// first; else nothing, named.
    static func kept(_ raw: JSONValue, _ shown: JSONValue, path: String, budget: inout Int, omitted: inout [TapeRow.Omission]) -> JSONValue? {
        let size = bytes(raw)
        if raw == shown, size <= budget { budget -= size; return raw }
        if case .object(let fields) = raw, case .object(let redacted) = shown, Set(fields.keys) == Set(redacted.keys), !fields.isEmpty {
            var out: [String: JSONValue] = [:]
            let sizes = fields.mapValues { TurnPractice.bytes($0) }
            for key in fields.keys.sorted(by: { (sizes[$0] ?? .max, $0) < (sizes[$1] ?? .max, $1) }) {
                guard let raw = fields[key], let shown = redacted[key] else {
                    omitted.append(TapeRow.Omission(path: path + "/" + JSONValue.escapedPointerComponent(key), reason: "redacted")); continue
                }
                // A kept field also spends its key's bytes.
                let cost = key.utf8.count + 4
                guard budget > cost else { omitted.append(TapeRow.Omission(path: path + "/" + JSONValue.escapedPointerComponent(key), reason: "over_bound")); continue }
                budget -= cost
                if let value = kept(raw, shown, path: path + "/" + JSONValue.escapedPointerComponent(key), budget: &budget, omitted: &omitted) {
                    out[key] = value
                } else { budget += cost }
            }
            return .object(out)
        }
        omitted.append(TapeRow.Omission(path: path, reason: raw == shown ? "over_bound" : "redacted"))
        return nil
    }

    /// Bounds, resource only: one call's bodies, and one agent's tape, whose
    /// oldest half goes when it is exceeded.
    public static let rowBytes = 64 * 1024
    public static let tapeBytes = 8 * 1024 * 1024

    private static let sequence = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// A recorded call's place on the tape, taken on the dispatch path as the
    /// call ends: increasing within a life and, seeded from the clock in
    /// microseconds, across lives. Rows carry it; readers and the trim order by it.
    public static func nextSequence() -> UInt64 {
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
        return sequence.withLock { last in
            last = max(last + 1, now)
            return last
        }
    }

    /// The one writer of tapes: each row is appended as soon as it is built,
    /// carrying its call-end sequence; nothing waits on another row.
    public actor Tape {
        public static let shared = Tape()

        public func append(_ row: TapeRow, principal: String, dataRoot: URL) {
            write(row, principal: principal, dataRoot: dataRoot)
        }

        private func write(_ row: TapeRow, principal: String, dataRoot: URL) {
            let url = TurnPractice.file(dataRoot, principal, ".tape.jsonl")
            do {
                var line = try row.value.serializedData(pretty: false)
                guard line.count < TurnPractice.rowBytes else {
                    throw PersistenceCoreError.ioFailure("Practice row metadata exceeds its complete serialized byte bound; row not kept.")
                }
                line.append(0x0A)
                try SwiftNativePersistenceCore.appendLines(line, to: url)
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw CocoaError(.fileReadUnknown)
                }
                guard size > TurnPractice.tapeBytes else { return }
                // The oldest half by call-end sequence goes, whatever order rows landed in.
                let rows = try Data(contentsOf: url).split(separator: 0x0A).compactMap { line -> (UInt64, Data)? in
                    guard let value = try? JSONValue.parse(Data(line)), let row = TapeRow(value) else { return nil }
                    return (row.sequence, Data(line))
                }.sorted { $0.0 < $1.0 }
                var kept = Data()
                for (_, line) in rows.suffix(max(1, rows.count / 2)) { kept.append(contentsOf: line); kept.append(0x0A) }
                try SwiftNativePersistenceCore.writeDataAtomicDurable(kept, to: url)
            } catch {
                TurnPractice.diagnostics("[practice] tape row %@ for %@ not kept: %@", row.receipt, principal, error.localizedDescription)
            }
        }
    }

    /// The agent's tape by receipt; a line that does not read is skipped and counted.
    public static func tape(_ dataRoot: URL, principal: String) -> (rows: [String: TapeRow], unreadable: Int) {
        let url = file(dataRoot, principal, ".tape.jsonl")
        guard let data = try? Data(contentsOf: url) else { return ([:], 0) }
        var rows: [String: TapeRow] = [:], unreadable = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let value = try? JSONValue.parse(Data(line)), let row = TapeRow(value) { rows[row.receipt] = row } else { unreadable += 1 }
        }
        return (rows, unreadable)
    }

    // MARK: - Examples

    public struct Example: Sendable, Equatable {
        public let turn: String
        public let calls: [TapeRow]
        public var at: Date { calls.first?.at ?? .distantPast }
        /// Some call's result has paths left out: what the route can read of
        /// it is what was kept; a later argument that came from a left-out
        /// path has no source there, so the value-flow map calls it judgment.
        public var partial: Bool { calls.contains { !$0.omitted.isEmpty } }
    }

    public static func evidence(_ examples: [Example]) throws -> String {
        let bytes = try JSONValue.array(examples.map { .object([
            "turn": .string($0.turn), "calls": .array($0.calls.map(\.value)),
        ]) }).serializedData(pretty: false)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The sequence's occurrences since `since`, the latest in each turn, and
    /// those whose every call the tape can replay, its arguments exact (the
    /// examples, newest first). Results count as far as they were kept: the
    /// value-flow map reads only kept paths, and the replay answers only them.
    public static func examples(of symbols: [String], in turns: [Turn], tape: [String: TapeRow], since: Date) -> (seen: Int, examples: [Example]) {
        var seen = 0, examples: [Example] = []
        for turn in turns {
            let row = turn.calls
            guard row.count >= symbols.count else { continue }
            let starts = (0...(row.count - symbols.count)).filter { start in
                row[start].at >= since && (0..<symbols.count).allSatisfy { row[start + $0].symbol == symbols[$0] }
            }
            guard let start = starts.last else { continue }
            seen += 1
            let recorded = (0..<symbols.count).compactMap { tape[row[start + $0].receipt] }
            if recorded.count == symbols.count, recorded.allSatisfy(\.replayable) { examples.append(Example(turn: turn.id, calls: recorded)) }
        }
        return (seen, examples.sorted { $0.at > $1.at })
    }

    // MARK: - Value flow

    public enum Source: Sendable, Equatable {
        /// The same value in every example.
        case constant
        /// The value at `path` of call `call`'s result (1-based), in every example.
        case result(call: Int, path: String)
        /// The value at `path` of call `call`'s arguments (1-based), in every example.
        case argument(call: Int, path: String)
        /// No earlier value had it in every example: her model chose it.
        case judgment
    }

    public struct Slot: Sendable, Equatable {
        /// 1-based; call 1's arguments are the intent and have no slots.
        public let call: Int
        public let path: String
        public let source: Source
    }

    /// Where each argument of calls 2... came from, unified over every example
    /// (exact JSON equality at one path in all of them; two examples at least,
    /// since one cannot tell a constant from a flow). A varying value found at
    /// one earlier path in every example is a flow; one equal in all examples
    /// is a constant; anything else is judgment. Source bodies are indexed once
    /// in call, result-before-arguments and leaf order; omitted paths stay judgment.
    /// Searches use only the first 20,000 leaves, even when traversal is incomplete.
    public static func valueFlow(_ examples: [Example]) -> [Slot] {
        guard examples.count >= 2, let first = examples.first, first.calls.count >= 2 else { return [] }
        let sources = Dictionary(grouping: first.calls.dropLast().enumerated().flatMap { call, row in
            [(true, row.result ?? .null), (false, row.flowArguments)].flatMap { result, body in
                var paths: [(path: String, value: JSONValue)] = []
                body.leaves(into: &paths, limit: 20_000)
                return paths.map { (call: call, result: result, path: $0.path, value: $0.value) }
            }
        }, by: { $0.value })
        var slots: [Slot] = []
        for call in 1..<first.calls.count {
            var arguments: [(path: String, value: JSONValue)] = []
            first.calls[call].flowArguments.leaves(into: &arguments, limit: 20_000)
            for (path, value) in arguments {
                let values = examples.map { $0.calls.indices.contains(call) ? $0.calls[call].flowArguments.value(atPointer: path) : nil }
                if values.contains(where: { $0 == nil }) { slots.append(Slot(call: call + 1, path: path, source: .judgment)); continue }
                var source: Source = .constant
                if Set(values.compactMap { $0 }).count > 1 {
                    source = sources[value]?.first { candidate in
                        candidate.call < call && examples.indices.allSatisfy { index in
                            guard examples[index].calls.indices.contains(candidate.call) else { return false }
                            let row = examples[index].calls[candidate.call]
                            return (candidate.result ? row.result ?? .null : row.flowArguments).value(atPointer: candidate.path) == values[index]
                        }
                    }.map { candidate -> Source in
                        candidate.result ? .result(call: candidate.call + 1, path: candidate.path) : .argument(call: candidate.call + 1, path: candidate.path)
                    } ?? .judgment
                }
                slots.append(Slot(call: call + 1, path: path, source: source))
            }
        }
        return slots
    }

    /// A route whose later arguments are mostly her judgment does not compile:
    /// she would compose most of it again on every use, so it saves no thought
    /// (the assumption the majority rests on). Judged values become its inputs.
    public static func mostlyJudgment(_ slots: [Slot]) -> Bool {
        let judged = slots.filter { $0.source == .judgment }.count
        return judged > slots.count / 2
    }

}
