import Foundation
import os

// Blueprint: | `WorkshopWireVocabulary.swift` | Workshop wire vocabularies: canonical surface/event/approval/inbox/environment spelling and current writes and data-retained historical reads |

// Wire aliases are translated here, without rewriting stored records.
// Comparisons canonicalize both sides; callers use these vocabularies rather than open-coded aliases.

// MARK: - Surface vocabulary

/// Surface identifiers: emit `workshop`; accept `workshop` and `missions`.
public enum WorkshopSurfaceVocabulary {
    public static let canonical = "workshop"
    public static let legacy = "missions"

    /// Disclosure allowlists accept both spellings, canonical first.
    public static let bothSpellings: [String] = [canonical, legacy]

    /// Trim + lowercase, then fold the legacy spelling onto the canonical one.
    /// Every other surface passes through normalized but unchanged.
    public static func canonicalSurface(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == legacy ? canonical : normalized
    }

    /// Fold either Workshop spelling; preserve every other surface byte-for-byte.
    public static func foldLegacySpelling(_ value: String) -> String {
        isWorkshopSurface(value) ? canonical : value
    }

    /// True when `value` names the Workshop surface in EITHER vocabulary.
    public static func isWorkshopSurface(_ value: String) -> Bool {
        canonicalSurface(value) == canonical
    }

    /// Gates also accept singular `mission`; routing/config keys do not fold it.
    public static let gateSpellings: [String] = [canonical, legacy, "mission"]

    /// Match any gate spelling after trimming whitespace and lowercasing.
    public static func isWorkshopGateSurface(_ value: String) -> Bool {
        gateSpellings.contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Fold `missions` into `workshop` in config maps; an existing `workshop` key wins.
    public static func canonicalizeSurfaceKeys<V>(_ map: [String: V]) -> [String: V] {
        guard map[legacy] != nil else { return map }
        var out = map
        let legacyValue = out.removeValue(forKey: legacy)
        if out[canonical] == nil, let legacyValue {
            out[canonical] = legacyValue
        }
        return out
    }
}

// MARK: - Execution event vocabulary

/// Event kinds: accept the listed aliases and emit their canonical spellings.
public enum ExecutionEventVocabulary {
    /// Accepted legacy spelling -> emitted canonical spelling.
    public static let renames: [(legacy: String, canonical: String)] = [
        ("mission.step", "execution.step"),
        ("mission_complete", "execution_complete"),
        ("mission_cancelled", "execution_cancelled"),
    ]

    /// Trim whitespace; translate exact or colon-prefixed kinds, preserving case and suffixes.
    public static func canonicalKind(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for rename in renames {
            if trimmed == rename.legacy { return rename.canonical }
            if trimmed.hasPrefix(rename.legacy + ":") {
                return rename.canonical + trimmed.dropFirst(rename.legacy.count)
            }
        }
        return trimmed
    }

    /// Compare canonical kinds; two absent values match.
    public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return canonicalKind(lhs) == canonicalKind(rhs)
    }

}

/// Workshop-step approval action and payload kind: emit `execution.step`; accept `mission.step`.
public enum WorkshopStepApprovalAction {
    public static let canonical = "execution.step"
    public static let legacy = "mission.step"
}

/// Approval payload: the current writer and reader use `execution_id`.
public enum WorkshopStepApprovalPayload {
    /// The only key any writer may emit.
    public static let canonicalExecutionIdKey = "execution_id"
    /// The canonical execution identity, or nil when it is absent.
    public static func executionId(_ lookup: (String) -> String?) -> String? {
        guard let value = lookup(canonicalExecutionIdKey), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Cross-device keys

/// The current Trust policy block shared by Mac and phone.
public enum WorkshopPolicyBlockVocabulary {
    public static let wireKey = "workshopPolicy"

    public static func block<V>(_ policy: [String: V]) -> V? {
        policy[wireKey]
    }
}

/// Inbox execution link: emit `related_execution_id`; InboxItemRecord alone
/// reads retained `related_mission_id` (present on the live root, 2026-11-01).
public enum InboxExecutionLinkVocabulary {
    public static let wireKey = "related_execution_id"
    public static let legacyKey = "related_mission_id"
}

/// Inbox action/response execution ID: the current phone and Mac use `executionId`.
public enum InboxActionExecutionIdVocabulary {
    public static let wireKey = "executionId"

    /// No identity is inferred from an older key or another object.
    public static func executionId(_ payload: [String: String]) -> String? {
        guard let value = payload[wireKey], !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Environment variable vocabulary

/// Only current execution environment names are accepted.
public enum ExecutionEnvVocabulary {
    public static func value(
        canonical: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let raw = environment[canonical]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }
}
