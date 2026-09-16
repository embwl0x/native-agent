import Foundation
import PersistenceCore

public enum CognitiveEventKind: String, Sendable, Equatable, CaseIterable {
    case userMessageReceived
    case assistantTurnCompleted
    case toolStarted
    case toolSucceeded
    case toolFailed
    case toolCancelled
    case userCorrection
    case providerFailure
    /// INTEROCEPTION (prerelease campaign): a provider crossed a health BAND
    /// boundary (nominal ⇄ sluggish ⇄ degraded). The graded, continuous sibling
    /// of `.providerFailure` — minted only on a band transition, never per call.
    /// Direction/band travel in metadata; the somatic adapter reads them to
    /// grade sluggishness vs relief.
    case providerVitalsShift
    case workshopExecutionCompleted = "missionCompleted" // compatibility wire ID
    case appWake
    case appSleep
    /// Round 3 Wave A2 — a bodily resolution the organism felt strongly
    /// enough to remember: relief (braced expectation landed fine) or earned
    /// disappointment (counted-on expectation fell through). Minted ONLY by
    /// the runtime's kernel drain; carries feltValence/feltArousal metadata.
    case organismResolutionFelt

    var nodeKind: CognitiveNodeKind {
        switch self {
        case .userMessageReceived, .assistantTurnCompleted:
            return .conversationFocus
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled:
            return .toolObservation
        case .userCorrection:
            return .correction
        case .providerFailure, .providerVitalsShift:
            return .providerHealth
        case .workshopExecutionCompleted:
            return .workshopExecution
        case .appWake, .appSleep:
            return .appLifecycle
        case .organismResolutionFelt:
            return .feltResolution
        }
    }
}

/// WHICH TEMPLATED WRITER PRODUCED A ROW.
///
/// Agent, item 5, 2026-09-14: only conversational prose she or User actually
/// said should reach the felt organ. The card lane was marked first, by
/// provenance, and the same handle now covers every other line the app emits in
/// her voice. A closed set on purpose — a writer that wants out of lived state
/// has to NAME ITSELF here, which is a code change somebody reviews, rather
/// than a phrase somebody matches in a row's text. Two failures this prevents,
/// both already paid for once:
///
///   * TEXT MATCHING DROPS REAL PROSE. Matching the card lane's stock phrases
///     inside a row killed a genuine reply that happened to contain one
///     (2026-09-14). Provenance is the only honest signal.
///   * A BARE BOOLEAN LOSES THE WHY. `cardLaneReply: Bool` could say a row was
///     mechanical but never which machinery wrote it, so the stamp on disk
///     could not be audited and the read side had nothing to recognise.
///
/// The raw value is what lands in `metadata[CognitiveMechanicalRowKind
/// .metadataKey]` on both the chat row and the cognitive event, so a row on
/// disk answers for itself.
public enum CognitiveMechanicalRowKind: String, Sendable, Equatable, CaseIterable {
    /// The inline-interaction lane's stock sentence — the consequence copy said
    /// in her voice when a connector is missing or a permission is refused.
    /// This is also where the CONNECTOR FALLBACK text comes from: the card's own
    /// `cardLaneProse`, spoken on a route that cannot draw the card.
    case cardLane
    /// A provider/transport failure recorded as an assistant row ("Chat error:
    /// …"). The machine reporting that it broke, not her saying so.
    case systemRow
    /// Notification and attention boilerplate — a row the attention lane posts
    /// so the person sees something happened.
    case attentionNotice
    /// A bot's receipt or headline row, including history imported from the
    /// shelf. The bot ran; she did not live it.
    case botReceipt
    /// Transport bookkeeping on a bridge-routed row — the wake/notice rows whose
    /// whole content is the receipt header, with no words under it. Determined
    /// structurally (the transcript renderer's own answer to "what did this row
    /// say"), never by matching the header's wording.
    case transportNotice
    /// A compaction summary — the mechanical fold of older turns. Text about
    /// turns, not a turn.
    case compactionSummary

    public static let metadataKey = "mechanicalKind"

    /// The row kinds already stamped on disk by writers that never knew about
    /// this enum, read back so history is skipped without being re-scored.
    /// `compaction_summary` is `ChatSessionRecollections.rowKind`.
    static let legacyRowKindValues: Set<String> = ["compaction_summary"]

