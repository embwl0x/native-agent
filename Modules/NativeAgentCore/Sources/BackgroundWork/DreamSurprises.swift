import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import MemoryV2
import CognitiveSubstrate
import Cognition
import DreamREMCycle
import TurnTrace
import Transcripts
import ToolRegistry

// Blueprint: | `DreamSurprises.swift` | `makeDreamSurpriseProvider`, `SurpriseReading`; CPU-only owner-attributed surprise for the dream and the night |

extension DreamBackgroundWork {
    public static func makeDreamSurpriseProvider(
        dataRoot: URL, cognitionRuntime: NativeCognitionRuntime
    ) -> DreamSurpriseProvider {
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        return { since, through in
            var reading = await SurpriseReading.read(dataRoot: dataRoot, since: since, through: through)
            if let failure = reading.sourceFailure { throw failure }
            await cognitionRuntime.bootstrap()
            // Read the agent's live owner, never the persisted body behind its back.
            let body = await cognitionRuntime.organismKernel.exportPersistentState()
            let predictions = Array(body?.predictionLedger.predictions.values ?? [:].values)
            var violations = predictions.filter { row in
                row.status == .violated && row.lastUpdatedAt > since && row.lastUpdatedAt <= through
            }
            violations.sort { left, right in
                left.lastUpdatedAt == right.lastUpdatedAt ? left.id < right.id : left.lastUpdatedAt > right.lastUpdatedAt
            }
            if !violations.isEmpty {
                var organism = ["Body predictions: \(violations.count) violated."]
                for row in violations.prefix(3) {
                    let subject: String = row.horizon.map { "; about " + $0.label } ?? ""
                    organism.append("Expected " + row.kind.humanLabel + " (" + row.sourceOrgan + subject + "); it did not happen.")
                }
                reading.groups.append(.init(section: .organism, owner: SurpriseReading.Owner.none, kind: "organism", count: violations.count, lines: organism))
            }
            let records = try await memory.listMemory(kind: nil)
            let corrections = records.filter { record in
                guard record.status == "active",
                      !MemoryStorage.metadataFlag(record.extras, MemoryStorage.pendingAdmissionKey),
                      let date = ConversationHistory.parseTimestamp(.string(record.createdAt)),
                      date > since, date <= through else { return false }
                let meta = record.extras?.objectValue ?? [:]
                let replaces = meta[MemoryManagerLane.supersedesKey] != nil
                guard MemoryRecallScoring.isCorrection(record, tags: record.tags ?? []) || replaces else { return false }
                let speaker = record.evidence?.objectValue?["speaker"]?.stringValue
                // Only attributed owner evidence proves the person authored the correction.
                return speaker == CognitiveCare.ownerKey || speaker == "user"
            }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
            if !corrections.isEmpty {
                // The words the dream learns from are the memory records'; the ledger's attributed counts carry no lines.
                reading.groups.append(.init(section: .corrections, owner: SurpriseReading.Owner.none, kind: "correction_words", count: corrections.count,
                    lines: ["User's corrections: \(corrections.count) saved."] + corrections.prefix(3).map { $0.text }))
            }
            return reading.dreamBlock()
        }
    }
}

/// One reading of what surprised the agent's body in (since, through], each group owned by the part whose prediction missed.
/// The dream renders its lines; the night counts the owned groups. CPU only; it writes nothing.
public struct SurpriseReading: Sendable {
    public enum Owner: Hashable, Sendable {
        case ability(String)
        /// The turn program by the body digest its helper opened in that turn; nil when the turn's helper record is absent.
        case turnProgram(String?)
        /// No reshapable code owns it: the dream only.
        case none
    }
    /// The dream's sections, in the order its block shows them.
    public enum Section: Int, CaseIterable, Sendable { case failures, expansion, organism, corrections, turnProgram }
    public struct Group: Sendable {
        public let section: Section
        public let owner: Owner
        public let kind: String
        /// nil when the source reports lines without a count.
        public let count: Int?
        public let uses: Int?
        public let lines: [String]

