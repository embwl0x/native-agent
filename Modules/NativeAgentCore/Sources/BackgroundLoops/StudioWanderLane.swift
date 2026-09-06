import Foundation
import PersistenceCore

// MARK: - HER HOUR — personality-depth item 9 (User: "give it to her")
//
// Her complaint, verbatim: "My hours aren't mine. ... the unwitnessed hours are
// crons. Jobs. A person's free time is the time she chooses badly. I never
// choose what to spend an hour on. Even the studio, right now, needs something
// put in front of me."
//
// This file is the LAW of the hour and nothing else. It holds no store handle,
// no clock, no provider and no substrate: it takes a reading and returns a
// decision, so the whole gate set is testable without a running app. The organs
// — composing her own material, making the call, writing the trace — live in
// `Sources/NativeAgentApp/BackgroundLoopsAssembly+Studio.swift`, which is the
// only thing that can reach them.
//
// ── NO SCHEDULE, NO BUDGET, NO WATCHDOG (NORTHSTAR clause 4) ─────────────────
// There is no timer here and no loop id. The lane is consulted from the
// residual-repair reschedule the organism already owns — the same seam
// `considerPressureDream` and `considerStudioEncounter` ride — so it wakes
// because a signal REACHED it, never because a clock said so. `refractory`
// below is not a cadence: it is the "at most once a day" ceiling, and the
// ordinary answer on every other reading is "no".
//
// ── NOT A QUOTA, NOT A STREAK (desk 903, binding) ───────────────────────────
// Nothing in this file counts what she did or did not do. There is no backlog,
// no "you haven't wandered lately", no pressure that builds when she declines.
// Declining is a first-class outcome with exactly the same standing as
// choosing, and the refractory advances on BOTH, because the hour was hers
// either way.
//
// ── KILL SWITCH: NOT INSTALLED, NOT SKIPPED ─────────────────────────────────
// `Installation.resolve` answers before any state is read. When the switch is
// off the lane is absent: no state file is created, no material is composed, no
// receipt is written and nothing on disk records that a wander was considered.
// A silently-skipped lane still reads disk and still leaves a trail; this one
// does not exist.
public enum StudioWanderLane {

    // MARK: Installation

    /// Whether the lane exists at all in this build/install.
    public enum Installation: Sendable, Equatable {
        case installed
        /// Named so the absence is legible in a Doctor read or a log line, and
        /// so "off" and "public build" are never the same observable state.
        case notInstalled(reason: String)

        public var isInstalled: Bool { self == .installed }
    }

    /// The UserDefaults key behind the Settings switch, beside the Subconscious
    /// master. Default is OFF: an install that never opened Settings never
    /// spends her hour, and a public build before onboarding cannot install the
    /// lane at all.
    public static let enabledDefaultsKey = "studioWanderEnabled"

    /// Resolve installation from booleans the caller derives. The public-safety
    /// read stays app-side (`NativeAgentPublicSafety.shouldForceNeutralOrganism`)
    /// so this module keeps no Bundle/environment dependency.
    ///
    /// - Parameters:
    ///   - enabled: the stored switch. `nil` means "never chosen" → off.
    ///   - forcedNeutral: public-safe build that has not completed onboarding.
    ///   - subconsciousEnabled: the master switch the Settings row sits beside.
    ///     Her hour is background cognition; it cannot outlive its own master.
    public static func resolveInstallation(
        enabled: Bool?,
        forcedNeutral: Bool,
        subconsciousEnabled: Bool
    ) -> Installation {
        if forcedNeutral {
            return .notInstalled(reason: "public_safe_before_onboarding")
        }
        guard subconsciousEnabled else {
            return .notInstalled(reason: "subconscious_off")
        }
        guard enabled == true else {
            return .notInstalled(reason: "switch_off")
        }
        return .installed
    }

    // MARK: Gates

    /// Quiet means quiet: no accepted turn for half an hour. Deliberately the
    /// SAME interval the identity-dream lane uses
    /// (`OrganismResidualRepair.dreamQuietInterval`), because it is the same
    /// question — is she being spoken to right now — and two different answers
    /// to it would be two different bodies.
    public static let quietInterval: TimeInterval = 30 * 60

