import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `SessionIdentity.swift` | Session identity ledger, mint-site traces and source-flapping diagnostics |

// MARK: - SessionIdentityTrace

/// Session identity emits through bounded, drop-on-backpressure `TurnTraceBus.fire`
/// without awaiting observers or persistence.
/// Resolutions outside a bound turn still emit, stamped with `unboundTurnId`.
public enum SessionIdentityTrace {
    /// Turn-trace `kind` for the row. Dotted, matching the other emitters
    /// (`tool.dispatch`, `assembly.stage`, `surface.firstRender`).
    public static let kind = "session.identity"
    /// Payload schema tag; bumped only on a breaking payload change.
    public static let schema = "session.identity.v1"
    /// Envelope turnId used when resolution happens outside a bound turn.
    public static let unboundTurnId = "unbound"

    /// Which minting site produced this identity.
    public enum MintSite: String, Sendable, Equatable, CaseIterable {
        /// `TelegramSessionStore.activeSessionId` / `startNewSession`.
        case telegramSessionStore = "telegram_session_store"
    }

    /// HOW the identity was arrived at. Distinguishing `minted` from every
    /// other value is what makes the Doctor row's "minted in the last 24h"
    /// count honest.
    public enum Resolution: String, Sendable, Equatable, CaseIterable {
        /// Caller supplied the id (iOS client, bridge `sessionId` field).
        case requested
        /// Read out of the surface's own durable map
        /// (`telegram/session_map.json`, `slack/session_map.json`).
        case mapped
        /// A NEW session id was created.
        case minted
        /// A concurrent first message minted first; this turn adopted its id
        /// under the same lock.
        case adopted
    }

    /// Build the row. Exposed separately from `emit` so tests can assert the
    /// schema without driving the bus.
    public static func event(
        threadKey: String?,
        sessionId: String,
        surface: String,
        mintSite: MintSite,
        resolvedBy: Resolution,
        turnId: String? = nil,
        ts: Date = Date()
    ) -> TurnTraceEvent {
        var payload: [String: JSONValue] = [
            "schema": .string(schema),
            "sessionId": .string(sessionId),
            "surface": .string(surface),
            "mintSite": .string(mintSite.rawValue),
            "resolvedBy": .string(resolvedBy.rawValue),
        ]
        // A null threadKey records a site with no thread key; an absent field is missing evidence.
        payload["threadKey"] = threadKey.map(JSONValue.string) ?? .null
        return TurnTraceEvent(
            turnId: turnId ?? TurnTraceContext.turnId ?? unboundTurnId,
            ts: ts,
            kind: kind,
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload)
        )
    }

    /// Fire-and-forget emission. Never throws, never awaits, never blocks the
    /// caller's resolution.
    public static func emit(
        threadKey: String?,
        sessionId: String,
        surface: String,
        mintSite: MintSite,
        resolvedBy: Resolution,
        on bus: TurnTraceBus? = nil
    ) {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        TurnTraceBus.fire(
            event(
                threadKey: threadKey,
                sessionId: trimmed,
                surface: surface,
                mintSite: mintSite,
                resolvedBy: resolvedBy
            ),
            on: bus ?? TurnTraceContext.bus ?? .shared
        )
    }
}

// MARK: - SessionIdentityLedger (read side)

/// Read-only mint counts and source-flapping diagnostics take no lock and share the writer's payload contract.
/// Diagnostic reads never throw; decoded evidence is counted and unreadable coverage stays explicit.
public enum SessionIdentityLedger {
    public struct MintTally: Sendable, Equatable {
        /// Mint-site raw value → number of `resolvedBy == minted` rows.
        public let mintedByMintSite: [String: Int]
        /// Every `session.identity` row seen in the window, minted or not.
        public let totalRows: Int
        /// Days of the per-day trace feed actually present on disk.
        public let daysRead: Int
        /// Existing day files whose contents could not be read completely.
        public let unreadablePaths: [String]

        public var totalMinted: Int { mintedByMintSite.values.reduce(0, +) }

        public init(mintedByMintSite: [String: Int], totalRows: Int, daysRead: Int, unreadablePaths: [String] = []) {
            self.mintedByMintSite = mintedByMintSite
            self.totalRows = totalRows
            self.daysRead = daysRead
            self.unreadablePaths = unreadablePaths
        }
    }

