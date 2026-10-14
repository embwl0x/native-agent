import Foundation

// MARK: - REMReport

/// Summary the weekly REM run returns to its caller (scheduler / debug menu).
public struct REMReport: Sendable, Codable, Equatable {
    public var proposalsGenerated: Int
    public var evidenceDatesMin: Int
    public var tombstoneSkips: Int
    public var growthMDEvicted: Int
    public var archivedEntries: Int
    /// Proposals the store REFUSED, keyed by persona doc ("SOUL.md": 2).
    /// nil (and omitted on the wire) when nothing was dropped — and optional
    /// so run reports written before this field decode unchanged. The fence
    /// itself is unchanged; this is the fence saying what it stopped.
    public var personaTargetDrops: [String: Int]?
    /// Proposals the store REFUSED for breaking the GROWTH.md passage bound,
    /// keyed by reason ("over 240 characters": 1). nil when none, and optional
    /// so older run reports decode unchanged.
    public var passageBoundDrops: [String: Int]?
    /// Why this pass did no work, when it did none. 2026-09-06: losing the run
    /// reservation to a concurrent pass returned a report indistinguishable
    /// from a genuine zero-proposal week, so the scheduler recorded the week
    /// "completed" and never came back — the week was silently dropped. nil on
    /// a pass that actually ran, and omitted on the wire so older run reports
    /// decode unchanged.
    public var skipReason: String?
    /// Of the survivors, how many are one lived occasion dreamt about more than
    /// once — kept and labelled `dwelt_on`, never counted as a pattern. nil
    /// when none, and optional so older run reports decode unchanged.
    public var dweltOnKept: Int?
    /// Of the survivors, how many rest on entries with no provenance at all, so
    /// whether they recurred is not knowable. Said, not assumed.
    public var provenanceUnavailableKept: Int?

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
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func nonnegativeInt(_ rawValue: Any?) -> Int? {
        // 2026-09-17: `is Bool` is not a boolean test on a decoded JSON value.
        // JSONSerialization hands back an NSNumber, and Swift bridges an
        // NSNumber holding 0 or 1 to Bool as readily as it bridges a real
        // boolean — so this guard rejected every record whose counts were 0,
        // and a young root's nothing-to-consolidate pass (proposals 0,
        // archived 0) read as an incomplete completion record before the
        // skipReason below was ever consulted. Reject only a true boolean.
        if isBoolean(rawValue) { return nil }
        let value: Int?
        if let integer = rawValue as? Int {
            value = integer
        } else if let number = rawValue as? NSNumber {
            value = number.intValue
        } else if let text = rawValue as? String {
            value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
        guard let value, value >= 0 else { return nil }
        return value
    }

    /// True only for a genuine boolean — a JSON `true`/`false` or a Swift
    /// `Bool` — never for a number that merely happens to be 0 or 1.
    private static func isBoolean(_ rawValue: Any?) -> Bool {
        guard let number = rawValue as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