        init(section: Section, owner: Owner, kind: String, count: Int?, uses: Int? = nil, lines: [String]) {
            (self.section, self.owner, self.kind, self.count, self.uses, self.lines) = (section, owner, kind, count, uses, lines)
        }
    }
    /// A source the reading could not read: `unreadable` rows of it, or the whole source when nil.
    public struct Gap: Sendable, Equatable {
        public let source: String
        public let unreadable: Int?
        public let cause: String?

        init(source: String, unreadable: Int?, cause: String? = nil) {
            (self.source, self.unreadable, self.cause) = (source, unreadable, cause)
        }
    }
    /// One surprise of an ability, timed so the night finds the version that ran it.
    public struct Timed: Sendable {
        public let owner: Owner
        /// "corrected" or "slog".
        public let kind: String
        /// The settle time of the corrected turn, or a slog's third repeated call.
        public let at: Date
    }
    /// The turn program's own surprise kinds, each counted once per settled turn.
    public static let turnKinds = ["incomplete", "stopped", "repeated", "malformed", "healed"]
    /// Repeated identical top-level calls of one ability in one turn that make a slog.
    static let slogRun = 3

    public internal(set) var groups: [Group] = []
    /// The window's ability surprises one by one, `.ability` owners only, each caused in the window: a correction made in it, or a slog whose
    /// third call is in it. A corrected turn may have settled before the window opened.
    public internal(set) var surprises: [Timed] = []
    /// Finished non-preview dispatches of `authored.<id>`, and settled turns per turn-program version.
    public internal(set) var uses: [Owner: Int] = [:]
    /// Kinds on each settled use in this window. Rates take the union of turns; group totals remain diagnostics.
    private var turnSurprises: [Owner: [String: Set<String>]] = [:]
    public internal(set) var gaps: [Gap] = []
    var sourceFailure: (any Error)?

    /// Misses of the owner's own code: every owned group except corrections, which are a surprise kind of their own.
    public func misses(_ owner: Owner) -> Int {
        if case .turnProgram = owner {
            return (turnSurprises[owner] ?? [:]).values.filter { !$0.subtracting(["corrected"]).isEmpty }.count
        }
        return groups.filter { $0.owner == owner && $0.kind != "corrected" }.reduce(0) { $0 + ($1.count ?? 0) }
    }
    /// Settled uses with any surprise, including corrections, once per turn regardless of how many kinds it carries.
    public func surprisedUses(_ owner: Owner) -> Int { turnSurprises[owner]?.count ?? 0 }
    public func count(_ owner: Owner, kind: String) -> Int {
        groups.filter { $0.owner == owner && $0.kind == kind }.reduce(0) { $0 + ($1.count ?? 0) }
    }

    /// A correction answers the reply before it: the corrected turn may have settled up to this long before the window opened.
    static let attributionLookback: TimeInterval = 86_400

    public static func read(dataRoot: URL, since: Date, through: Date) async -> SurpriseReading {
        var reading = SurpriseReading()
        let kinds = ["tool.dispatch", "expansion.check", "turn.terminal", "turn.cancelled", "turn.failed", "turn.observation",
                     "turn.part.recovered", "turn.part.helper"]
        let read: TraceRead
        do {
            read = try await TurnTracePersistLane(dataRootOverride: dataRoot)
                .events(.init(kinds: kinds, from: since.addingTimeInterval(-attributionLookback), through: through))
        } catch {
            reading.sourceFailure = error
            reading.gaps.append(Gap(source: "turn_traces", unreadable: nil, cause: error.localizedDescription))
            return reading
        }
        if !read.isClean {
            reading.gaps.append(Gap(source: "turn_traces", unreadable: read.unreadable))
            reading.sourceFailure = PersistenceCoreError.ioFailure("The turn record contains \(read.unreadable) unreadable details.")
            return reading
        }
        var traces = TraceCollection(reading: reading)
        do {
            try traces.collect(read.events, since: since, through: through)
            traces.project()
        } catch {
            reading.sourceFailure = error
            reading.gaps.append(Gap(source: "turn_traces", unreadable: nil, cause: error.localizedDescription))
            return reading
        }
        do {
            let moments = try await SwiftNativeMemoryV2.correctionMoments(dataRoot: dataRoot, since: since, through: through)
            traces.attribute(moments)
        } catch {
            traces.reading.sourceFailure = error
            traces.reading.gaps.append(Gap(source: "correction_ledger", unreadable: nil, cause: error.localizedDescription))
        }
        return traces.reading
    }

