import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Studio
// Blueprint: | `StudioWanderLane.swift` | `StudioWanderLane` enum; installation, eligibility, carried-hour state and prompt for studio wandering |

/// The hour's installation, refractory law and durable trace share cognition's
/// runtime owner. Installation is resolved before reading state; an absent
/// lane must leave no receipt. Declining spends the hour just as choosing does.
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
        /// Something happened inside the quiet window.
        case notQuiet = "not_quiet"
        /// She already had her hour inside the refractory.
        case alreadyToday = "already_today"
    }

    /// THE WHOLE LAW.
    ///
    /// - Parameters:
    ///   - now: the caller's clock (injected; this type never reads one).
    ///   - turnInFlight: the runtime's own latch.
    ///   - lastTurnActivityAt: the most recent instant a turn was observed in
    ///     flight. `nil` means none has been seen, which IS quiet.
    ///   - lastWanderAt: from the durable state; `nil` means she has never had
    ///     one.
    /// The person's quiet hours are not here: they hold what reaches him
    /// (AttentionRouter), never her own work (User 10-12).
    public static func decide(
        now: Date,
        turnInFlight: Bool,
        lastTurnActivityAt: Date?,
        lastWanderAt: Date?
    ) -> Decision {
        if turnInFlight { return .turnInFlight }
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

    /// The terminal outcome of one admitted hour, including interrupted work.
    public enum Outcome: String, Sendable, Equatable, CaseIterable {
        /// She chose something and received the actual artifact.
        case chose
        /// She declined. A valid outcome, with no streak to break and no
        /// backlog to inherit.
        case declined
        /// She chose something and the artifact could NOT be obtained, so the
        /// encounter did not happen. Her veto: honest encounters only.
        case noArtifact = "no_artifact"
        case stopped
        case failed

        /// Each admitted hour records one terminal receipt, even when it ends
        /// the same way as an earlier hour.
        public var receiptKind: String {
            switch self {
            case .chose: return "studio.wander_chose"
            case .declined: return "studio.wander_declined"
            case .noArtifact: return "studio.wander_no_artifact"
            case .stopped: return "studio.wander_stopped"
            case .failed: return "studio.wander_failed"
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
        dataRoot: URL
    ) async throws -> State {
        let bytes: Data
        do { bytes = try Data(contentsOf: statePath(dataRoot: dataRoot)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .empty }
        let value = try JSONValue.parse(bytes)
        guard case .object(let object) = value,
              case .array(let rows)? = object["trace"] else { throw StateError.malformed }
        var last: Date?
        if case .string(let stamp)? = object["last_wander_at"] {
            guard let parsed = NativeTimestampFormat.parseISO8601FractionalFirst(stamp) else { throw StateError.malformed }
            last = parsed
        } else if object["last_wander_at"] != nil && object["last_wander_at"] != .null {
            throw StateError.malformed
        }
        let trace = try rows.map { row -> TraceEntry in
            guard let entry = TraceEntry.fromJSON(row), NativeTimestampFormat.parseISO8601FractionalFirst(entry.at) != nil else {
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
    public static func beginHour(dataRoot: URL, at: Date) async throws {
        let path = statePath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let existing = try await loadState(dataRoot: dataRoot)
            if let last = existing.lastWanderAt, at.timeIntervalSince(last) < refractoryInterval {
                throw StateError.refractory
            }
            try await SwiftNativePersistenceCore.writeJSON(.object([
                "last_wander_at": .string(NativeTimestampFormat.sixDigitUTCOffset(at)),
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
        at: Date
    ) async throws {
        let path = statePath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let existing = try await loadState(dataRoot: dataRoot)
            let trace = (existing.trace + [entry]).suffix(maximumTraceLines)
            try await SwiftNativePersistenceCore.writeJSON(
                .object([
                    "last_wander_at": .string(NativeTimestampFormat.sixDigitUTCOffset(at)),
                    "trace": .array(trace.map { $0.toJSON() }),
                ]),
                to: path
            )
        }
    }

    // MARK: Her own material

    /// Her cares, invitations and recent writing; nothing is invented,
    /// recommended or ranked. Empty material still lets her explore,
    /// return a question or decline.
    public struct Material: Sendable, Equatable {
        /// The studio-intake part's invitation for what is in reach.
        public var invitations: [String]
        /// Titles she has written about lately — so she can notice a rut, not
        /// so anything avoids one for her.
        public var recentJournalTitles: [String]
        /// Her own open cares, most pressing first.
        /// ("[w1] topic — her question"; the key lets her say which one a
        /// question carries on). Offered ahead of everything else, never assigned.
        public var cares: [String]

        public init(
            invitations: [String] = [],
            recentJournalTitles: [String] = [],
            cares: [String] = []
        ) {
            self.invitations = invitations
            self.recentJournalTitles = recentJournalTitles
            self.cares = cares
        }

        /// No invitations or open cares; the hour still reaches her for judgment.
        public var isEmpty: Bool {
            invitations.isEmpty && cares.isEmpty
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
    public static func prompt(_ material: Material) throws -> String {
        var sections: [String] = [
            try completionPolicy("her-hour", section: "prompt"),
        ]
        sections[0] += try completionPolicy("her-hour", section: "question")
        if material.isEmpty {
            sections.append(try completionPolicy("her-hour", section: "empty"))
        }
        if !material.cares.isEmpty {
            sections.append(try completionPolicy("her-hour", section: "cares") + Material.bullets(material.cares))
        }
        if !material.invitations.isEmpty {
            sections.append(try completionPolicy("her-hour", section: "invitations") + Material.bullets(material.invitations))
        }
        if !material.recentJournalTitles.isEmpty {
            sections.append(
                try completionPolicy("her-hour", section: "journal") + Material.bullets(material.recentJournalTitles)
            )
        }
        return sections.joined(separator: "\n\n")
    }
}
