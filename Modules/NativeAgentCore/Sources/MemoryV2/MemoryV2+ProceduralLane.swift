import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - The procedural lane (sweep item 38; procedural-memory-lane.md)
//
// The triad's third leg. Dreams turn experience into identity (REM → GROWTH,
// approval-gated); this turns REPETITION into craft, through the same gate.
//
// SHAPE — clause 4. The 2026-07-03 plan drew a WEEKLY job: Sunday 05:30,
// claim token, gather seven days of traces, distill. That is a scheduler
// imitating attention. This lane fires on the repetition ITSELF: the after-
// turn hook hands it what the turn did, and the moment the n-th qualifying
// repeat LANDS the proposal is minted. No timer, no budget, no watchdog. On a
// quiet week nothing runs, because nothing happened — not because a job found
// an empty window.
//
// SOURCE — no new event capture. The lane reads the bounded tool-evidence
// projection the promoter already receives (sweep item 35,
// `TurnToolEvidenceProjection`): success-only, secret-redacted, ≤ 6 lines. It
// keeps only the SHAPE of each line — the tool name and its argument KEYS —
// so nothing it stores can leak a path, a filename, or a value.
//
// FLOOR — the plan's: ≥ 3 occurrences across ≥ 2 distinct days, same ordered
// sequence, compatible argument shapes, every recorded run a verified success.
//
// That last clause needs the WHOLE turn, not the success-only slice (HIGH
// review finding, 2026-09-01). The projection drops what failed, so
// `read ok, write ok, run_tests failed` arrives here as `read → write`: a
// contiguous verified run that never happened, with the failure stitched out.
// The projection now states the break instead of hiding it — one payload-free
// `sequenceBreakMarker` line whenever the turn carried a non-success dispatch
// or the window was truncated — and this lane counts NOTHING from a turn
// carrying that marker. A broken turn is ignored, not counted and not reset:
// a bad afternoon is still not evidence against a procedure that works.
//
// BOUNDS — ≤ 1 proposal per SEQUENCE IDENTITY (the shape digest), at most
// `pendingProposalCap` procedural cards pending at once. The identity is the
// only dedupe key, held in three places that must agree: the occurrence
// ledger's row, the durable `ProceduralProposedSequenceStore`, and the filed
// card's payload. The compiled procedure's `id` is NOT that key — its digest
// folds in the occurrence count and the observed days, so the same sequence
// re-mints on a different day (MEDIUM→HIGH review finding, 2026-09-01).
// Nothing here enters a prompt (clause 6): the mint writes a card, and only
// the owner's approval turns it into a skill body and one recall pointer.

/// A verified motor outcome, as the payload-free tuple the body survey named.
///
/// SEAM (2026-09-01): `MotorActionReadModel` — the shared read-only motor
/// projection — exposes `domain`, `actionIdentity`, `phase`, `domainState`,
/// `verification` and `expectedNextEvidence`. It does NOT yet expose
/// `bundle_id`, `verb`, or `target_role`. This type is the receiving end of
/// that tuple and nothing in the app constructs it yet: when MacControl's read
/// model projects the three missing fields, the only work left is mapping them
/// here and passing them to `observeTurn`. The lane treats a motor step as a
/// first-class repetition the moment it arrives — no other change is needed.
public struct ProceduralMotorStep: Sendable, Equatable {
    public let bundleID: String
    public let verb: String
    public let targetRole: String
    /// The read model's verification state. Only `satisfied` counts.
    public let verification: String

    public init(bundleID: String, verb: String, targetRole: String, verification: String) {
        self.bundleID = bundleID
        self.verb = verb
        self.targetRole = targetRole
        self.verification = verification
    }

    /// Verified motor outcomes only. An unverified completion is not a
    /// repetition worth learning: completion and verification are not
    /// synonyms (the read model says so in its own doc comment).
    public var isVerified: Bool { verification.lowercased() == "satisfied" }