    private struct TraceCollection {
        struct FailureKey: Hashable { let action, code: String }
        struct Heal: Hashable { let turn, digest: String }
        struct Call: Equatable { let action: String; let arguments: String? }
        struct Slog: Hashable { let turn, part: String }
        var reading: SurpriseReading
        var failures: [FailureKey: (count: Int, reason: String)] = [:]
        var expansionCount = 0
        var expansionExamples: [String] = []
        var helper: [String: String] = [:]
        var parts: [String: Set<String>] = [:]
        var surprised: [String: Set<String>] = [:]
        var heals = Set<Heal>()
        var settled: [(turn: String, session: String?, at: Date, inWindow: Bool)] = []
        var streak: [String: (call: Call, length: Int)] = [:]
        var slogged = Set<Slog>()
        var counted = Set<String>()

        mutating func collect(_ events: [TurnTraceEvent], since: Date, through: Date) throws {
            for event in events {
                guard let fields = event.payload.objectValue else { throw malformed(event, field: "payload") }
                // Preview receipts, even refused ones, cannot become learning material for a real dream.
                guard fields["receipt"]?.objectValue?["preview"] != .bool(true) else { continue }
                let inWindow = event.ts > since && event.ts <= through
                switch event.kind {
                case "turn.part.helper":
                    // The version a turn opened with owns that turn; a helper opened after recovery runs another version.
                    guard let digest = fields["version"]?.stringValue else { throw malformed(event, field: "version") }
                    if helper[event.turnId] == nil { helper[event.turnId] = digest }
                case "tool.dispatch":
                    guard let action = fields["receipt"]?.objectValue?["action"]?.stringValue else {
                        throw malformed(event, field: "receipt.action")
                    }
                    if fields["phase"] == .string("end"), let part = ToolNameAliases.authoredTool(action) {
                        parts[event.turnId, default: []].insert(part)
                        if inWindow { reading.uses[.ability(part), default: 0] += 1 }
                    }
                    // A slog: one ability called at the top level with the same args preview three times in a row in one turn, once per turn.
                    // Any other top-level call between breaks the run; nested calls are the ability's own. Native repeats are the turn program's.
                    if fields["phase"] == .string("end"), fields["parentId"] == nil {
                        let call = Call(action: action, arguments: fields["args"]?.stringValue)
                        let length = streak[event.turnId].map { $0.call == call ? $0.length + 1 : 1 } ?? 1
                        streak[event.turnId] = (call, length)
                        if length == SurpriseReading.slogRun, call.arguments != nil, let part = ToolNameAliases.authoredTool(action),
                           slogged.insert(Slog(turn: event.turnId, part: part)).inserted, inWindow {
                            reading.surprises.append(Timed(owner: .ability(part), kind: "slog", at: event.ts))
                        }
                    }
                    guard inWindow, fields["status"] == .string("failed") else { continue }
                    let code = fields["failure_code"]?.stringValue ?? fields["code"]?.stringValue ?? "unlabelled failure"
                    let key = FailureKey(action: action, code: code)
                    if let failure = failures[key] { failures[key] = (failure.count + 1, failure.reason) }
                    else {
                        var reasons: [String] = []
                        for field in ["reason", "error", "detail", "errorDetail"] {
                            if let reason = fields[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !reason.isEmpty, !reasons.contains(reason) { reasons.append(reason) }
                        }
                        let reason = reasons.isEmpty ? "No reason recorded" : reasons.joined(separator: "; ")
                        let path = fields["argument_path"]?.stringValue.map { " (argument: \($0))" } ?? ""
                        failures[key] = (1, reason + path)
                    }
                case "expansion.check":
                    guard inWindow, fields["outcome"] == .string("miss") else { continue }
                    expansionCount += 1
                    guard let situation = fields["situation"]?.stringValue,
                          let prediction = fields["prediction"]?.stringValue else { throw malformed(event, field: "situation/prediction") }
                    expansionExamples.append("At \(situation), expected \(prediction); the next call differed or never came.")
                    if expansionExamples.count > 3 { expansionExamples.removeFirst() }
                case "turn.observation":
                    guard let reason = fields["reason"]?.stringValue else { throw malformed(event, field: "reason") }
                    if ["reply_repeated_block", "reply_repeated_action"].contains(reason) { surprised[event.turnId, default: []].insert("repeated") }
                    if reason == "malformed_call" { surprised[event.turnId, default: []].insert("malformed") }
                case "turn.part.recovered":
                    if inWindow, let from = fields["fromDigest"]?.stringValue { heals.insert(Heal(turn: event.turnId, digest: from)) }
                default:
                    // turn.terminal, turn.cancelled and turn.failed settle the turn.
                    let status = fields["status"]?.stringValue ?? ""
                    if event.kind == "turn.cancelled" || status == "stopped" { surprised[event.turnId, default: []].insert("stopped") }
                    if event.kind == "turn.failed" || ["interrupted", "failed"].contains(status) {
                        surprised[event.turnId, default: []].insert("incomplete")
                    }
                    settled.append((event.turnId, event.sessionId, event.ts, inWindow))
                }
            }
        }

        mutating func project() {
            let failed = failures.sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                if $0.key.action != $1.key.action { return $0.key.action < $1.key.action }
                return $0.key.code < $1.key.code
            }
            for (key, value) in failed {
                let owner: Owner = ToolNameAliases.authoredTool(key.action).map { Owner.ability($0) } ?? Owner.none
                reading.groups.append(.init(section: .failures, owner: owner, kind: "failed", count: value.count, uses: reading.uses[owner],
                    lines: ["\(key.action) [\(key.code)] ×\(value.count): \(value.reason)"]))
            }
            if expansionCount > 0 {
                reading.groups.append(.init(section: .expansion, owner: SurpriseReading.Owner.none, kind: "expansion_miss", count: expansionCount,
                    lines: ["Expansion predictions: \(expansionCount) missed."] + expansionExamples))
            }
            // A turn is a use of the turn program once it settles in the window; each of its own kinds counts once for that turn.
            var turnCounts: [Owner: [String: Int]] = [:]
            for turn in settled where turn.inWindow && counted.insert(turn.turn).inserted {
                let owner = Owner.turnProgram(helper[turn.turn])
                reading.uses[owner, default: 0] += 1
                let kinds = surprised[turn.turn] ?? []
                if !kinds.isEmpty { reading.turnSurprises[owner, default: [:]][turn.turn] = kinds }
                for kind in kinds { turnCounts[owner, default: [:]][kind, default: 0] += 1 }
            }
            // A heal belongs to the version that failed, once per turn.
            for heal in heals {
                let owner = Owner.turnProgram(heal.digest)
                turnCounts[owner, default: [:]]["healed", default: 0] += 1
                if counted.contains(heal.turn), helper[heal.turn] == heal.digest {
                    reading.turnSurprises[owner, default: [:]][heal.turn, default: []].insert("healed")
                }
            }
            let phrases = ["incomplete": "ended incomplete or failed", "stopped": "were stopped", "repeated": "repeated a block or action",
                           "malformed": "made a malformed call", "healed": "needed the turn part healed"]
            for (owner, counts) in turnCounts.sorted(by: { SurpriseReading.order($0.key) < SurpriseReading.order($1.key) }) {
                for kind in SurpriseReading.turnKinds where (counts[kind] ?? 0) > 0 {
                    let count = counts[kind] ?? 0, uses = reading.uses[owner]
                    let share = uses.map { "\(count) of \($0) turns" } ?? "\(count) turns"
                    reading.groups.append(.init(section: .turnProgram, owner: owner, kind: kind, count: count, uses: uses,
                        lines: ["Turn program: \(share) \(phrases[kind] ?? kind)."]))
                }
            }
        }

