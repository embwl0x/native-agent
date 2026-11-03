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
public enum DreamTrigger: String, Sendable, Equatable, CaseIterable, Codable {
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
    /// Her cares as the committed dream was shown them, with its answer lines.
    public var careNight: CognitiveCareNight?
    /// Generated and decoded through the real dream path; never committed.
    public var preview: JSONValue?
    /// Previously committed sections whose retained work finished on this pass.
    public var effectsSettled: Int = 0

    public var committed: Bool { entriesWritten > 0 && !disabled && errors.isEmpty }

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

/// CPU reading of existing surprise records over the same high-water window
/// as the dream. The runner adds the prompt-owned header and bounds the block.
public typealias DreamSurpriseProvider = @Sendable (_ since: Date, _ through: Date) async throws -> String

/// Provider for the "felt" tone of the dream prompt — ONE bounded, read-time
/// summary of what the day FELT like, pulled from the cognitive substrate's
/// felt layer (per-node emotional tags + derived mood). Returns nil when nothing
/// was felt / affect is disabled, in which case the dream's felt section is
/// OMITTED entirely (feeling-silence stays silence, mirroring the capsule's
/// neutral path). Default returns nil so tests don't need to wire one. Production
/// (BackgroundLoopsAssembly) wires this against the substrate's
/// `feltDaySummary(at:)`. It colors the dream's TONE — it never scripts content.
public typealias DreamFeltSummaryProvider = @Sendable () async throws -> String?

/// Provider for the felt nodes' provenance behind `DreamFeltSummaryProvider`'s
/// text — the same last-24h felt population, subject/metadata only. Default is
/// empty, so a dream with nothing wired cites nothing and reads exactly as it
/// did before.
public typealias DreamFeltOriginProvider = @Sendable () async throws -> [CognitiveFeltOrigin]

/// Her cares for the dream prompt: what moved her today and what is still open,
/// with the keys the dream may answer by. nil when the inner life is off.
public typealias DreamCareNightProvider = @Sendable () async throws -> CognitiveCareNight?

/// Receipt channel for the dream lane. DreamREMCycle holds no substrate
/// reference (and must not: cognition lives above it), so a receipt it owns is
/// handed OUT to whoever holds the store — the same shape
/// `CognitiveSubstrate.recordReceiptChecked(kind:payload:)` takes. Default is
/// an explicit unavailable failure, never an acknowledgment.
public typealias DreamReceiptSink = @Sendable (_ kind: String, _ payload: JSONValue) async throws -> Void

/// Her explicit affect judgment, after the dream commits. The dated sink answers
/// whether the effect persisted or its owner is explicitly switched off.
public typealias DreamDatedMoodSink = @Sendable (
    _ affect: Double,
    _ dateKey: String
) async throws -> DreamEffectResult

/// One owed step, carrying its retained input. Producing a reflection is distinct
/// from integrating it: its judgment must be saved before it can change her.
public enum DreamEffect: Sendable {
    case reflectionJudgment([String: CognitiveReflectionCause])
    case reflectionIntegration(CognitiveReflectionReceipt)
    case reflectionAcknowledgment(UUID)
    case care(CognitiveCareNight)
    case completion(occurredAt: Date, feltSummary: String?)
}

public enum DreamEffectResult: Sendable {
    case done
    case skipped(String)
    case reflection(CognitiveReflectionReceipt)
}

/// Delivery of the exact saved section, never a fresh lookup of the latest dream.
public struct DreamDelivery: Sendable {
    public let id: UUID
    public let date: String
    public let trigger: DreamTrigger
    public let force: Bool
    public let sessionsProcessed: Int
    public let effect: DreamEffect
}

public typealias DreamEffectSink = @Sendable (DreamDelivery) async throws -> DreamEffectResult
import CognitiveSubstrate
// Blueprint: | `DreamCycleContracts.swift` | Dream trigger, report, provider and saved-effect delivery contracts, including bounded CPU surprise material and the uncommitted decoded preview result |