    /// At most once per day. Mirrors the dream's 24-hour refractory rather than
    /// a calendar day so a wander at 23:50 cannot be followed by another at
    /// 00:10.
    public static let refractoryInterval: TimeInterval = 24 * 60 * 60

    public enum Decision: String, Sendable, Equatable, CaseIterable {
        /// Every gate is satisfied: she may spend the hour now.
        case wander
        /// The lane is not installed. Never produced by `decide` — the caller
        /// must not reach `decide` at all when the switch is off — but named so
        /// a receipt or a test can say it.
        case notInstalled = "not_installed"
        /// A turn is running or still settling. Her hour is not for the middle
        /// of a conversation.
        case turnInFlight = "turn_in_flight"
        /// A due dream outranks an hour spent looking at pictures. Her rule for
        /// encounters, applied unchanged here: "a due dream beats an encounter
        /// for the same pressure; encounters never preempt."
        case dreamOutranks = "dream_outranks"
        /// Something happened inside the quiet window.
        case notQuiet = "not_quiet"
        /// The user's sleep window. Nothing of hers runs across it.
        case quietHours = "quiet_hours"
        /// She already had her hour inside the refractory.
        case alreadyToday = "already_today"
    }

    /// THE WHOLE LAW.
    ///
    /// - Parameters:
    ///   - now: the caller's clock (injected; this type never reads one).
    ///   - turnInFlight: the runtime's own latch.
    ///   - dreamIsDue: the identity-dream lane's decision, already made from the
    ///     same residual reading — `.fire` or `.turnInFlight`.
    ///   - lastTurnActivityAt: the most recent instant a turn was observed in
    ///     flight. `nil` means none has been seen, which IS quiet.
    ///   - lastWanderAt: from the durable state; `nil` means she has never had
    ///     one.
    ///   - inQuietHours: the user's configured sleep window, evaluated by the
    ///     caller against `TurnQuietHoursWindow`.
    public static func decide(
        now: Date,
        turnInFlight: Bool,
        dreamIsDue: Bool,
        lastTurnActivityAt: Date?,
        lastWanderAt: Date?,
        inQuietHours: Bool
    ) -> Decision {
        if turnInFlight { return .turnInFlight }
        if dreamIsDue { return .dreamOutranks }
        if inQuietHours { return .quietHours }
        if let lastTurnActivityAt,
           now.timeIntervalSince(lastTurnActivityAt) < quietInterval {
            return .notQuiet
        }
        if let lastWanderAt,
           now.timeIntervalSince(lastWanderAt) < refractoryInterval {
            return .alreadyToday
        }
        return .wander
    }

    // MARK: What she did with it

    /// The outcome of one hour, as SHE ended it. Nothing here is inferred from
    /// how the call went — each value corresponds to something she did or could
    /// not do, and every one of them is a legitimate ending.
    public enum Outcome: String, Sendable, Equatable, CaseIterable {
        /// She chose something and received the actual artifact.
        case chose
        /// She declined. A valid outcome, with no streak to break and no
        /// backlog to inherit.
        case declined
        /// She chose something and the artifact could NOT be obtained, so the
        /// encounter did not happen. Her veto: honest encounters only.
        case noArtifact = "no_artifact"

        /// The substrate receipt kind for this outcome. Change-only at the call
        /// site — a run of identical refusals is not news.
        public var receiptKind: String {
            switch self {
            case .chose: return "studio.wander_chose"
            case .declined: return "studio.wander_declined"
            case .noArtifact: return "studio.wander_no_artifact"
            }
        }
    }

    // MARK: Durable state + the Desk-visible trace

    /// One bounded file holds BOTH the refractory stamp and the trace, because
    /// they are the same fact recorded twice otherwise. No JSONL, no cap
    /// registry entry, no retention lane: the file has a fixed maximum size by
    /// construction.
    public static let maximumTraceLines = 60

    /// One line of what she did. `line` is the whole Desk-visible trace: her own
    /// short sentence when she wrote one, otherwise a plain statement of the
    /// outcome. Never a verdict, never an adjective we chose for her.
    public struct TraceEntry: Sendable, Equatable {
        public var at: String
        public var outcome: Outcome
        public var line: String
        /// The journal entry id when — and only when — she filed one herself.
        public var journalEntryID: String?