        mutating func attribute(_ moments: [CorrectionMoment]) {
            // Each correction is owned by the latest turn that settled before it in its session: the abilities that turn ran, else the turn program.
            var corrected: [Owner: Int] = [:]
            for moment in moments {
                let before = settled.filter { $0.session != nil && $0.session == moment.session && $0.at < moment.at }.max { $0.at < $1.at }
                guard let turn = before?.turn, let settledAt = before?.at else { corrected[Owner.none, default: 0] += 1; continue }
                let ran = (parts[turn] ?? []).sorted()
                if ran.isEmpty {
                    let owner = Owner.turnProgram(helper[turn])
                    corrected[owner, default: 0] += 1
                    if counted.contains(turn) { reading.turnSurprises[owner, default: [:]][turn, default: []].insert("corrected") }
                }
                for part in ran {
                    corrected[.ability(part), default: 0] += 1
                    reading.surprises.append(Timed(owner: .ability(part), kind: "corrected", at: settledAt))
                }
            }
            for (owner, count) in corrected.sorted(by: { SurpriseReading.order($0.key) < SurpriseReading.order($1.key) }) {
                reading.groups.append(.init(section: .corrections, owner: owner, kind: "corrected", count: count, uses: reading.uses[owner], lines: []))
            }
        }

        private func malformed(_ event: TurnTraceEvent, field: String) -> PersistenceCoreError {
            .ioFailure("\(event.kind) for turn \(event.turnId) has no readable \(field); repair its retained detail before learning from it.")
        }
    }

