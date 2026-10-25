import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `SessionIdentity.swift` | `ChatThreadKind` and session identity ledger: creation-time conversation kind, mint-site traces and source-flapping diagnostics |

// MARK: - ChatThreadKind

/// What KIND of conversation a chat session row is — recorded on the session
/// index row so downstream readers stop having to infer it from `source`.
///
/// This is the field that replaces the last-writer-wins `source` overwrite
/// (plan §1.3). `source` said "whichever surface appended most recently",
/// which is not a property of the conversation at all; `threadKind` says what
/// the conversation IS, and is written once at creation.
///
/// Per User's 2026-09-01 decisions the target is NOT one absorbing thread: the
/// active Telegram session is the ANCHOR that Mac and iPhone pin, `/new` stays
/// a real new session, and every surface keeps full multi-session. So `anchor`
/// is a role a session HOLDS for a while (see `ChatAnchorPin`), not a kind it
/// is born with — which is why there is no `resident` case here.
///
/// `legacy` is the honest label for a row minted without a thread
/// classification. Rows keep it until something classifies them.
public enum ChatThreadKind: String, Sendable, Equatable, CaseIterable, Codable {
    /// A private conversation between User and her, on any surface.
    case direct
    /// A Slack channel or Slack-threaded reply — other humans are present.
    case channel
    /// A builder wake. Work, not conversation.
    case builder
    /// An unrouted bridge probe. Diagnostic traffic.
    case ephemeral
    /// Minted with no classification behind it.
    case legacy