    /// Count `session.identity` rows in `<dataRoot>/turn_traces/<day>.jsonl`
    /// within `now - window ... now`. Reads each local calendar day intersecting
    /// the window once, including a third day when a 24h window spans a short
    /// DST day. It does not scan the feed directory.
    public static func mintTally(
        dataRoot: URL,
        now: Date = Date(),
        window: TimeInterval = 24 * 60 * 60
    ) -> MintTally {
        let calendar = TurnTracePersistLane.dayCalendar

        let cutoff = now.addingTimeInterval(-window)
        var minted: [String: Int] = [:]
        var total = 0
        var daysRead = 0
        var unreadablePaths: [String] = []

        var day = calendar.startOfDay(for: cutoff)
        let lastDay = calendar.startOfDay(for: now)
        while day <= lastDay {
            let path = TurnTracePersistLane.fileURL(for: day, root: dataRoot)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
            let data: Data
            do {
                data = try Data(contentsOf: path)
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                unreadablePaths.append(path.path)
                continue
            }
            daysRead += 1
            let read = TurnTraceReplayReader.parse(data)
            if !read.report.isClean { unreadablePaths.append(path.path) }
            // Count decoded evidence, including unbound resolutions; damage limits coverage.
            for event in read.events where event.kind == SessionIdentityTrace.kind
                && event.ts >= cutoff && event.ts <= now {
                guard case .object(let payload) = event.payload else { continue }
                total += 1
                guard case .string(let resolvedBy)? = payload["resolvedBy"],
                      resolvedBy == SessionIdentityTrace.Resolution.minted.rawValue,
                      case .string(let site)? = payload["mintSite"]
                else { continue }
                minted[site, default: 0] += 1
            }
        }
        return MintTally(mintedByMintSite: minted, totalRows: total, daysRead: daysRead, unreadablePaths: unreadablePaths)
    }

    public struct FlappingReport: Sendable, Equatable {
        /// Whether the index decodes as ChatSession rows with nonempty IDs.
        public let indexReadable: Bool
        /// Live (non-archived) rows in `chat/sessions.json`.
        public let hotSessionCount: Int
        /// Sessions whose index source disagrees with their creation row.
        public let disagreeingSessionIds: [String]
        /// Sessions whose transcript carries MORE THAN ONE distinct `source`.
        /// Informational: a conversation can legitimately be picked up on
        /// another surface.
        public let mixedSourceSessionCount: Int
        /// Sessions continued mostly on another surface; informational, never a warning.
        public let continuedElsewhereSessionCount: Int
        /// Sessions skipped because their transcript was missing, unreadable,
        /// empty, or over the byte budget. Reported so a "0 disagreements"
        /// reading can never be mistaken for "0 disagreements measured".
        public let unreadableSessionCount: Int
        /// Sessions without a retained creation row are unmeasured, never evidence of a defect.
        public let creationUnmeasuredSessionCount: Int

        public var disagreeingSessionCount: Int { disagreeingSessionIds.count }

        public init(
            hotSessionCount: Int,
            disagreeingSessionIds: [String],
            mixedSourceSessionCount: Int,
            unreadableSessionCount: Int,
            continuedElsewhereSessionCount: Int = 0,
            creationUnmeasuredSessionCount: Int = 0,
            indexReadable: Bool = true
        ) {
            self.indexReadable = indexReadable
            self.hotSessionCount = hotSessionCount
            self.disagreeingSessionIds = disagreeingSessionIds
            self.mixedSourceSessionCount = mixedSourceSessionCount
            self.unreadableSessionCount = unreadableSessionCount
            self.continuedElsewhereSessionCount = continuedElsewhereSessionCount
            self.creationUnmeasuredSessionCount = creationUnmeasuredSessionCount
        }
    }

    /// Per-transcript byte budget. A transcript above this is counted as
    /// unreadable rather than scanned — a health check may not turn into an
    /// unbounded read of the hot chat tier.
    static let maximumTranscriptBytes = 16 * 1024 * 1024
    /// Whole-pass byte budget across all transcripts.
    static let maximumTotalScanBytes = 128 * 1024 * 1024

    /// Compare index and creation sources; mixed-source and continued-elsewhere transcripts are informational.
    public static func flappingReport(dataRoot: URL) -> FlappingReport {
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: sessionsPath),
              let rows = try? JSONDecoder().decode([ChatSession].self, from: data) else {
            return FlappingReport(
                hotSessionCount: 0,
                disagreeingSessionIds: [],
                mixedSourceSessionCount: 0,
                unreadableSessionCount: 0,
                indexReadable: false
            )
        }

        var hot = 0
        var disagreeing: [String] = []
        var mixed = 0
        var continuedElsewhere = 0
        var unreadable = 0
        var scanned = 0
        var creationUnmeasured = 0
        var indexReadable = true