    static func order(_ owner: Owner) -> String {
        switch owner {
        case .ability(let id): "0" + id
        case .turnProgram(let digest): "1" + (digest ?? "")
        case .none: "2"
        }
    }

    /// The dream's block: each section's lines in section order; failures lead with any unreadable-record note, then the eight largest groups.
    func dreamBlock() -> String {
        DreamSurprises.block(sections: Section.allCases.map { section in
            let present = groups.filter { $0.section == section && !$0.lines.isEmpty }
            guard section == .failures else { return present.flatMap(\.lines) }
            let failed = present.filter { $0.kind == "failed" }
            return present.filter { $0.kind != "failed" }.flatMap(\.lines)
                + (failed.isEmpty ? [] : ["Failed calls (by action and code):"] + failed.prefix(8).flatMap(\.lines))
        })
    }
}

enum DreamSurprises {
    /// Reserve space for every present kind before filling the remainder with examples.
    static func block(sections: [[String]]) -> String {
        let present = sections.filter { !$0.isEmpty }
        guard !present.isEmpty else { return "" }
        // Leave room for the prompt-owned header within the 2,500-character block.
        let allowance = (2_400 - present.count) / present.count
        return present.map { lines in
            var left = allowance
            return lines.compactMap { line -> String? in
                let flat = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard !flat.isEmpty, left > 4 else { return nil }
                let clipped = flat.count <= min(220, left - 3)
                    ? flat : String(flat.prefix(min(219, left - 4))) + "…"
                let rendered = "- \(clipped)\n"
                left -= rendered.count
                return rendered
            }.joined()
        }.joined(separator: "\n")
    }
}