    public var stepShape: ProceduralStepShape {
        ProceduralStepShape(
            origin: .motor,
            action: "\(bundleID):\(verb)",
            argumentKeys: [targetRole],
            verificationClass: "motor_verification_satisfied"
        )
    }
}

public struct ProceduralLaneConfiguration: Sendable, Equatable {
    /// The plan's floor: ≥ 3 occurrences.
    public let minimumOccurrences: Int
    /// ...across ≥ 2 distinct days.
    public let minimumDistinctDays: Int
    /// A single tool is not a procedure.
    public let minimumSequenceLength: Int
    /// Beyond this a "sequence" is just a long turn.
    public let maximumSequenceLength: Int
    /// Skills are heavy; a backlog of unreviewed craft is clutter, not reach.
    public let pendingProposalCap: Int
    /// Ledger rows retained. Bounds the file without bounding the evidence
    /// that matters: rows are evicted oldest-touched first.
    public let maximumLedgerEntries: Int

    public init(
        minimumOccurrences: Int = 3,
        minimumDistinctDays: Int = 2,
        minimumSequenceLength: Int = 2,
        maximumSequenceLength: Int = 6,
        pendingProposalCap: Int = 8,
        maximumLedgerEntries: Int = 512
    ) {
        self.minimumOccurrences = max(2, minimumOccurrences)
        self.minimumDistinctDays = max(2, minimumDistinctDays)
        self.minimumSequenceLength = max(2, minimumSequenceLength)
        self.maximumSequenceLength = max(minimumSequenceLength, maximumSequenceLength)
        self.pendingProposalCap = max(1, pendingProposalCap)
        self.maximumLedgerEntries = max(16, maximumLedgerEntries)
    }
}

/// What one `observeTurn` did. Payload-free; safe for a receipt.
public enum ProceduralLaneOutcome: Sendable, Equatable {
    /// The turn carried nothing this lane counts (no eligible sequence).
    case ignored
    /// Counted, floor not reached yet.
    case counted(sequenceIdentity: String, occurrences: Int, distinctDays: Int)
    /// The floor landed and one proposal was staged.
    case minted(approvalID: String, procedureID: String, sequenceIdentity: String)
    /// The floor landed but the lane declined to stage.
    case blocked(ProceduralLaneBlockReason)
}

public enum ProceduralLaneBlockReason: String, Sendable, Equatable {
    /// This sequence already produced its one proposal.
    case alreadyProposedForSequence = "already_proposed_for_sequence"
    /// A card carrying an identical compiled digest is already filed.
    case duplicateProcedureDigest = "duplicate_procedure_digest"
    /// Too many procedural cards already waiting on the owner.
    case pendingCapReached = "pending_cap_reached"
    /// The inbox could not be read or written; nothing was staged.
    case stagingFailed = "staging_failed"
}

// MARK: - Denylist

public enum ProceduralLaneDenylist {
    /// Tools whose success proves nothing durable.
    ///
    /// This is the SAME set `TurnToolEvidenceProjection.transientReaders`
    /// applies upstream, restated here because the module graph forbids the
    /// import (ChatOrchestration depends on MemoryV2, never the reverse) and
    /// because a boundary that trusts its caller's bound is not bounded — the
    /// doctrine `AdaptiveToolEvidence` states one file over. If the upstream
    /// set grows, grow this one; a name in only one of them is filtered by the
    /// projection anyway, never admitted by mistake.
    public static let transientReaders: Set<String> = [
        "battery", "clock", "context_expand", "current_time", "date",
        "get_time", "get_weather", "list_notifications", "look", "observe",
        "ping", "random", "recall_memory", "roll", "screen", "screenshot",
        "search_chat_history", "search_memory", "memory_search",
        "session_search", "system_status", "time", "view", "weather",
    ]

    public static func admits(_ tool: String) -> Bool {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !name.isEmpty && !transientReaders.contains(name)
    }
}

// MARK: - Shaping the evidence lines

