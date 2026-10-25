import Foundation
import NativeAgentCore
import PersistenceCore

/// Assembly provenance is request metadata, never an inference from prompt prose.
public enum PrivateWorkContextAssembly: Sendable {
    case compilePersona
    case suppliedPersona
    case taskOnly

    @TaskLocal public static var current: PrivateWorkContextAssembly = .compilePersona
}

/// What woke the dream. `schedule` is the 03:30 daily job on the Mac's local clock.
/// `manual` is a person asking for a pass now, from the Dreams tab or a tool. Receipts carry it so a dream's
/// provenance is never guessed from its timestamp.
public enum DreamTrigger: String, Sendable, Equatable, CaseIterable {
    case schedule
    case manual
}

public struct DreamReport: Sendable, Equatable {
    public var repair: JSONValue?
    public var sessionsProcessed: Int
    public var entriesWritten: Int
    public var errors: [String]
    public var disabled: Bool
    public var trigger: DreamTrigger
    /// Set when a run wrote nothing for a reason that is NOT a failure, so the
    /// scheduler's existing skipped-outcome shape can say WHICH honest reason:
    /// `no_new_material` (nothing past the high-water mark; an existing entry
    /// for the day is never a reason) or `already_running`.
    public var skipReason: String?
    /// The exact committed entry, delivered to reflection without a latest-item lookup.
    public var reflectionMaterial: [String: CognitiveReflectionCause] = [:]
    /// Her cares as the committed dream was shown them, with its answer lines.
    public var careNight: CognitiveCareNight?

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
/// about herself since the last dream). It is handed the run's own cutoff
/// (the high-water mark the conversations are read from), so a night that
/// retries a missed stretch dreams that stretch's memories too. Each string
/// is one pre-formatted delta. Default returns empty so tests don't need to
/// wire one. Production
/// (BackgroundLoopsAssembly) wires this against SwiftNativeMemoryV2 filtered
/// by the `persona-feedback` tag.
public typealias DreamMemoryDeltaProvider = @Sendable (_ since: Date) async throws -> [String]

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

/// Her cares for the dream prompt: what moved her today and what is still open,
/// with the keys the dream may answer by. nil when the inner life is off.
public typealias DreamCareNightProvider = @Sendable () async -> CognitiveCareNight?

/// Receipt channel for the dream lane. DreamREMCycle holds no substrate
/// reference (and must not: cognition lives above it), so a receipt it owns is
/// handed OUT to whoever holds the store — the same shape
/// `CognitiveSubstrate.recordReceipt(kind:payload:)` already takes. Default is
/// a no-op.
public typealias DreamReceiptSink = @Sendable (_ kind: String, _ payload: JSONValue) async -> Void

/// Her explicit affect judgment, after the dream commits. The dated sink answers
/// whether persistence landed, so a failed integration releases the existing claim.
public typealias DreamDatedMoodSink = @Sendable (
    _ affect: Double,
    _ dateKey: String
) async -> Bool
import CognitiveSubstrate
// Blueprint: | `DreamCycleContracts.swift` | `DreamTrigger` enum |
