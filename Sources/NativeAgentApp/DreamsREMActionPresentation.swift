import Foundation

/// The manual REM button has three distinct policy states. An unresolved
/// authority read cannot be presented as an enabled cycle, and an explicit
/// false remains a normal disabled state rather than an execution failure.
enum DreamsREMRunAvailability: Equatable {
    case checking
    case enabled
    case disabled
    case unavailable

    static func resolve(policy: TrustPolicy?, policyLoadFailed: Bool) -> Self {
        if policyLoadFailed { return .unavailable }
        guard let policy else { return .checking }
        return policy.trainingPolicy?.rem_cycle_enabled == true ? .enabled : .disabled
    }

    var canRun: Bool { self == .enabled }

    var help: String {
        switch self {
        case .checking:
            return "Checking REM-cycle permission."
        case .enabled:
            return "Run a REM consolidation pass over unconsumed dream entries."
        case .disabled:
            return "REM cycle is disabled. Enable the REM cycle toggle."
        case .unavailable:
            return "REM-cycle permission could not be read. Refresh and retry."
        }
    }
}

/// Bounded, user-visible completion for the same response returned by
/// `NativeClient.runRem()`. A synchronous manual run has already completed;
/// calling it "started" hides both no-op weeks and malformed responses.
enum DreamsREMActionFeedback: Equatable {
    case completed(proposals: Int, archivedEntries: Int)
    case failed(String)

    static func resolve(response: [String: Any]) -> Self {
        guard let ok = bool(response["ok"]), ok else {
            return .failed("REM consolidation did not report a successful completion.")
        }
        guard let proposals = nonnegativeInt(response["proposalsGenerated"]),
              let archivedEntries = nonnegativeInt(response["archivedEntries"]) else {
            return .failed("REM consolidation returned an incomplete completion record.")
        }
        return .completed(proposals: proposals, archivedEntries: archivedEntries)
    }

    var message: String {
        switch self {
        case .completed(let proposals, let archivedEntries):
            let proposalText = proposals == 1 ? "1 proposal" : "\(proposals) proposals"
            let archiveText = archivedEntries == 1 ? "1 diary entry archived" : "\(archivedEntries) diary entries archived"
            return "REM consolidation completed — \(proposalText), \(archiveText)."
        case .failed(let detail):
            return detail
        }
    }

    var systemImage: String {
        switch self {
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var isSuccess: Bool {
        if case .completed = self { return true }
        return false
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
        if rawValue is Bool { return nil }
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
}
