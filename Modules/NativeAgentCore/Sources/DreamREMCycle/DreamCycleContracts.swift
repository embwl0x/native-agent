import Foundation
import NativeAgentCore
import PersistenceCore

/// What woke the dream. `schedule` is the 03:30 America/Chicago daily job —
/// the integrity fallback. `pressure` is the organism's own identity-Dream lane
/// firing once its residual sleep pressure, quiet window and 24-hour refractory
/// all resolved (NORTHSTAR clause 4, 2026-09-01). Receipts carry it so a dream's
/// provenance is never guessed from its timestamp.
public enum DreamTrigger: String, Sendable, Equatable, CaseIterable {
    case schedule
    case pressure
}

public struct DreamReport: Sendable, Equatable {
    public var sessionsProcessed: Int
    public var entriesWritten: Int
    public var errors: [String]
    public var disabled: Bool
    public var trigger: DreamTrigger
    /// Set when a run wrote nothing for a reason that is NOT a failure, so the
    /// scheduler's existing skipped-outcome shape can say WHICH honest reason:
    /// `already_dreamt` (the target day's entry exists — typically because a
    /// pressure-fired dream beat the 03:30 job to it) or `no_new_material`.
    public var skipReason: String?

    public init(
        sessionsProcessed: Int = 0,
        entriesWritten: Int = 0,
        errors: [String] = [],
        disabled: Bool = false,
        trigger: DreamTrigger = .schedule,
        skipReason: String? = nil
    ) {
        self.sessionsProcessed = sessionsProcessed
        self.entriesWritten = entriesWritten
        self.errors = errors
        self.disabled = disabled
        self.trigger = trigger
        self.skipReason = skipReason
    }
}

/// Provider for the "self half" of the dream prompt — recent memory deltas
/// (persona-feedback episodic entries, KG nudges, anything she's absorbed
/// about herself since the last dream). Each string is one pre-formatted
/// delta. Default returns empty so tests don't need to wire one. Production
/// (BackgroundLoopsAssembly) wires this against SwiftNativeMemoryV2 filtered
/// by the `persona-feedback` tag.
public typealias DreamMemoryDeltaProvider = @Sendable () async throws -> [String]

/// Provider for the "felt" tone of the dream prompt — ONE bounded, read-time
/// summary of what the day FELT like, pulled from the cognitive substrate's
/// felt layer (per-node emotional tags + derived mood). Returns nil when nothing
/// was felt / affect is disabled, in which case the dream's felt section is
/// OMITTED entirely (feeling-silence stays silence, mirroring the capsule's
/// neutral path). Default returns nil so tests don't need to wire one. Production
/// (BackgroundLoopsAssembly) wires this against the substrate's
/// `feltDaySummary(at:)`. It colors the dream's TONE — it never scripts content.
public typealias DreamFeltSummaryProvider = @Sendable () async throws -> String?

/// The PROVENANCE half of one felt node — subject + metadata, and nothing else.
/// `DreamFeltSummaryProvider` says what the day felt like; this says where a
/// feeling CAME FROM, which is the only thing the dream needs beyond the tone.
///
/// Desk 903 phase 2 (the studio journal on the cognitive bus) mints a felt node
/// carrying its journal entry id in BOTH `subject.id` (with subject type
/// `studio_entry`) and `metadata["studioEntryId"]` — see the DREAM-CITATION
/// SEAM note in CognitiveSubstrate+StudioEvents.swift. Either alone is enough
/// here, so a node minted by either half still cites.
public struct DreamFeltOrigin: Sendable, Equatable {
    /// The seam's subject type for a filed journal entry.
    public static let studioEntrySubjectType = "studio_entry"
    /// The seam's metadata key for the same id.
    public static let studioEntryIDMetadataKey = "studioEntryId"

    public var subjectType: String?
    public var subjectID: String?
    public var metadata: [String: String]

    public init(
        subjectType: String? = nil,
        subjectID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.subjectType = subjectType
        self.subjectID = subjectID
        self.metadata = metadata
    }

    /// The journal entry this feeling came from, or nil when it came from
    /// anywhere else. Nil is the common case and is not a gap.
    public var studioEntryID: String? {
        if let value = metadata[Self.studioEntryIDMetadataKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if subjectType == Self.studioEntrySubjectType,
           let value = subjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }
}

/// Provider for the felt nodes' provenance behind `DreamFeltSummaryProvider`'s
/// text — the same last-24h felt population, subject/metadata only. Default is
/// empty, so a dream with nothing wired cites nothing and reads exactly as it
/// did before.
public typealias DreamFeltOriginProvider = @Sendable () async throws -> [DreamFeltOrigin]

/// Receipt channel for the dream lane. DreamREMCycle holds no substrate
/// reference (and must not: cognition lives above it), so a receipt it owns is
/// handed OUT to whoever holds the store — the same shape
/// `CognitiveSubstrate.recordReceipt(kind:payload:)` already takes. Default is
/// a no-op.
public typealias DreamReceiptSink = @Sendable (_ kind: String, _ payload: JSONValue) async -> Void

/// Completion sink for the nightly dream's own MOOD line — the felt tone of what she
/// dreamt. Fired exactly once per dream, AFTER the diary entry has actually been written
/// (a cancelled, failed, or no-op dream must never move her), and only when the LLM
/// emitted a non-empty `mood` field. The counterpart to `DreamFeltSummaryProvider`:
/// that one carries the day's feeling INTO the dream, this one carries the dream's
/// feeling back OUT into her slow disposition layer. Default is a no-op so
/// focused runner tests need not wire one.
///
/// 2026-09-06, two changes:
///   • the DATE KEY of the dream being delivered is passed explicitly. The sink
///     used to recover it by scanning for the greatest `.mood_integrated_*`
///     marker on disk, and those markers accumulate — a 03:30 scheduled dream
///     keys to the PREVIOUS day, so any newer marker named a different dream
///     and the residue mint was suppressed against the wrong night's claim.
///   • it returns whether the integration is DURABLE. The runner claims the day
///     before calling (that claim is what makes the sink fire once), and
///     releases the claim again when this returns false, so a night whose
///     disposition write failed is retryable instead of permanently spent.
///
/// 2026-09-06 (second pass): both of those ride a SECOND, optional sink rather
/// than a widened parameter list. A Swift closure type cannot give a parameter
/// a default, so changing `DreamMoodSink` in place broke every one-argument
/// caller in the tree, test targets included. The plain sink is restored
/// exactly as it was and is still honoured; a runner given the dated one
/// prefers it.
public typealias DreamMoodSink = @Sendable (String) async -> Void

/// The dated, answering form of `DreamMoodSink` — see the two changes above.
public typealias DreamDatedMoodSink = @Sendable (
    _ mood: String,
    _ dateKey: String
) async -> Bool