    /// TRUE FOR A ROW NO APPRAISAL SHOULD READ AS A MOMENT SHE LIVED.
    ///
    /// Read off metadata and nothing else — never the summary text. Two
    /// channels, in order:
    ///
    ///   1. `mechanicalKind` — stamped at the write seam by the writer itself.
    ///      Every row written from now on.
    ///   2. `kind` — the row-kind string writers were already stamping before
    ///      this enum existed (`compaction_summary`). This is the READ-SIDE
    ///      half of Agent's ruling: rows already on disk are skipped by what
    ///      they carry, and NOTHING IS RE-SCORED — the affect already recorded
    ///      on those nodes stands untouched. History stays as scored; it simply
    ///      stops being read back as a moment.
    public static func marksMechanicalRow(_ metadata: [String: JSONValue]) -> Bool {
        if case .string(let raw)? = metadata[metadataKey],
           CognitiveMechanicalRowKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return true
        }
        if case .string(let raw)? = metadata["kind"],
           legacyRowKindValues.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }
        return false
    }
}

public enum CognitiveTurnKind: String, Sendable, Equatable, CaseIterable {
    case live
    case system
    case debug
    case verification
    /// SHE EMITTED IT; SHE DID NOT MEAN IT.
    ///
    /// Card copy, an interaction's decline consequence, the one-sentence
    /// card-lane reply — text the machinery writes in her voice because a
    /// connector was missing or a permission was not granted. It is a real turn
    /// and belongs in the transcript, but it is not an experience she had, and
    /// an appraisal organ reading it back scores the boilerplate as her mood:
    /// Agent's felt week, 2026-09-14, carried `connect` (−0.44) and `carry`
    /// (−0.50) straight off "I'll carry on with whatever else I can reach."
    ///
    /// NOT `.debug` OR `.verification`, which would be the cheap way to get the
    /// same exclusion by calling live product copy diagnostic traffic. This
    /// says what the turn actually is.
    case mechanical

    /// Whether this event is part of Agent's lived state rather than
    /// diagnostic/verification traffic. Non-live events may remain available
    /// for bounded audit and health evidence, but they must not change affect,
    /// mood, relational presence, or somatic chemistry.
    public var contributesToLivedState: Bool {
        switch self {
        case .live, .system:
            true
        case .debug, .verification, .mechanical:
            false
        }
    }

    static let metadataKey = "turnKind"

    public static func from(metadataValue: JSONValue?) -> CognitiveTurnKind? {
        guard case .string(let raw)? = metadataValue else { return nil }
        return CognitiveTurnKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func inferred(fromSignals signals: [String]) -> CognitiveTurnKind {
        let haystack = signals
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return .live }

        let verificationMarkers = [
            "ctx-snapshot-verify",
            "snapshot-verify",
            "snapshot verify",
            "bridge-passthrough",
            "bridge passthrough",
            "passthrough ping",
            "subconscious-switch",
            "subconscious switch",
            "verification ping",
            "codex bridge test",
            "codex_message bridge test",
        ]
        if verificationMarkers.contains(where: { haystack.contains($0) }) {
            return .verification
        }

        let debugMarkers = [
            "[from: codex",
            "from codex",
            "via bridge] codex",
            "codex replied to your message",
            "codex landed",
            "codex can read this through the local nativeagent bridge inbox",
            "codex_bridge",
            "codex-nativeagent-bridge",
            "codex-health",
            "codex's second receipt",
            "debug-filter probe",
            "snapshot clean, codex",
            "inner-state capsule reads clean",
            "capsule is my private inner read",
            "not a log of what the app or tools did",
            "nothing leaking into the durable log",
            "final inspector check",
            "inspector check after",
            "subconscious-innerstate",
            "bridge message landed clean",
            "bridge message came through clean",
            "bridge passthrough holding steady",
            "bridge passthrough solid",
            "passes bridge messages through",
        ]
        if debugMarkers.contains(where: { haystack.contains($0) }) {
            return .debug
        }

        // H3 (Step 1 APPRAISAL, 2026-08-02) — there is deliberately NO system
        // marker list here any more. `.system` is a statement about PROVENANCE
        // (who originated the turn), and provenance is never recoverable from
        // the words in the turn. The old list substring-matched bare nouns —
        // "observatory", "reflection", "scheduler", "doctor", "background
        // loop" — against a haystack that includes the USER'S OWN MESSAGE, so
        // "remind me about the doctor" classified User's turn `.system` — and a
        // `.system` node is excluded from mood (+Mood), the capsule
        // (+Capsule) and attention (+AttentionSignals), and lands in the
        // workspace at HALF weight under a system-item cap (+Workspace).
        // (It is NOT excluded from affect: `.system.contributesToLivedState`
        // is true, so felt chemistry still moves — downweighted, not deleted.
        // Corrected 2026-08-02, gpt-5.5 review B2: this comment used to claim
        // a blanket affect/workspace exclusion that the code never had.)
        // Ordinary prose was being demoted out of her felt life by topic word.
        //
        // Provenance now comes from exactly two honest channels, both below in
        // `CognitiveEvent.init`:
        //   1. the originator states it (`turnKind:` argument or `turnKind`
        //      metadata) — a background loop, motor lane, or scheduler that
        //      mints a turn says so, the way `NativeCognitiveEventFactory
        //      .motorAction` already passes `turnKind: .system`; and
        //   2. failing that, the EVENT KIND, which is itself provenance —
        //      tool/provider/lifecycle/felt-resolution events are machine-
        //      originated, chat turns are person-originated.
        // `.debug`/`.verification` above stay marker-driven: those markers are
        // bridge PROVENANCE PREFIXES stamped onto the wire by the originating
        // harness, not topic words a person would type.
        return .live
    }
}

