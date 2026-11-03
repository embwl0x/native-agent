import Foundation
import CoreFoundation

// MARK: - REMReport

/// Summary the weekly REM run returns to its caller (scheduler / debug menu).
public struct REMReport: Sendable, Codable, Equatable {
    public var proposalsGenerated: Int
    /// Historical wire name: the floor applies to supporting experiences OR dream dates.
    public var evidenceDatesMin: Int
    public var tombstoneSkips: Int
    public var growthMDEvicted: Int
    public var archivedEntries: Int
    /// Proposals the store REFUSED, keyed by persona doc ("SOUL.md": 2).
    /// nil (and omitted on the wire) when nothing was dropped.
    public var personaTargetDrops: [String: Int]?
    /// Proposals the store REFUSED for breaking the GROWTH.md passage bound,
    /// keyed by reason ("over 240 characters": 1). nil when none.
    public var passageBoundDrops: [String: Int]?
    /// Distinguishes skipped work from a completed quiet week; nil when not skipped.
    public var skipReason: String?

    /// The same terminal classification used by the REM owner and its callers.
    public var outcome: REMRunReportPayload.Outcome {
        if skipReason != nil { return .skipped }
        if let unavailableDreamSections, !unavailableDreamSections.isEmpty { return .failed }
        return .completed
    }
    /// Of the survivors, how many are one lived occasion dreamt about more than
    /// once — kept and labelled `dwelt_on`, never counted as a pattern. nil when none.
    public var dweltOnKept: Int?
    /// Of the survivors, how many rest on entries with no provenance at all, so
    /// whether they recurred is not knowable. Said, not assumed.
    public var provenanceUnavailableKept: Int?
    /// Exact diary sections that remain unreadable and unconsumed; readable siblings proceed.
    public var unavailableDreamSections: [String]?
    /// Transient delivery of committed causes, excluded from the counter-only run ledger.
    public var reflectionMaterial: [String: CognitiveReflectionCause] = [:]

    private enum CodingKeys: String, CodingKey {
        case proposalsGenerated, evidenceDatesMin, tombstoneSkips, growthMDEvicted, archivedEntries
        case personaTargetDrops, passageBoundDrops, skipReason, dweltOnKept, provenanceUnavailableKept, unavailableDreamSections
    }

    public init(
        proposalsGenerated: Int,
        evidenceDatesMin: Int,
        tombstoneSkips: Int,
        growthMDEvicted: Int,
        archivedEntries: Int = 0,
        personaTargetDrops: [String: Int]? = nil,
        passageBoundDrops: [String: Int]? = nil,
        skipReason: String? = nil,
        dweltOnKept: Int? = nil,
        provenanceUnavailableKept: Int? = nil
    ) {
        self.proposalsGenerated = proposalsGenerated
        self.evidenceDatesMin = evidenceDatesMin
        self.tombstoneSkips = tombstoneSkips
        self.growthMDEvicted = growthMDEvicted
        self.archivedEntries = archivedEntries
        self.personaTargetDrops = personaTargetDrops
        self.passageBoundDrops = passageBoundDrops
        self.skipReason = skipReason
        self.dweltOnKept = dweltOnKept
        self.provenanceUnavailableKept = provenanceUnavailableKept
    }
}

/// Durable, privacy-safe summary of one invocation of `runWeeklyREM`.
///
/// `REMReport` is the successful-run value returned to an immediate caller.
/// This envelope is what survives a scheduler wake, app restart, or manual
/// debug session in the shared run ledger. It deliberately contains counters
/// and a bounded outcome/reason only — never diary, persona, or proposal text.
public struct REMRunReportPayload: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable, Equatable {
        /// The pipeline reached all commit boundaries (a zero-proposal week is
        /// still completed and is distinguishable by its real counters).
        case completed
        /// The weekly reservation was already fresh, so no second LLM pass ran.
        case skipped
        /// Trust policy rejected the run before any REM persistence work began.
        case disabled
        /// A real execution error or cancellation prevented completion.
        case failed
    }

    public static let schema = "rem.run_report.v1"

    public var schemaVersion: String
    public var outcome: Outcome
    public var reason: String?
    public var report: REMReport?

    public init(
        outcome: Outcome,
        reason: String? = nil,
        report: REMReport? = nil
    ) {
        self.schemaVersion = Self.schema
        self.outcome = outcome
        self.reason = reason
        self.report = report
    }
}

extension REMRunReportPayload {
    public static func validatedManualCompletion(
        response: [String: Any]
    ) -> Result<(proposals: Int, archivedEntries: Int, nothingToConsolidate: Bool), NSError> {
        if let skipReason = response["skipReason"] as? String,
           !skipReason.isEmpty, skipReason != "nothing_to_consolidate" {
            return .failure(NSError(domain: "NativeAgent.REMCompletion", code: 3, userInfo: [
                NSLocalizedDescriptionKey: skipReason == "already_running"
                    ? "REM consolidation is already running; this request was skipped."
                    : "REM consolidation was skipped; this request did not run a pass.",
                "skipReason": skipReason,
            ]))
        }
        guard let ok = bool(response["ok"]), ok else {
            return .failure(NSError(domain: "NativeAgent.REMCompletion", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "REM consolidation did not report a successful completion."
            ]))
        }
        guard let proposals = nonnegativeInt(response["proposalsGenerated"]),
              let archivedEntries = nonnegativeInt(response["archivedEntries"]) else {
            return .failure(NSError(domain: "NativeAgent.REMCompletion", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "REM consolidation returned an incomplete completion record."
            ]))
        }
        return .success((proposals, archivedEntries, response["skipReason"] as? String == "nothing_to_consolidate"))
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard isBoolean(value), let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private static func nonnegativeInt(_ rawValue: Any?) -> Int? {
        // Reject genuine booleans by CF type, preserving numeric counts of 0 and 1 despite Bool bridging.
        if isBoolean(rawValue) { return nil }
        guard let value = rawValue as? Int, value >= 0 else { return nil }
        return value
    }

    /// True only for a genuine boolean — a JSON `true`/`false` or a Swift
    /// `Bool` — never for a number that merely happens to be 0 or 1.
    private static func isBoolean(_ rawValue: Any?) -> Bool {
        guard let number = rawValue as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
import CognitiveSubstrate
// Blueprint: | `REMReport.swift` | `REMReport` owns the typed completed/skipped/failed projection used by its ledger and scheduled caller; `REMRunReportPayload` manual completion validates counters and refuses skipped passes as completion |
