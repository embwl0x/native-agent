import Foundation
import NativeAgentCore
import PersistenceCore

/// The background client owns this operation's persona assembly explicitly.
public enum PrivateWorkContextAssembly: Sendable {
    case compilePersona
    case suppliedPersona
    case taskOnly
}

/// Retain the trigger so dream provenance cannot be guessed from time; scheduled runs use the Mac's local clock.
public enum DreamTrigger: String, Sendable, Equatable, CaseIterable, Codable {
    case schedule
    case manual
}

public struct DreamReport: Sendable, Equatable {
    public var repair: JSONValue?
    public var sessionsProcessed: Int
    public var entriesWritten: Int
    public var errors: [String]
    /// Effects kept owed because a shared slot was busy: not errors, each naming its holder and when to try again.
    public var busy: [String] = []
    public var disabled: Bool
    public var trigger: DreamTrigger
    /// Keep nonfailure skips distinct and name their actual reason; an existing diary entry alone cannot justify skipping new material.
    public var skipReason: String?
    public var careNight: CognitiveCareNight?
    /// Preview uses real generation and decoding without committing.
    public var preview: JSONValue?
    public var effectsSettled: Int = 0
    /// Lessons this run committed to memory, from its own dream and any earlier night it settled.
    public var lessonsSaved: Int = 0

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

/// Use the run's conversation high-water cutoff for self-memory deltas too, so missed stretches retain matching evidence.
public typealias DreamMemoryDeltaProvider = @Sendable (_ since: Date) async throws -> [String]

/// Read surprise evidence over the dream's own window; the runner owns prompt headers and bounds.
public typealias DreamSurpriseProvider = @Sendable (_ since: Date, _ through: Date) async throws -> String

/// Omit felt tone when affect is absent or disabled; feeling-silence stays silence.
/// Use bounded substrate evidence to color tone without scripting dream content.
public typealias DreamFeltSummaryProvider = @Sendable () async throws -> String?

/// Use the same felt population's subject metadata for provenance; absent origins supply no citations.
public typealias DreamFeltOriginProvider = @Sendable () async throws -> [CognitiveFeltOrigin]

/// Open-care keys bind dream answers to shown cares; disabled inner life supplies none.
public typealias DreamCareNightProvider = @Sendable () async throws -> CognitiveCareNight?

/// Send receipts to the injected owner because cognition sits above DreamREMCycle.
/// An unavailable sink must fail explicitly rather than acknowledge.
public typealias DreamReceiptSink = @Sendable (_ kind: String, _ payload: JSONValue) async throws -> Void

/// Acknowledge dream affect only after dated persistence or an explicitly disabled owner.
public typealias DreamDatedMoodSink = @Sendable (
    _ affect: Double,
    _ dateKey: String
) async throws -> DreamEffectResult

/// Save produced reflection judgment before integration so no effect can precede its durable cause.
public enum DreamEffect: Sendable {
    case reflectionJudgment([String: CognitiveReflectionCause])
    case reflectionIntegration(CognitiveReflectionReceipt)
    case reflectionAcknowledgment(UUID)
    case care(CognitiveCareNight)
    case completion(occurredAt: Date, feltSummary: String?)
}

/// An effect whose shared slot other work holds stays owed and is not a failure; the words name the holder and when to try again.
public struct DreamBusy: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let words: String
    public init(_ words: String) { self.words = words }
    public var errorDescription: String? { words }
    public var description: String { words }
}

public enum DreamEffectResult: Sendable {
    case done
    case skipped(String)
    case reflection(CognitiveReflectionReceipt)
}

/// Deliver the exact saved section rather than looking up a newer dream.
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
// Blueprint: | `DreamCycleContracts.swift` | DreamCycleContracts owner. |
