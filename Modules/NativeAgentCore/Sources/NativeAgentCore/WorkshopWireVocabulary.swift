import Foundation
import os

// The de-mission wire bridges (Phase 2, items P2-3/P2-4/P2-5).
//
// Phase 1 removed every human-facing use of the word "mission". What is left
// is persisted/wire literals on 0.3.x installs that are still LIVE data. These
// three enums are the ONE place each lane translates between the old spelling
// and the new one. Every writer emits the new spelling; every reader routes
// through here so an old row, an old config file, or an old environment
// variable keeps working forever.
//
// Rules that hold for all three:
//   * Old bytes are historical records. Nothing here ever rewrites them.
//   * Canonicalization is one-directional (legacy -> canonical). Comparisons
//     canonicalize BOTH sides so mismatched-vocabulary pairs still match.
//   * No caller may open-code an `if x == "missions"` check. Add the case here.

// MARK: - P2-3: surface vocabulary

/// The Workshop/Executions *surface* identifier. Written as `missions` up to
/// 0.3.7 (routing `providers/surfaces.json` + `providers/active.json` keys,
/// MemoryV2 `permittedSurfaces` entries, `LLMClient.complete(surface:)`
/// arguments); written as `workshop` from here on.
public enum WorkshopSurfaceVocabulary {
    /// What every writer emits from now on.
    public static let canonical = "workshop"
    /// What 0.3.x installs already have on disk. Still read, never written.
    public static let legacy = "missions"

    /// Both spellings, canonical first. Disclosure allowlists carry both so a
    /// row written by either vocabulary is accepted by either reader.
    public static let bothSpellings: [String] = [canonical, legacy]

    /// Trim + lowercase, then fold the legacy spelling onto the canonical one.
    /// Every other surface passes through normalized but unchanged.
    public static func canonicalSurface(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == legacy ? canonical : normalized
    }

    /// Rewrite ONLY the legacy Workshop spelling; return every other surface
    /// byte-identical, case included.
    ///
    /// `canonicalSurface` lowercases as well, which is correct for routing and
    /// config-key lanes that already normalize. It is NOT correct at a general
    /// turn entry point, where the surface string is threaded through dozens of
    /// downstream comparisons — silently lowercasing an unrelated surface there
    /// would be a second, unrequested behavior change riding along with P2-3.
    public static func foldLegacySpelling(_ value: String) -> String {
        isWorkshopSurface(value) ? canonical : value
    }

    /// True when `value` names the Workshop surface in EITHER vocabulary.
    public static func isWorkshopSurface(_ value: String) -> Bool {
        canonicalSurface(value) == canonical
    }

    /// Fold a surface-keyed config map (`surfaces.json`, `active.json`) onto
    /// the canonical vocabulary at the READ seam. When a file carries both
    /// spellings — possible only if an older build wrote `missions` after a
    /// newer build wrote `workshop` — the canonical key wins deterministically,
    /// so the two never silently disagree about which model is pinned.
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

// MARK: - P2-4: execution event vocabulary

/// Event/record kind strings that carried the word "mission" on the wire:
/// ApprovalInbox `action`, TriggerScheduler trigger `kind` + `name`, inbox card
/// `source` prefixes, and step-outcome error codes. `timeline.jsonl`, receipts,
/// `inbox.jsonl` and `trigger_config.json` written before this change are
/// historical records — they are read through here and never rewritten.
public enum ExecutionEventVocabulary {
    /// legacy spelling -> canonical spelling. Order is longest-first so
    /// `mission_complete` is never partially matched by a shorter entry.
    public static let renames: [(legacy: String, canonical: String)] = [
        ("mission.step", "execution.step"),
        ("mission_complete", "execution_complete"),
        ("mission_followup", "execution_followup"),
        ("mission_cancelled", "execution_cancelled"),
    ]

    /// Fold a kind/action/name/source onto the canonical spelling.
    ///
    /// Handles the two shapes these strings appear in: a bare kind
    /// (`mission_complete`) and a prefixed source (`mission_complete:abc123`).
    /// Anything else passes through with only whitespace trimmed — case is
    /// preserved because these are exact wire tokens, not display text.
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

    /// Equality that tolerates either side being written in either vocabulary.
    /// Use this instead of `==` at every seam that compares a stored kind to an
    /// expected one — a 0.3.x row read by new code and a new row read by an
    /// old-shaped filter must both match.
    public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return canonicalKind(lhs) == canonicalKind(rhs)
    }

    /// `hasPrefix` that tolerates either vocabulary on either side. Used by the
    /// inbox `source` readers (`mission_complete:<id>` vs
    /// `execution_complete:<id>`).
    public static func hasKindPrefix(_ value: String, _ prefix: String) -> Bool {
        canonicalKind(value).hasPrefix(canonicalKind(prefix))
    }
}

/// The ApprovalInbox `action` (and payload `kind`) for a Workshop step that is
/// blocked waiting on User. Named separately from the rename table because it is
/// spelled out at half a dozen call sites and a typo there is a silently dead
/// approval lane, not a compile error.
public enum WorkshopStepApprovalAction {
    public static let canonical = "execution.step"
    public static let legacy = "mission.step"
}

/// The TriggerScheduler trigger that fires when a Workshop execution finishes:
/// row `name` + row `kind` + the `<kind>:<id>` inbox-card source prefix.
public enum WorkshopCompletionTrigger {
    public static let canonicalName = "execution_followup"
    public static let legacyName = "mission_followup"
    public static let canonicalKind = "execution_complete"
    public static let legacyKind = "mission_complete"
}

// MARK: - P2-5: environment variable vocabulary

/// Public env-var contract. The `..._MISSION[S]_...` spellings are documented
/// on 0.3.x installs and shipped in real launch agents, so they keep working
/// and — when both are set — they WIN. Reading one emits a single info-level
/// deprecation notice per process.
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

    /// Resolve one setting from either spelling.
    ///
    /// Precedence is deliberate and matches the design note: the LEGACY name
    /// wins when both are set, so an existing launch agent that pins
    /// `NATIVE_AGENT_MAX_ACTIVE_MISSIONS` is not silently overridden by a
    /// default-valued new name someone exported later. A non-empty legacy read
    /// logs one deprecation line naming the replacement.
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

    /// One line per legacy variable per process — never per read. A hot loop
    /// resolving a timeout must not turn a deprecation notice into log spam.
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

    /// Test seam: forget which deprecations were already logged.
    public static func _resetDeprecationNoticesForTesting() {
        noticed.withLock { $0.removeAll() }
    }
}