public enum ProceduralEvidenceShaper {
    /// Longest tool name we will treat as a tool name.
    static let maximumActionCharacters = 64
    /// Argument keys per step. Matches the projection's own input cap.
    static let maximumArgumentKeys = 2

    /// The success token the projection writes after the name and arguments,
    /// and the ONLY status this shaper accepts. Stamping
    /// `tool_result_succeeded` on any line that merely STARTS with a tool name
    /// made the verification class a guess (MEDIUM review finding,
    /// 2026-09-01); it is now read off the line.
    static let successToken = "ok"

    /// Status words that are never a verified success, checked explicitly so a
    /// future producer cannot slip one past the equality above by writing e.g.
    /// `ok, then failed`.
    static let rejectedStatusWords: Set<String> = [
        "cancelled", "canceled", "denied", "error", "failed", "failure",
        "pending", "pending_approval", "queued", "skipped", "timeout",
        "timed_out", "unknown", "unverified",
    ]

    /// The line `TurnToolEvidenceProjection` appends when the turn was not a
    /// contiguous verified run. Restated here, not imported: the module graph
    /// forbids the import (ChatOrchestration depends on MemoryV2, never the
    /// reverse), the same reason `ProceduralLaneDenylist` restates the
    /// upstream reader set. Keep the two literals identical.
    public static let sequenceBreakMarker = "!seq-break"

    /// True when the turn's evidence says its own window is not proof that a
    /// procedure ran start to finish.
    public static func carriesSequenceBreak(_ lines: [String]) -> Bool {
        lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == sequenceBreakMarker }
    }

    /// Turn the promoter's evidence lines into ordered step shapes.
    ///
    /// The projection's line format is its own documented contract:
    /// `name ok`, `name(k=v, k2=v2) ok`, either optionally followed by
    /// `: <result>`. Only the name and the KEYS are read — never a value,
    /// never the result — so the ledger cannot hold a path or a filename.
    public static func steps(from lines: [String]) -> [ProceduralStepShape] {
        lines.compactMap(step(from:))
    }

    public static func step(from line: String) -> ProceduralStepShape? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Everything before the first "(" or the first " " is the tool name.
        let head = trimmed.prefix { $0 != "(" && $0 != " " }
        let action = String(head).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, action.count <= maximumActionCharacters,
              action.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }),
              ProceduralLaneDenylist.admits(action) else { return nil }

        var cursor = trimmed.index(trimmed.startIndex, offsetBy: head.count)
        var keys: [String] = []
        if cursor < trimmed.endIndex, trimmed[cursor] == "(" {
            // An unclosed argument list is a malformed line, not a step.
            guard let close = trimmed[cursor...].firstIndex(of: ")") else { return nil }
            let inner = trimmed[trimmed.index(after: cursor)..<close]
            for pair in inner.split(separator: ",") {
                let key = pair.split(separator: "=", maxSplits: 1).first
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                guard !key.isEmpty, key.count <= 40,
                      key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                      !keys.contains(key) else { continue }
                keys.append(key)
                if keys.count >= maximumArgumentKeys { break }
            }
            cursor = trimmed.index(after: close)
        }

        // The status sits between the name/arguments and the optional
        // `: <result>`. It must BE the success token — a bare `read_file`, a
        // `read_file failed`, or a `read_file pending` is not a verified step.
        let status = trimmed[cursor...]
            .prefix { $0 != ":" }
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard status == successToken, !rejectedStatusWords.contains(status) else { return nil }

        return ProceduralStepShape(
            origin: .tool,
            action: action,
            argumentKeys: keys,
            // Read off the line, not assumed: the token above is the
            // projection's rendering of `exactResultClass == .succeeded`,
            // which never reads a missing status as success.
            verificationClass: "tool_result_succeeded"
        )
    }

    public static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Ledger

