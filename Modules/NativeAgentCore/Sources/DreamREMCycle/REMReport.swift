import Foundation
import CoreFoundation

// MARK: - REMReport

public struct REMReport: Sendable, Codable, Equatable {
    public var proposalsGenerated: Int
    /// The wire field counts supporting experiences or dream dates despite its date-oriented name.
    public var evidenceDatesMin: Int
    public var tombstoneSkips: Int
    public var growthMDEvicted: Int
    public var archivedEntries: Int
    /// Name refused persona targets; omit the field only when none were refused.
    public var personaTargetDrops: [String: Int]?
    /// Name passage-bound refusal reasons; absence means no such refusals.
    public var passageBoundDrops: [String: Int]?
    /// Distinguish skipped work from a quiet completed week.
    public var skipReason: String?

    /// Share the terminal classification with REM's owner and callers.
    public var outcome: REMRunReportPayload.Outcome {
        if skipReason != nil { return .skipped }
        if let unavailableDreamSections, !unavailableDreamSections.isEmpty { return .failed }
        return .completed
    }
    /// Count dwelling separately; repeated dreams of one occasion are not recurrence.
    public var dweltOnKept: Int?
    /// Expose unknown provenance rather than infer recurrence.
    public var provenanceUnavailableKept: Int?
    /// Unreadable sections stay unconsumed while readable siblings proceed.
    public var unavailableDreamSections: [String]?
    /// Keep committed causes transient and outside the counter-only ledger.
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

/// Persist only bounded counters, outcome and reason so run evidence survives restart without diary, persona or proposal text.
public struct REMRunReportPayload: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable, Equatable {
        /// Zero proposals still count as completion if every commit boundary was reached.
        case completed
        /// A fresh weekly reservation prevents a second model pass.
        case skipped
        /// Trust refusal must precede REM persistence.
        case disabled
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
        // Check CF type to distinguish real booleans while preserving numeric zero and one.
        if isBoolean(rawValue) { return nil }
        guard let value = rawValue as? Int, value >= 0 else { return nil }
        return value
    }

    /// Reject numeric zero/one as booleans despite Foundation bridging.
    private static func isBoolean(_ rawValue: Any?) -> Bool {
        guard let number = rawValue as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
import CognitiveSubstrate
// Blueprint: | `REMReport.swift` | `REMReport`, `REMRunReportPayload`. |