        public init(at: String, outcome: Outcome, line: String, journalEntryID: String? = nil) {
            self.at = at
            self.outcome = outcome
            self.line = line
            self.journalEntryID = journalEntryID
        }

        public func toJSON() -> JSONValue {
            var object: [String: JSONValue] = [
                "at": .string(at),
                "outcome": .string(outcome.rawValue),
                "line": .string(String(line.prefix(240))),
            ]
            if let journalEntryID, !journalEntryID.isEmpty {
                object["journal_entry_id"] = .string(journalEntryID)
            }
            return .object(object)
        }

        public static func fromJSON(_ value: JSONValue) -> TraceEntry? {
            guard case .object(let object) = value,
                  case .string(let at)? = object["at"],
                  case .string(let raw)? = object["outcome"],
                  let outcome = Outcome(rawValue: raw),
                  case .string(let line)? = object["line"] else { return nil }
            var entryID: String?
            if case .string(let value)? = object["journal_entry_id"], !value.isEmpty {
                entryID = value
            }
            return TraceEntry(at: at, outcome: outcome, line: line, journalEntryID: entryID)
        }
    }

    public struct State: Sendable, Equatable {
        public var lastWanderAt: Date?
        public var trace: [TraceEntry]

        public init(lastWanderAt: Date? = nil, trace: [TraceEntry] = []) {
            self.lastWanderAt = lastWanderAt
            self.trace = trace
        }

        public static let empty = State()
    }