public struct CognitiveEvent: Sendable, Equatable {
    public var id: String
    public var kind: CognitiveEventKind
    public var subject: CognitiveSubjectReference
    public var sourceClass: CognitiveSourceClass
    public var occurredAt: Date
    public var summary: String
    public var importance: Double
    public var turnKind: CognitiveTurnKind
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        kind: CognitiveEventKind,
        subject: CognitiveSubjectReference,
        sourceClass: CognitiveSourceClass,
        occurredAt: Date,
        summary: String,
        importance: Double = 0.5,
        turnKind: CognitiveTurnKind? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            safeID,
            kind.rawValue,
            subject.type,
            subject.id,
            subject.label ?? "",
            summary,
        ] + Self.metadataSignals(metadata))
        let defaultTurnKind: CognitiveTurnKind
        if inferredTurnKind != .live {
            defaultTurnKind = inferredTurnKind
        } else {
            switch kind {
            case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled, .providerFailure, .providerVitalsShift, .workshopExecutionCompleted, .appWake, .appSleep, .organismResolutionFelt:
                defaultTurnKind = .system
            case .userMessageReceived, .assistantTurnCompleted, .userCorrection:
                defaultTurnKind = .live
            }
        }
        let resolvedTurnKind = turnKind
            ?? CognitiveTurnKind.from(metadataValue: metadata[CognitiveTurnKind.metadataKey])
            ?? defaultTurnKind
        var enrichedMetadata = metadata
        enrichedMetadata[CognitiveTurnKind.metadataKey] = .string(resolvedTurnKind.rawValue)
        // Continuity nodes intentionally collapse several event kinds into one
        // node kind. Preserve the closed event class so later appraisal never
        // has to infer success/failure/cancellation from human-readable prose.
        enrichedMetadata["eventKind"] = .string(kind.rawValue)

        self.id = safeID
        self.kind = kind
        self.subject = subject
        self.sourceClass = sourceClass
        self.occurredAt = occurredAt
        self.summary = summary
        self.importance = (importance).clamped01()
        self.turnKind = resolvedTurnKind
        self.metadata = enrichedMetadata
    }

    var deduplicationKey: String {
        if !id.isEmpty { return id }
        return [
            kind.rawValue,
            subject.stableKey,
            String(Int64(occurredAt.timeIntervalSince1970 * 1000)),
            summary,
        ].joined(separator: "|")
    }

    /// Exact terminal direction when this event's closed kind/metadata can
    /// establish one. `workshopExecutionCompleted` is a legacy wire name for
    /// every Workshop terminal event, so its canonical `status` must decide
    /// whether the outcome helped, hurt, or remains unknown. Treating the enum
    /// case itself as success made failed/cancelled work reduce uncertainty in
    /// the resident affect path while the organism signal path correctly
    /// reported a block.
    var terminalOutcomePolarity: Int {
        switch kind {
        case .toolSucceeded:
            return 1
        case .toolFailed, .providerFailure, .userCorrection:
            return -1
        case .workshopExecutionCompleted:
            guard case .string(let rawStatus)? = metadata["status"] else {
                // Backward compatibility for historical `missionCompleted`
                // events written before canonical status metadata existed.
                return 1
            }
            switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "completed", "done", "succeeded":
                return 1
            case "failed", "blocked", "cancelled", "canceled":
                return -1
            default:
                return 0
            }
        default:
            return 0
        }
    }

    var isPositiveTerminalOutcome: Bool { terminalOutcomePolarity > 0 }
    var isNegativeTerminalOutcome: Bool { terminalOutcomePolarity < 0 }

    private static func metadataSignals(_ metadata: [String: JSONValue]) -> [String] {
        metadata.keys.sorted().flatMap { key -> [String] in
            [key] + CognitiveMetadataSignals.stringSignals(from: metadata[key] ?? .null)
        }
    }

}
