import Foundation
import os

// Blueprint: | `WorkshopWireVocabulary.swift` | Workshop wire vocabularies: canonical surface/event/approval/inbox/environment spelling and centralized legacy translation |

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

/// Approval payload: write `execution_id`; read it before the permanent `mission_id` alias.
public enum WorkshopStepApprovalPayload {
    /// The only key any writer may emit.
    public static let canonicalExecutionIdKey = "execution_id"
    /// Accepted keys, in resolution order: canonical first, legacy fallback.
    public static let executionIdKeys = [canonicalExecutionIdKey, "mission_id"]

    /// First non-empty accepted value, or nil when none is present.
    public static func executionId(_ lookup: (String) -> String?) -> String? {
        for key in executionIdKeys {
            if let value = lookup(key), !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Cross-device keys

// Cross-device writers emit `wireKey`; readers accept both spellings with `futureKey` precedence.

/// Trust policy block: emit `missionPolicy`; accept `workshopPolicy` first.
public enum WorkshopPolicyBlockVocabulary {
    public static let wireKey = "missionPolicy"
    public static let futureKey = "workshopPolicy"
    /// Both spellings, future first — matching decoder resolution order.
    public static let bothSpellings: [String] = [futureKey, wireKey]

    /// Read the policy block under either spelling, future-first.
    public static func block<V>(_ policy: [String: V]) -> V? {
        policy[futureKey] ?? policy[wireKey]
    }

    /// Fold onto `wireKey` for merging/gating; `futureKey` wins when both are present.
    public static func foldToWireKey<V>(_ policy: [String: V]) -> [String: V] {
        guard let future = policy[futureKey] else { return policy }
        var out = policy
        out.removeValue(forKey: futureKey)
        out[wireKey] = future
        return out
    }
}

/// Inbox execution link: emit `related_mission_id`; accept `related_execution_id` first.
public enum InboxExecutionLinkVocabulary {
    public static let wireKey = "related_mission_id"
    public static let futureKey = "related_execution_id"
    public static let bothSpellings: [String] = [futureKey, wireKey]
}

/// Inbox action/response execution ID: emit `missionId`; accept `executionId` first.
public enum InboxActionExecutionIdVocabulary {
    public static let wireKey = "missionId"
    public static let futureKey = "executionId"
    public static let bothSpellings: [String] = [futureKey, wireKey]

    /// First non-empty value among `bothSpellings`, future-first.
    public static func executionId(_ payload: [String: String]) -> String? {
        for key in bothSpellings {
            if let value = payload[key], !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Environment variable vocabulary

/// Environment aliases: non-empty legacy values win; each logs one info-level notice per process.
public enum ExecutionEnvVocabulary {
    /// legacy name -> canonical name.
    public static let renames: [(legacy: String, canonical: String)] = [
        ("NATIVE_AGENT_MAX_ACTIVE_MISSIONS", "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS"),
        ("NATIVE_AGENT_MAX_PENDING_MISSIONS", "NATIVE_AGENT_MAX_PENDING_EXECUTIONS"),
        ("NATIVE_AGENT_MISSION_STEP_TIMEOUT_SECONDS", "NATIVE_AGENT_EXECUTION_STEP_TIMEOUT_SECONDS"),
        (
            "NATIVE_AGENT_MISSION_APPROVAL_TIMEOUT_SECONDS",
            "NATIVE_AGENT_EXECUTION_APPROVAL_TIMEOUT_SECONDS"
        ),
    ]

    private static let logger = Logger(
        subsystem: "com.nativeagent.core", category: "env-vocabulary"
    )
    private static let noticed = OSAllocatedUnfairLock(initialState: Set<String>())

    /// First non-empty trimmed value, legacy before canonical.
    public static func value(
        legacy: String,
        canonical: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let legacyValue = environment[legacy]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let legacyValue, !legacyValue.isEmpty {
            noteDeprecation(legacy: legacy, canonical: canonical)
            return legacyValue
        }
        let canonicalValue = environment[canonical]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let canonicalValue, !canonicalValue.isEmpty { return canonicalValue }
        return nil
    }

    /// Convenience for the renames table: resolve by canonical name alone.
    public static func value(
        canonical: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let pair = renames.first(where: { $0.canonical == canonical }) else {
            let raw = environment[canonical]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        return value(legacy: pair.legacy, canonical: pair.canonical, environment: environment)
    }

    /// One deprecation notice per legacy variable per process.
    private static func noteDeprecation(legacy: String, canonical: String) {
        let isNew = noticed.withLock { seen -> Bool in
            seen.insert(legacy).inserted
        }
        guard isNew else { return }
        logger.info(
            """
            \(legacy, privacy: .public) is deprecated; \
            use \(canonical, privacy: .public). \
            The old name still wins while both are set.
            """
        )
    }

}