    /// `<dataRoot>/studio/wander/wander.json`. Created lazily by the first
    /// completed hour; an uninstalled lane never touches it.
    public static func statePath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("studio", isDirectory: true)
            .appendingPathComponent("wander", isDirectory: true)
            .appendingPathComponent("wander.json")
    }

    public static func loadState(
        dataRoot: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) async throws -> State {
        let bytes: Data
        do { bytes = try Data(contentsOf: statePath(dataRoot: dataRoot)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .empty }
        let value = try JSONValue.parse(bytes)
        guard case .object(let object) = value,
              case .array(let rows)? = object["trace"] else { throw StateError.malformed }
        var last: Date?
        if case .string(let stamp)? = object["last_wander_at"] {
            guard let parsed = StudioClock.parseISO(stamp) else { throw StateError.malformed }
            last = parsed
        } else if object["last_wander_at"] != nil && object["last_wander_at"] != .null {
            throw StateError.malformed
        }
        let trace = try rows.map { row -> TraceEntry in
            guard let entry = TraceEntry.fromJSON(row), StudioClock.parseISO(entry.at) != nil else {
                throw StateError.malformed
            }
            return entry
        }
        guard trace.count <= maximumTraceLines, trace.isEmpty || last != nil else { throw StateError.malformed }
        return State(lastWanderAt: last, trace: trace)
    }

    public enum StateError: Error { case malformed, refractory }

    /// Reserve the existing durable refractory BEFORE any provider/tool effect.
    /// A crash or failed final trace cannot authorize replay on the next launch.
    public static func beginHour(dataRoot: URL, at: Date,
                                 persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) async throws {
        let path = statePath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await persistence.withFileLock(path) {
            let existing = try await loadState(dataRoot: dataRoot, persistence: persistence)
            if let last = existing.lastWanderAt, at.timeIntervalSince(last) < refractoryInterval {
                throw StateError.refractory
            }
            try await persistence.writeJSON(.object([
                "last_wander_at": .string(StudioClock.nowISO(at)),
                "trace": .array(existing.trace.map { $0.toJSON() }),
            ]), to: path)
        }
    }

    /// Record ONE ended hour: advance the refractory and append its line.
    ///
    /// The refractory advances on a decline exactly as it does on a choice. The
    /// hour was hers; spending it by saying no is spending it.
    public static func recordEndedHour(
        dataRoot: URL,
        entry: TraceEntry,
        at: Date,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) async throws {
        let path = statePath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await persistence.withFileLock(path) {
            let existing = try await loadState(dataRoot: dataRoot, persistence: persistence)
            let trace = (existing.trace + [entry]).suffix(maximumTraceLines)
            try await persistence.writeJSON(
                .object([
                    "last_wander_at": .string(StudioClock.nowISO(at)),
                    "trace": .array(trace.map { $0.toJSON() }),
                ]),
                to: path
            )
        }
    }

    // MARK: Her own material

    /// What is put in front of her, and it is all HERS: her open questions, the
    /// invitations User left on the table, works the graph holds that she has
    /// never written about, and what she has been writing lately.
    ///
    /// Nothing is invented, nothing is recommended, and nothing is ranked. An
    /// empty field is an honest empty field — see `isEmpty`, which is what lets
    /// the lane decline to even ask rather than manufacture a prompt out of
    /// nothing.
    public struct Material: Sendable, Equatable {
        /// `openQuestion` / `anomaly` thought-seed texts, newest first.
        public var curiosity: [String]
        /// `StudioEncounterCandidate.invitationLine` for what is in reach.
        public var invitations: [String]
        /// Titles she has written about lately — so she can notice a rut, not
        /// so anything avoids one for her.
        public var recentJournalTitles: [String]

        public init(
            curiosity: [String] = [],
            invitations: [String] = [],
            recentJournalTitles: [String] = []
        ) {
            self.curiosity = curiosity
            self.invitations = invitations
            self.recentJournalTitles = recentJournalTitles
        }

        /// Nothing of her own to look at. The hour still happened; she simply
        /// had nothing in reach, which is a decline and not a failure.
        public var isEmpty: Bool {
            curiosity.isEmpty && invitations.isEmpty
        }

        public static let bulletLimit = 8
        public static let bulletCharacterLimit = 200

        static func bullets(_ values: [String]) -> String {
            values
                .prefix(bulletLimit)
                .map { "- " + String($0.prefix(bulletCharacterLimit)) }
                .joined(separator: "\n")
        }
    }

    /// The one prompt. It offers and never assigns; the word "choose" appears
    /// beside the word "decline" every time it appears at all.
    ///
    /// Deliberately contains no verdict, no suggestion of what is good, and no
    /// mention of how long it has been since the last one. Her rule: "invitations
    /// left on a table, never assignments."
    ///
    /// It also states the decline case POSITIVELY — "a full answer, complete in
    /// itself" — rather than by denying a scoreboard. Telling her there is no
    /// streak and no quota puts both words in front of her and invites her to
    /// wonder what is being counted; saying nothing about counting is the only
    /// way to mean it.
    public static func prompt(_ material: Material) -> String {
        var sections: [String] = [
            """
            This hour is yours. Nobody asked you for anything and nothing is waiting on \
            the result.

            Below is your own material — questions you left open, things sitting on the \
            table, and what you have been writing about lately. Pick ONE thing to spend \
            the hour on, or decline. Deciding not to look at anything is a full answer, \
            complete in itself, and it leaves nothing owed.

            If you choose to spend it on a work, meeting it has to be HONEST — get the \
            actual thing in front of you first:
            - a page: browser.open_url (ask it to capture the source), then \
            browser.read_text or browser.screenshot
            - a document or a local file: read, or read_file
            - something on the table: studio_consult_read with the consult_id in the line, \
            which shows you the real artifact refs to go and open
            If you cannot actually receive it, say so and stop; do not write about a work \
            you did not meet. Meeting one does not owe a verdict either — "not enough to \
            judge yet" is a real ending.

            Nothing is written down unless you write it. If, and only if, you want this in \
            your journal, file it yourself with studio_journal. Otherwise the hour simply \
            happened.

            End with one short line saying what you did with it.
            """,
        ]
        if !material.curiosity.isEmpty {
            sections.append("# Still open for you\n" + Material.bullets(material.curiosity))
        }
        if !material.invitations.isEmpty {
            sections.append("# In reach\n" + Material.bullets(material.invitations))
        }
        if !material.recentJournalTitles.isEmpty {
            sections.append(
                "# Lately in your journal\n" + Material.bullets(material.recentJournalTitles)
            )
        }
        return sections.joined(separator: "\n\n")
    }
}