/// One counted sequence. Payload-free: an identity, a count, day buckets.
public struct ProceduralLedgerEntry: Sendable, Equatable {
    public var sequenceIdentity: String
    public var steps: [ProceduralStepShape]
    public var occurrenceCount: Int
    public var days: [String]
    public var lastSeenAt: String
    /// Set once, when this sequence mints its one proposal. Its presence is
    /// what makes a fourth repeat cost nothing.
    public var proposedProcedureID: String?

    var jsonValue: JSONValue {
        .object([
            "sequenceIdentity": .string(sequenceIdentity),
            "steps": .array(steps.map { step in
                .object([
                    "origin": .string(step.origin.rawValue),
                    "action": .string(step.action),
                    "argumentKeys": .array(step.argumentKeys.map { .string($0) }),
                    "verificationClass": .string(step.verificationClass),
                ])
            }),
            "occurrenceCount": .int(Int64(occurrenceCount)),
            "days": .array(days.map { .string($0) }),
            "lastSeenAt": .string(lastSeenAt),
            "proposedProcedureId": proposedProcedureID.map { .string($0) } ?? .null,
        ])
    }

    init(
        sequenceIdentity: String,
        steps: [ProceduralStepShape],
        occurrenceCount: Int,
        days: [String],
        lastSeenAt: String,
        proposedProcedureID: String?
    ) {
        self.sequenceIdentity = sequenceIdentity
        self.steps = steps
        self.occurrenceCount = occurrenceCount
        self.days = days
        self.lastSeenAt = lastSeenAt
        self.proposedProcedureID = proposedProcedureID
    }

    init?(jsonValue: JSONValue) {
        guard case .object(let row) = jsonValue,
              case .string(let identity)? = row["sequenceIdentity"],
              case .array(let rawSteps)? = row["steps"],
              case .string(let lastSeen)? = row["lastSeenAt"] else { return nil }
        var steps: [ProceduralStepShape] = []
        for raw in rawSteps {
            guard case .object(let step) = raw,
                  case .string(let originRaw)? = step["origin"],
                  let origin = ProceduralStepOrigin(rawValue: originRaw),
                  case .string(let action)? = step["action"],
                  case .string(let verification)? = step["verificationClass"] else { return nil }
            var keys: [String] = []
            if case .array(let rawKeys)? = step["argumentKeys"] {
                for key in rawKeys { if case .string(let k) = key { keys.append(k) } }
            }
            steps.append(ProceduralStepShape(
                origin: origin, action: action, argumentKeys: keys,
                verificationClass: verification
            ))
        }
        var days: [String] = []
        if case .array(let rawDays)? = row["days"] {
            for day in rawDays { if case .string(let d) = day { days.append(d) } }
        }
        let occurrences: Int = {
            if case .int(let value)? = row["occurrenceCount"] { return Int(value) }
            return 0
        }()
        let proposed: String? = {
            if case .string(let value)? = row["proposedProcedureId"], !value.isEmpty {
                return value
            }
            return nil
        }()
        self.init(
            sequenceIdentity: identity, steps: steps, occurrenceCount: occurrences,
            days: days, lastSeenAt: lastSeen, proposedProcedureID: proposed
        )
    }
}

/// The lane's own durable memory of what it has seen. One small JSON file,
/// written under the same cross-process flock every other store here holds.
public struct ProceduralLaneLedger: Sendable {
    public static let schema = "procedural-lane-ledger.v1"

    let path: URL
    private let persistence: any PersistenceCoreProtocol

    public init(dataRoot: URL, persistence: (any PersistenceCoreProtocol)? = nil) {
        self.path = dataRoot
            .appendingPathComponent("procedural_lane", isDirectory: true)
            .appendingPathComponent("ledger.json")
        self.persistence = persistence ?? SwiftNativePersistenceCore()
    }

    public func load() async -> [String: ProceduralLedgerEntry] {
        let raw = await persistence.readJSON(path, defaultValue: .null)
        return Self.decode(raw)
    }

