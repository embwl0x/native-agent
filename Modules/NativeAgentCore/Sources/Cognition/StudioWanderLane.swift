import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Studio
// Blueprint: | `StudioWanderLane.swift` | `StudioWanderLane`. |

/// Resolve installation before state reads so disabled hours leave no receipt; a decline still spends an admitted hour.
public enum StudioWanderLane {

    // MARK: Installation

    public enum Installation: Sendable, Equatable {
        case installed
        /// Distinguish disabled preference from public-build restriction in diagnostics.
        case notInstalled(reason: String)

        public var isInstalled: Bool { self == .installed }
    }

    /// Public pre-onboarding builds cannot install this work.
    public static let enabledDefaultsKey = "studioWanderEnabled"

    /// A new agent has the hour from day one; the person can turn it off.
    public static let enabledByDefault = true

    /// Resolve from caller-supplied choices so this module owns no Bundle/environment dependency.
    /// Absent hour choice takes `enabledByDefault`; the Subconscious master also bounds installation.
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
        guard enabled ?? enabledByDefault else {
            return .notInstalled(reason: "switch_off")
        }
        return .installed
    }

    // MARK: Gates

    /// Share the identity-dream half-hour quiet interval so both owners agree whether a conversation is active.
    public static let quietInterval: TimeInterval = 30 * 60

    /// Use a rolling 24-hour refractory so midnight cannot admit adjacent hours.
    /// Explicit mind.wander satisfies only this scheduling wait.
    public static let refractoryInterval: TimeInterval = 24 * 60 * 60

    /// Project admission's quiet/refractory boundaries on the existing deadline; live turns release through idle edges.
    public static func nextEligibility(now: Date, lastTurnActivityAt: Date?, lastWanderAt: Date?) -> Date? {
        [lastTurnActivityAt?.addingTimeInterval(quietInterval),
         lastWanderAt?.addingTimeInterval(refractoryInterval)]
            .compactMap { $0 }.filter { $0 > now }.max()
    }

    public enum Decision: String, Sendable, Equatable, CaseIterable {
        case wander
        /// Resolve installation before decide so disabled work cannot enter admission.
        case notInstalled = "not_installed"
        /// Do not run an unattended hour during an active or settling turn.
        case turnInFlight = "turn_in_flight"
        case notQuiet = "not_quiet"
        case alreadyToday = "already_today"
    }

    /// Use the caller's clock and canonical turn activity; absent activity is quiet and absent durable wander time is unspent.
    /// Person-facing quiet hours belong to delivery routing and cannot block the agent's own work.
    public static func decide(
        now: Date,
        turnInFlight: Bool,
        lastTurnActivityAt: Date?,
        lastWanderAt: Date?,
        satisfyWait: Bool = false
    ) -> Decision {
        if turnInFlight { return .turnInFlight }
        if !satisfyWait, let lastTurnActivityAt,
           now.timeIntervalSince(lastTurnActivityAt) < quietInterval {
            return .notQuiet
        }
        if !satisfyWait, let lastWanderAt,
           now.timeIntervalSince(lastWanderAt) < refractoryInterval {
            return .alreadyToday
        }
        return .wander
    }

    // MARK: What the agent did with it

    /// Every admitted hour has a terminal outcome, including interruption.
    public enum Outcome: String, Sendable, Equatable, CaseIterable {
        case chose
        /// Declining is complete without streaks or inherited backlog.
        case declined
        /// Without the actual artifact, an attempted encounter is no_artifact.
        case noArtifact = "no_artifact"
        case stopped
        case failed

        /// A failed or stopped hour was not had, so the day's hour stays the agent's.
        public var spendsTheDay: Bool { self != .failed && self != .stopped }

        /// Record each admitted hour even if its terminal outcome repeats.
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

    /// Store refractory and trace together because they describe one fact; fixed capacity bounds the file without another retention owner.
    public static let maximumTraceLines = 60

    /// Keep the agent's own closing line when present, otherwise describe the outcome without an invented verdict.
    public struct TraceEntry: Sendable, Equatable {
        public var at: String
        public var outcome: Outcome
        public var line: String
        /// Record a journal ID only for an entry the agent filed.
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

    /// Create durable state lazily; an uninstalled hour never touches it.
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
        guard trace.count <= maximumTraceLines, last != nil || !trace.contains(where: \.outcome.spendsTheDay) else { throw StateError.malformed }
        return State(lastWanderAt: spentAt(reserved: last, trace: trace), trace: trace)
    }

    public enum StateError: Error { case malformed, refractory }

    /// Reserve refractory before provider/tool effects so crashes cannot authorize replay; explicit run-now bypasses no state check.
    public static func beginHour(dataRoot: URL, at: Date, satisfyWait: Bool = false) async throws {
        let path = statePath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let existing = try await loadState(dataRoot: dataRoot)
            if !satisfyWait, let last = existing.lastWanderAt, at.timeIntervalSince(last) < refractoryInterval {
                throw StateError.refractory
            }
            try await SwiftNativePersistenceCore.writeJSON(.object([
                "last_wander_at": .string(NativeTimestampFormat.sixDigitUTCOffset(at)),
                "trace": .array(existing.trace.map { $0.toJSON() }),
            ]), to: path)
        }
    }

    /// The day's hour is spent by the newest hour that was had. An admission newer than every ended hour is still in flight, or crashed with
    /// unknown effects, so it holds; one whose ending did not spend the day gives the day back.
    static func spentAt(reserved: Date?, trace: [TraceEntry]) -> Date? {
        let had = trace.filter(\.outcome.spendsTheDay).compactMap { NativeTimestampFormat.parseISO8601FractionalFirst($0.at) }.max()
        guard let reserved, let newest = trace.last, let ended = NativeTimestampFormat.parseISO8601FractionalFirst(newest.at),
              ended >= reserved, !newest.outcome.spendsTheDay else { return reserved ?? had }
        return had
    }

    /// A decline consumes refractory just like a choice because the admitted hour was spent; a failed or stopped hour does not.
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
            let trace = Array((existing.trace + [entry]).suffix(maximumTraceLines))
            try await SwiftNativePersistenceCore.writeJSON(
                .object([
                    "last_wander_at": spentAt(reserved: at, trace: trace).map { .string(NativeTimestampFormat.sixDigitUTCOffset($0)) } ?? .null,
                    "trace": .array(trace.map { $0.toJSON() }),
                ]),
                to: path
            )
        }
    }

    // MARK: The agent's own material

    /// Offer only real material without assignment or ranking; empty material still permits exploration or decline.
    public struct Material: Sendable, Equatable {
        public var invitations: [String]
        /// Recent titles let the agent notice repetition without imposing an automatic avoidance rule.
        public var recentJournalTitles: [String]
        /// Offer pressing cares with explicit keys so the agent can choose which question continues, without assignment.
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

        /// No material still leaves the hour's judgment to the agent.
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

    /// Offer choice and decline equally without verdicts, quotas or absence pressure.
    /// Frame decline positively as complete; mentioning a nonexistent scoreboard would itself introduce one.
    public static func prompt(_ material: Material) throws -> String {
        var sections: [String] = [
            try completionPolicy("wander-hour", section: "prompt"),
        ]
        sections[0] += try completionPolicy("wander-hour", section: "question")
        if material.isEmpty {
            sections.append(try completionPolicy("wander-hour", section: "empty"))
        }
        if !material.cares.isEmpty {
            sections.append(try completionPolicy("wander-hour", section: "cares") + Material.bullets(material.cares))
        }
        if !material.invitations.isEmpty {
            sections.append(try completionPolicy("wander-hour", section: "invitations") + Material.bullets(material.invitations))
        }
        if !material.recentJournalTitles.isEmpty {
            sections.append(
                try completionPolicy("wander-hour", section: "journal") + Material.bullets(material.recentJournalTitles)
            )
        }
        return sections.joined(separator: "\n\n")
    }
}
