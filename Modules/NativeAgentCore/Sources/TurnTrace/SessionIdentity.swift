import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Experiences

// Blueprint: | `SessionIdentity.swift` | Session identity ledger, mint-site traces and source-flapping diagnostics |

// MARK: - SessionIdentityTrace

/// Session identity emits through bounded, drop-on-backpressure `TurnTraceBus.fire` without awaiting observers or persistence. Resolutions outside a bound turn
/// still emit, stamped with `unboundTurnId`.
public enum SessionIdentityTrace {
    public static let kind = "session.identity"
    /// Bump the schema tag only for a breaking payload change.
    public static let schema = "session.identity.v1"
    /// Give unbound resolutions an explicit envelope identity.
    public static let unboundTurnId = "unbound"

    public enum MintSite: String, Sendable, Equatable, CaseIterable {
        case telegramSessionStore = "telegram_session_store"
    }

    /// Separate minted identities from reuse so Doctor's creation count measures actual minting.
    public enum Resolution: String, Sendable, Equatable, CaseIterable {
        case requested
        case mapped
        case minted
        /// Adopt a concurrent first message's identity under the same lock to avoid duplicate sessions.
        case adopted
    }

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
            destinationId: TurnTraceContext.destinationId,
            threadId: TurnTraceContext.threadId,
            payload: .object(payload),
            turn: nil
        )
    }

    /// Fire-and-forget emission. Never throws, never awaits, never blocks the caller's resolution.
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

/// Read-only mint counts and source-flapping diagnostics take no lock and share the writer's payload contract. Diagnostic reads never throw; decoded evidence
/// is counted and unreadable coverage stays explicit.
public enum SessionIdentityLedger {
    public struct MintTally: Sendable, Equatable {
        public let mintedByMintSite: [String: Int]
        public let totalRows: Int
        public let daysWithEvidence: Int
        public let unreadable: Int
        public let readIssue: String?

        public var totalMinted: Int { mintedByMintSite.values.reduce(0, +) }

        public init(mintedByMintSite: [String: Int], totalRows: Int, daysWithEvidence: Int,
                    unreadable: Int = 0, readIssue: String? = nil) {
            self.mintedByMintSite = mintedByMintSite
            self.totalRows = totalRows
            self.daysWithEvidence = daysWithEvidence
            self.unreadable = unreadable
            self.readIssue = readIssue
        }
    }

    /// Count recorded identity resolutions within the requested window. Empty evidence leaves minting unmeasured.
    public static func mintTally(
        dataRoot: URL,
        now: Date = Date(),
        window: TimeInterval = 24 * 60 * 60
    ) async -> MintTally {
        let cutoff = now.addingTimeInterval(-window)
        do {
            let read = try await TurnTracePersistLane(dataRootOverride: dataRoot)
                .events(.init(kinds: [SessionIdentityTrace.kind], from: cutoff, through: now))
            var minted: [String: Int] = [:]
            var days: Set<Date> = []
            var total = 0
            var unreadable = read.unreadable
            for event in read.events {
                guard case .object(let payload) = event.payload,
                      payload["schema"] == .string(SessionIdentityTrace.schema),
                      case .string(let resolvedBy)? = payload["resolvedBy"],
                      SessionIdentityTrace.Resolution(rawValue: resolvedBy) != nil,
                      case .string(let site)? = payload["mintSite"],
                      SessionIdentityTrace.MintSite(rawValue: site) != nil else {
                    unreadable += 1
                    continue
                }
                total += 1
                days.insert(TurnTracePersistLane.dayCalendar.startOfDay(for: event.ts))
                if resolvedBy == SessionIdentityTrace.Resolution.minted.rawValue { minted[site, default: 0] += 1 }
            }
            return MintTally(mintedByMintSite: minted, totalRows: total, daysWithEvidence: days.count, unreadable: unreadable)
        } catch {
            return MintTally(mintedByMintSite: [:], totalRows: 0, daysWithEvidence: 0, readIssue: error.localizedDescription)
        }
    }

    public struct FlappingReport: Sendable, Equatable {
        public let indexReadable: Bool
        public let hotSessionCount: Int
        public let disagreeingSessionIds: [String]
        /// Multiple transcript sources can reflect valid continuation on another surface.
        public let mixedSourceSessionCount: Int
        /// Sessions continued mostly on another surface; informational, never a warning.
        public let continuedElsewhereSessionCount: Int
        /// Report skipped coverage so zero measured disagreements cannot imply a clean scan.
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

    /// Bound each transcript read so health checks cannot scan unbounded hot history.
    static let maximumTranscriptBytes = 16 * 1024 * 1024
    /// Bound aggregate IO across the whole diagnostic pass.
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
            // A first surviving surface row newer than index creation cannot prove the conversation's original source.
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
            // Only confirmed absence or measured zero is empty; unreadable metadata remains unmeasured, never a clean diagnostic.
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
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let value = try? JSONValue.parse(lineData),
                      case .object(let record) = value,
                      case .string(let source)? = record["source"] else { continue }
                // Only surface-authored rows establish session source; system rows do not.
                if case .string(let role)? = record["role"],
                   role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system" {
                    continue
                }
                let normalized = ChatThreadKind.normalizedSource(source)
                // Use the first surface-authored row because it supplies the index's creation source.
                if creationSource == nil {
                    creationSource = normalized
                    if case .string(let stamp)? = record["createdAt"] {
                        creationRowAt = TurnTraceEvent.parseISO8601(stamp.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                tally[normalized, default: 0] += 1
            }
            guard let majority = tally.max(by: { lhs, rhs in
                // Break count ties by name so dictionary order cannot change the report.
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            })?.key, let creationSource else {
                unreadable += 1
                continue
            }
            if tally.count > 1 { mixed += 1 }
            // A first row beyond write skew leaves creation provenance unmeasured.
            let firstRowPostdatesCreation: Bool = {
                guard let indexCreatedAt, let creationRowAt else { return false }
                return creationRowAt.timeIntervalSince(indexCreatedAt) > creationRowSkewSeconds
            }()
            if firstRowPostdatesCreation {
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

    /// Allow a few seconds between independent writers; a later retained row cannot credibly establish the creation source.
    static let creationRowSkewSeconds: TimeInterval = 120

}