    static func decode(_ raw: JSONValue) -> [String: ProceduralLedgerEntry] {
        guard case .object(let root) = raw, case .array(let rows)? = root["entries"] else {
            return [:]
        }
        var out: [String: ProceduralLedgerEntry] = [:]
        for row in rows {
            guard let entry = ProceduralLedgerEntry(jsonValue: row) else { continue }
            out[entry.sequenceIdentity] = entry
        }
        return out
    }

    static func encode(_ entries: [String: ProceduralLedgerEntry], limit: Int) -> JSONValue {
        // Evict oldest-touched first so a long tail of one-off sequences can
        // never crowd out the ones actually repeating.
        let ordered = entries.values
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(limit)
        return .object([
            "schema": .string(schema),
            "entries": .array(ordered.map(\.jsonValue)),
        ])
    }

    /// Read → mutate → write inside ONE lock, so two turns finishing at once
    /// cannot both read "2 occurrences" and both mint.
    func mutate<T: Sendable>(
        limit: Int,
        _ body: @Sendable (inout [String: ProceduralLedgerEntry]) async -> T
    ) async throws -> T {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return try await persistence.withFileLock(path) {
            let raw = await persistence.readJSON(path, defaultValue: .null)
            var entries = Self.decode(raw)
            let result = await body(&entries)
            try await persistence.writeJSON(Self.encode(entries, limit: limit), to: path)
            return result
        }
    }
}

// MARK: - Already-proposed sequences

/// The lane's durable answer to "have I already asked about this shape?".
///
/// Separate file, separate cap, on purpose. The occurrence ledger is bounded
/// at `maximumLedgerEntries` (512) and evicts oldest-touched first, so a busy
/// month drops the very row whose `proposedProcedureID` said "already asked" —
/// and the sequence re-mints (review finding, 2026-09-01). This file holds
/// identities and nothing else, so the same byte budget buys an order of
/// magnitude more history, and nothing about counting pressure can evict it.
///
/// Path-owned cap discipline: this type owns this path and this bound. The
/// oldest identity is dropped from the FRONT when the cap is reached — after
/// 4096 distinct minted sequences, re-asking about the very first one is the
/// correct failure.
public struct ProceduralProposedSequenceStore: Sendable {
    public static let schema = "procedural-lane-proposed-sequences.v1"
    /// Opaque identities only (~64 chars each): ~300 KB at the cap.
    public static let maximumEntries = 4096

    let path: URL
    private let persistence: any PersistenceCoreProtocol

    public init(dataRoot: URL, persistence: (any PersistenceCoreProtocol)? = nil) {
        self.path = dataRoot
            .appendingPathComponent("procedural_lane", isDirectory: true)
            .appendingPathComponent("proposed_sequences.json")
        self.persistence = persistence ?? SwiftNativePersistenceCore()
    }

    /// Oldest first, newest last.
    public func load() async -> [String] {
        Self.decode(await persistence.readJSON(path, defaultValue: .null))
    }

    public func contains(_ identity: String) async -> Bool {
        await load().contains(identity)
    }

    /// Idempotent append under the same cross-process lock the ledger holds.
    /// Silent on failure for the lane's reason: a bookkeeping write is never
    /// worth a turn. A lost write costs at most one duplicate card, which the
    /// inbox dedupe below then catches.
    func record(_ identity: String) async {
        guard !identity.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? await persistence.withFileLock(path) {
            var identities = Self.decode(
                await persistence.readJSON(path, defaultValue: .null)
            )
            guard !identities.contains(identity) else { return }
            identities.append(identity)
            if identities.count > Self.maximumEntries {
                identities.removeFirst(identities.count - Self.maximumEntries)
            }
            try await persistence.writeJSON(Self.encode(identities), to: path)
        }
    }

    static func decode(_ raw: JSONValue) -> [String] {
        guard case .object(let root) = raw,
              case .array(let rows)? = root["sequenceIdentities"] else { return [] }
        var out: [String] = []
        for row in rows {
            if case .string(let identity) = row, !identity.isEmpty, !out.contains(identity) {
                out.append(identity)
            }
        }
        return out
    }