    public static func parse(_ raw: String?) -> ChatThreadKind? {
        guard let raw else { return nil }
        return ChatThreadKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The kind implied by a session row's `source`, used when a row is
    /// created. Deliberately conservative: it classifies only what the source
    /// actually proves. Telegram/iOS/Mac chat are all direct conversation with
    /// User; Slack is a channel; anything else is unclassified.
    public static func inferred(fromSource source: String) -> ChatThreadKind {
        switch SessionIdentityLedger.normalizedSource(source) {
        case "telegram", "ios", "app": return .direct
        case "slack": return .channel
        default: return .legacy
        }
    }
}

// MARK: - SessionIdentityTrace

/// The Phase-0 `session.identity` turn-trace row.
///
/// Emission is fire-and-forget through the existing `TurnTraceEvent.fire`
/// path (bounded, drop-on-backpressure, detached persist lane), so the U5
/// lesson holds: a slow observer never slows the turn.
///
/// UNLIKE `fireFromContext`, this emits even when no turnId is bound. Session
/// resolution happens in the TRANSPORT, strictly before the turn engine binds
/// `TurnTraceContext.turnId` — guarding on a bound turn would silence these
/// resolutions. Unbound resolutions are stamped
/// with `unboundTurnId` so a reader can tell "no turn was in flight" from
/// "this belongs to turn X".
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
        // threadKey is nullable rather than absent: a reader must be able to
        // tell "this site has no thread concept yet" from "the field was
        // dropped", or the Phase-3 rollout can't be judged from the feed.
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

/// Reader for the Phase-0 feed and the §1.3 flapping detector. Pure reads —
/// it takes no lock, mutates nothing, and degrades to zeros rather than
/// throwing, because its only consumers are diagnostics.
///
/// Kept next to the writer so the payload key names have exactly one
/// definition; a second copy is the thing that drifts.
public enum SessionIdentityLedger {
    public struct MintTally: Sendable, Equatable {
        /// Mint-site raw value → number of `resolvedBy == minted` rows.
        public let mintedByMintSite: [String: Int]
        /// Every `session.identity` row seen in the window, minted or not.
        public let totalRows: Int
        /// Days of the per-day trace feed actually present on disk.
        public let daysRead: Int
        /// Existing day files whose contents could not be read.
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TurnTracePersistLane.dayTimeZone

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
            let raw: String
            do {
                raw = try String(contentsOf: path, encoding: .utf8)
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                unreadablePaths.append(path.path)
                continue
            }
            daysRead += 1
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                // Cheap prefilter: the kind appears verbatim in the row, and
                // the feed holds 20k rows/day of which this schema is a
                // handful. Parsing every line to find them is wasteful.
                guard line.contains(SessionIdentityTrace.kind) else { continue }
                guard let data = String(line).data(using: .utf8),
                      let value = try? JSONValue.parse(data),
                      case .object(let row) = value,
                      case .string(let rowKind)? = row["kind"],
                      rowKind == SessionIdentityTrace.kind,
                      case .string(let ts)? = row["ts"],
                      let stamp = TurnTraceEvent.parseISO8601(ts),
                      stamp >= cutoff,
                      stamp <= now,
                      case .object(let payload)? = row["payload"]
                else { continue }
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
        /// Sessions whose index-row `source` disagrees with the source of their
        /// own CREATION row.
        ///
        /// 2026-09-06: this used to compare the index against the majority of
        /// the transcript, which made every legitimate cross-surface
        /// continuation a warning — a Mac chat mostly answered from the phone
        /// disagreed by construction. The index `source` says what the
        /// conversation IS, stamped once at creation, so the only thing it can
        /// disagree WITH is the creation row.
        public let disagreeingSessionIds: [String]
        /// Sessions whose transcript carries MORE THAN ONE distinct `source`.
        /// Informational: a conversation can legitimately be picked up on
        /// another surface.
        public let mixedSourceSessionCount: Int
        /// Sessions whose creation surface is not where most of the
        /// conversation happened — "started on the Mac, continued mostly on the
        /// iPhone". Informational, never a warning. 2026-09-06.
        public let continuedElsewhereSessionCount: Int
        /// Sessions skipped because their transcript was missing, unreadable,
        /// empty, or over the byte budget. Reported so a "0 disagreements"
        /// reading can never be mistaken for "0 disagreements measured".
        public let unreadableSessionCount: Int
        /// Sessions whose CREATION ROW NO LONGER EXISTS, so their creation
        /// source cannot be measured from the transcript at all.
        ///
        /// 2026-09-11 (audit finding 10): compaction replaces the early
        /// transcript with one `native_autocompaction` recollection row, and
        /// the first surviving surface row is then just the oldest retained
        /// turn. Taking it as the creation row made the live main session
        /// (index `telegram`, created Sep 6; first retained row a Sep 10 `app`
        /// tool row) a "disagreement" that Doctor went on to describe as a
        /// restamp. A missing row is UNMEASURED, never evidence of a defect:
        /// these sessions are counted here and judged for nothing.
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

    /// The §1.3 flapping detector. Read-only over `chat/sessions.json` and the
    /// transcripts it names.
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
            let indexSource = row.source.map(normalizedSource) ?? ""
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
                if normalizedSource(source) == "native_autocompaction" {
                    compacted = true
                }
                // 2026-09-06: only rows a SURFACE authored answer "which
                // surface owns this conversation". System bookkeeping rows do
                // not — the autocompactor's summary carries
                // source "native_autocompaction" (ChatSessionAutocompactor),
                // so every compacted session tallied two sources and was
                // reported as flapping. That is a legitimate storage shape,
                // not a mixed-source session.
                if case .string(let role)? = record["role"],
                   role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system" {
                    continue
                }
                let normalized = normalizedSource(source)
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
            // 2026-09-06: a majority of LATER rows from another surface is a
            // conversation continued elsewhere, which is a supported shape and
            // not a defect. Only the index disagreeing with the creation row is.
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

    /// The same normalization `ChatOrchestrationClient.messageSource(for:)`
    /// applies when it writes the row, so a comparison between an index
    /// `source` and a message `source` compares like with like.
    static func normalizedSource(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "telegram": return "telegram"
        case "ios", "mobile", "iphone", "icloud": return "ios"
        case "app", "chat", "mac", "default", "": return "app"
        default: return normalized
        }
    }
}