        for row in rows {
            let id = row.id
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                indexReadable = false
                continue
            }
            if row.archived == true { continue }
            hot += 1
            let indexSource = row.source.map(ChatThreadKind.normalizedSource) ?? ""
            // DURABLE CREATION PROVENANCE. The index row carries the session's
            // own creation instant; a transcript whose oldest surviving surface
            // row postdates it has had its creation row compacted away.
            let indexCreatedAt = TurnTraceEvent.parseISO8601(row.createdAt.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let safeId = NativeAgentChatSessionID.normalizedPathComponent(id) else {
                unreadable += 1
                continue
            }
            let transcript = dataRoot
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("\(safeId).jsonl")
            let size = (try? FileManager.default.attributesOfItem(atPath: transcript.path))
                .flatMap { ($0[FileAttributeKey.size] as? NSNumber)?.intValue }
            // A session the index says has no messages has no transcript to
            // judge: a fresh chat, or a pinned empty one retention leaves hot,
            // is EMPTY, not unread. Only a confirmed absence or a measured
            // zero qualifies; a file whose metadata cannot be read stays
            // unread. Unread is a transcript the index says has content
            // that cannot be scanned.
            let absent = !FileManager.default.fileExists(atPath: transcript.path)
            if absent || size == 0, (row.messageCount ?? 0) <= 0 { continue }
            guard scanned < maximumTotalScanBytes,
                  let size,
                  size > 0,
                  size <= maximumTranscriptBytes,
                  let raw = try? String(contentsOf: transcript, encoding: .utf8) else {
                unreadable += 1
                continue
            }
            scanned += raw.utf8.count

            var tally: [String: Int] = [:]
            var creationSource: String?
            var creationRowAt: Date?
            var compacted = false
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let value = try? JSONValue.parse(lineData),
                      case .object(let record) = value,
                      case .string(let source)? = record["source"] else { continue }
                // A compaction row is proof the early transcript is GONE.
                if ChatThreadKind.normalizedSource(source) == "native_autocompaction" {
                    compacted = true
                }
                // Only surface-authored rows establish session source; system rows do not.
                if case .string(let role)? = record["role"],
                   role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system" {
                    continue
                }
                let normalized = ChatThreadKind.normalizedSource(source)
                // The CREATION row is the first row a surface authored, for the
                // same reason ChatSessionIndexReconciler takes it: it is what
                // the index `source` was stamped from.
                if creationSource == nil {
                    creationSource = normalized
                    if case .string(let stamp)? = record["createdAt"] {
                        creationRowAt = TurnTraceEvent.parseISO8601(stamp.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                tally[normalized, default: 0] += 1
            }
            guard let majority = tally.max(by: { lhs, rhs in
                // Deterministic: highest count, ties broken by name so the
                // report does not depend on dictionary ordering.
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            })?.key, let creationSource else {
                unreadable += 1
                continue
            }
            if tally.count > 1 { mixed += 1 }
            // Is the first surviving surface row actually the CREATION row?
            // Two independent witnesses say no: a compaction row anywhere in
            // the file, or a first row that postdates the index's own creation
            // instant by more than the write skew between the two files. When
            // either says so, this session's creation source is UNMEASURED and
            // nothing below is judged from it.
            let firstRowPostdatesCreation: Bool = {
                guard let indexCreatedAt, let creationRowAt else { return false }
                return creationRowAt.timeIntervalSince(indexCreatedAt) > creationRowSkewSeconds
            }()
            if compacted || firstRowPostdatesCreation {
                creationUnmeasured += 1
                continue
            }
            // Continuation elsewhere is valid; only index/creation source disagreement is a defect.
            if majority != creationSource { continuedElsewhere += 1 }
            if !indexSource.isEmpty, indexSource != creationSource {
                disagreeing.append(id)
            }
        }

        return FlappingReport(
            hotSessionCount: hot,
            disagreeingSessionIds: disagreeing,
            mixedSourceSessionCount: mixed,
            unreadableSessionCount: unreadable,
            continuedElsewhereSessionCount: continuedElsewhere,
            creationUnmeasuredSessionCount: creationUnmeasured,
            indexReadable: indexReadable
        )
    }

    /// How far a transcript's first retained row may postdate the index's own
    /// `createdAt` before it stops being credible as the creation row. The two
    /// files are written by different writers moments apart, so a few seconds
    /// of skew is normal; days are not.
    static let creationRowSkewSeconds: TimeInterval = 120

}