    static func encode(_ identities: [String]) -> JSONValue {
        .object([
            "schema": .string(schema),
            "sequenceIdentities": .array(identities.map { .string($0) }),
        ])
    }
}

// MARK: - The lane

public actor ProceduralLane {
    public static let shared = ProceduralLane()

    private let dataRoot: URL
    private let configuration: ProceduralLaneConfiguration
    private let ledger: ProceduralLaneLedger
    private let proposedSequences: ProceduralProposedSequenceStore
    private let inbox: SwiftNativeApprovalInbox
    private let clock: @Sendable () -> Date
    /// Sequences between "the floor landed" and "the card is filed". An actor
    /// is reentrant at every `await`, and the mint path awaits the inbox
    /// twice — without this, two turns finishing together could both pass the
    /// ledger's `alreadyProposed` check and file two cards for one n-gram.
    /// Checked and inserted with no `await` in between, so it is atomic.
    private var mintingSequences: Set<String> = []

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configuration: ProceduralLaneConfiguration = .init(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.configuration = configuration
        self.ledger = ProceduralLaneLedger(dataRoot: dataRoot)
        self.proposedSequences = ProceduralProposedSequenceStore(dataRoot: dataRoot)
        self.inbox = SwiftNativeApprovalInbox(root: dataRoot)
        self.clock = clock
    }

    /// The after-turn hook. Called once per completed turn from the production
    /// promoter seat, with the SAME bounded evidence lines the memory promoter
    /// receives — no second capture, no second projection.
    ///
    /// `motorSteps` is the seam described on `ProceduralMotorStep`: pass the
    /// turn's verified motor outcomes and they join the sequence in order.
    @discardableResult
    public func observeTurn(
        userMessage: String,
        toolEvidence: [String],
        motorSteps: [ProceduralMotorStep] = [],
        sessionId: String
    ) async -> ProceduralLaneOutcome {
        // 2026-09-12, User: a bridge turn is a full turn. A procedure she runs
        // for Claude or Codex is her procedure as much as one she runs for
        // User; the promoter dropped its own agent-seat skip the day before.
        // The whole-turn question, asked before the success-only slice is
        // read: did anything in this turn fail, stall, or get stitched out by
        // the projection's own head+tail bound? If so the remaining lines look
        // like a contiguous verified run and are not one. Count nothing.
        if ProceduralEvidenceShaper.carriesSequenceBreak(toolEvidence) { return .ignored }
        var steps = ProceduralEvidenceShaper.steps(from: toolEvidence)
        steps.append(contentsOf: motorSteps.filter(\.isVerified).map(\.stepShape))
        return await observe(steps: steps, day: ProceduralEvidenceShaper.dayKey(clock()))
    }

    /// Shape-level entry point: the counting, the floor, and the mint.
    @discardableResult
    public func observe(steps: [ProceduralStepShape], day: String) async -> ProceduralLaneOutcome {
        guard steps.count >= configuration.minimumSequenceLength,
              steps.count <= configuration.maximumSequenceLength else {
            return .ignored
        }
        // ONE dedupe key, shared by the ledger row, the durable proposed set,
        // and the card the mint files. See `sequenceIdentity(for:)`.
        let identity = ProceduralProcedureCompiler.sequenceIdentity(for: steps)
        let now = ISO8601DateFormatter().string(from: clock())

        // Count inside the lock and report back what the floor now says.
        struct Counted: Sendable {
            var entry: ProceduralLedgerEntry
            var alreadyProposed: Bool
        }
        let counted: Counted?
        do {
            counted = try await ledger.mutate(limit: configuration.maximumLedgerEntries) { entries in
                var entry = entries[identity] ?? ProceduralLedgerEntry(
                    sequenceIdentity: identity, steps: steps, occurrenceCount: 0,
                    days: [], lastSeenAt: now, proposedProcedureID: nil
                )
                let alreadyProposed = entry.proposedProcedureID != nil
                entry.occurrenceCount += 1
                if !entry.days.contains(day) { entry.days = (entry.days + [day]).sorted() }
                entry.lastSeenAt = now
                entry.steps = steps
                entries[identity] = entry
                return Counted(entry: entry, alreadyProposed: alreadyProposed)
            }
        } catch {
            return .ignored
        }
        guard let counted else { return .ignored }
        let entry = counted.entry

        // ≤ 1 proposal per n-gram: the fourth repeat is counted and stops here.
        if counted.alreadyProposed { return .blocked(.alreadyProposedForSequence) }
        guard entry.occurrenceCount >= configuration.minimumOccurrences,
              entry.days.count >= configuration.minimumDistinctDays else {
            return .counted(
                sequenceIdentity: identity,
                occurrences: entry.occurrenceCount,
                distinctDays: entry.days.count
            )
        }

        // The ledger's own `proposedProcedureID` above is evictable — 512 rows,
        // oldest-touched first — so it cannot be the only memory of "already
        // asked". This file is not evicted by counting pressure and outlives
        // the row by an order of magnitude.
        if await proposedSequences.contains(identity) {
            return .blocked(.alreadyProposedForSequence)
        }

        guard !mintingSequences.contains(identity) else {
            return .blocked(.alreadyProposedForSequence)
        }
        mintingSequences.insert(identity)
        defer { mintingSequences.remove(identity) }

        let procedure = ProceduralProcedureCompiler.compile(
            steps: entry.steps,
            occurrenceCount: entry.occurrenceCount,
            observedDays: entry.days,
            // The floor admits only verified successes, so every counted
            // occurrence is one. Recorded rather than assumed at read time.
            verifiedSuccessCount: entry.occurrenceCount
        )

        let pending: [ApprovalRecord]
        do {
            pending = try await inbox.list(filter: ApprovalFilter(
                status: "pending", action: ProceduralSkillProposal.approvalAction
            ))
        } catch {
            return .blocked(.stagingFailed)
        }
        // Dedupe by the SEQUENCE identity across EVERY card this lane has
        // filed, pending or resolved: a re-derived identical shape is the same
        // craft, and asking twice is noise. Keyed on the shape and not on
        // `procedure.id`, whose digest moves with every further repeat.
        if await ProceduralSkillProposal.isAlreadyFiled(
            sequenceIdentity: procedure.sequenceIdentity, inbox: inbox
        ) {
            await markProposed(identity: identity, procedureID: procedure.id)
            return .blocked(.duplicateProcedureDigest)
        }
        guard pending.count < configuration.pendingProposalCap else {
            return .blocked(.pendingCapReached)
        }

        do {
            let record = try await ProceduralSkillProposal.stage(
                procedure: procedure, inbox: inbox
            )
            await markProposed(identity: identity, procedureID: procedure.id)
            return .minted(
                approvalID: record.id,
                procedureID: procedure.id,
                sequenceIdentity: identity
            )
        } catch {
            return .blocked(.stagingFailed)
        }
    }

    /// Both memories of "already asked", written together: the ledger row (a
    /// receipt, evictable) and the durable identity set (the actual bound).
    private func markProposed(identity: String, procedureID: String) async {
        await proposedSequences.record(identity)
        _ = try? await ledger.mutate(limit: configuration.maximumLedgerEntries) { entries in
            entries[identity]?.proposedProcedureID = procedureID
        }
    }

    /// Read-only view for tests and receipts. Identities only.
    public func proposedSequenceIdentities() async -> [String] {
        await proposedSequences.load()
    }

    /// Read-only view for tests and receipts. Payload-free.
    public func ledgerEntries() async -> [ProceduralLedgerEntry] {
        await ledger.load().values.sorted { $0.sequenceIdentity < $1.sequenceIdentity }
    }
}
