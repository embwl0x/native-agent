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

    /// Every spelling that has ever named the Workshop surface in a GATE
    /// allowlist, canonical first.
    ///
    /// Wider than `bothSpellings` by the SINGULAR `mission`: the autonomy /
    /// full-mac / tool-loop gates were open-coded as
    /// `case "workshop", "mission", "missions"` and a turn can still arrive on
    /// either 0.3.x spelling. `canonicalSurface` deliberately does NOT fold
    /// `mission` — it is not a config-map key and folding it there would change
    /// routing/`active.json` lookups that never wrote it. Gates are the only
    /// lane that accepted the singular, so the extra spelling lives here.
    public static let gateSpellings: [String] = [canonical, legacy, "mission"]

    /// True when `value` names the Workshop surface in ANY gate spelling
    /// (canonical, legacy plural, legacy singular). Behavior-identical
    /// replacement for the open-coded `case "workshop", "mission", "missions"`.
    public static func isWorkshopGateSurface(_ value: String) -> Bool {
        gateSpellings.contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
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

/// P2-2: the execution-id key inside a Workshop-step approval `payload`.
///
/// The stager WRITES `canonicalExecutionIdKey` only. Readers resolve through
/// `executionId(_:)`, which walks `executionIdKeys` canonical-first and falls
/// back to the legacy spelling. The fallback is PERMANENT: approvals staged by
/// a 0.3.x binary live in `workflows/approvals/requests.json` (7 such rows on
/// the live install), that file is never rewritten, and a miss here is not an
/// error — it is a silently dead approval lane (a duplicate card from the
/// stager, or a resolved step that never executes).
///
/// Kept free of `JSONValue` so it can live beside the rest of the wire
/// vocabulary in dependency-free `NativeAgentCore`; callers pass a lookup that
/// unwraps their own representation.
public enum WorkshopStepApprovalPayload {
    /// The only key any writer may emit.
    public static let canonicalExecutionIdKey = "execution_id"
    /// Accepted keys, in resolution order: canonical first, legacy fallback.
    public static let executionIdKeys = [canonicalExecutionIdKey, "mission_id"]

    /// First non-empty value among `executionIdKeys`, or nil when the payload
    /// carries neither key (absent is not a crash — the caller reports it).
    public static func executionId(_ lookup: (String) -> String?) -> String? {
        for key in executionIdKeys {
            if let value = lookup(key), !value.isEmpty { return value }
        }
        return nil
    }
}

/// The TriggerScheduler trigger that fires when a Workshop execution finishes:
/// row `name` + row `kind` + the `<kind>:<id>` inbox-card source prefix.
public enum WorkshopCompletionTrigger {
    public static let canonicalName = "execution_followup"
    public static let legacyName = "mission_followup"
    public static let canonicalKind = "execution_complete"
    public static let legacyKind = "mission_complete"
}

// MARK: - Wave 4: cross-device keys, READ-BOTH ONLY (phase A)

// The three keys below travel BETWEEN the Mac and a 0.3.7 iOS install. Phase A
// widens the readers ONLY: every writer on both ends keeps emitting the legacy
// spelling, so the wire stays byte-identical in both directions while old and
// new builds are in the field at the same time. Phase B (a later wave, gated on
// the iOS floor) flips the writers.
//
// Anything here with `wireKey` in the name is what is still WRITTEN. `futureKey`
// is accepted on read and emitted by nobody yet — if you find yourself writing a
// `futureKey`, you are in the wrong phase.

/// The Workshop policy block inside `trust/policy.json` and the iOS/Mac
/// `TrustPolicy` model: `missionPolicy` on the wire, `workshopPolicy` later.
public enum WorkshopPolicyBlockVocabulary {
    /// Still written by every writer (defaults, fail-closed, trust patches).
    public static let wireKey = "missionPolicy"
    /// Accepted on read; emitted by nobody in phase A.
    public static let futureKey = "workshopPolicy"
    /// Both spellings, future first — matching decoder resolution order.
    public static let bothSpellings: [String] = [futureKey, wireKey]

    /// Read the policy block under either spelling, future-first.
    public static func block<V>(_ policy: [String: V]) -> V? {
        policy[futureKey] ?? policy[wireKey]
    }

    /// Fold a future-spelled block onto the WIRE key at the read seam, so every
    /// downstream merge/gate keeps reading exactly one key. Future wins when
    /// both are present, matching `block(_:)` and the Codable decoders.
    public static func foldToWireKey<V>(_ policy: [String: V]) -> [String: V] {
        guard let future = policy[futureKey] else { return policy }
        var out = policy
        out.removeValue(forKey: futureKey)
        out[wireKey] = future
        return out
    }
}

/// The inbox card's linked-execution field in `items.jsonl` and the iCloud
/// inbox snapshot both devices decode.
public enum InboxExecutionLinkVocabulary {
    /// Still written by every writer (card emitters, `toJSONValue`, encoders).
    public static let wireKey = "related_mission_id"
    /// Accepted on read; emitted by nobody in phase A.
    public static let futureKey = "related_execution_id"
    public static let bothSpellings: [String] = [futureKey, wireKey]
}

/// The execution id inside an `InboxAction` payload (iOS -> Mac approve/reject).
/// RAW string keys on both ends — no Codable, no CodingKeys.
public enum InboxActionExecutionIdVocabulary {
    /// Still written by the iOS sender and the Mac's submit response.
    public static let wireKey = "missionId"
    /// Accepted on read; emitted by nobody in phase A.
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

/// P2-6 residue: the notification action identifier for "open the execution".
/// Wave 5 flips the EMITTER to the canonical spelling; readers accept both
/// because a 0.3.x payload (or a notification already queued in Notification
/// Center) still carries the legacy id.
public enum WorkshopOpenNotificationAction {
    public static let canonical = "open_execution"
    public static let legacy = "open_mission"
    public static let bothSpellings: [String] = [canonical, legacy]

    /// True when `value` is the open-execution action in EITHER spelling.
    public static func matches(_ value: String) -> Bool {
        bothSpellings.contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// P2-6 residue: the Apple Shortcuts connector's "start an execution" action
/// name. `data/connectors/registry.json` is LIVE persisted data carrying
/// `start_mission`; nothing rewrites it, so any reader that matches this action
/// must accept both spellings.
public enum WorkshopStartConnectorAction {
    public static let canonical = "start_execution"
    public static let legacy = "start_mission"
    public static let bothSpellings: [String] = [canonical, legacy]

    /// Fold either spelling onto the canonical one; every other action name
    /// passes through with only whitespace trimmed (these are wire tokens).
    public static func canonicalAction(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == legacy ? canonical : trimmed
    }

    /// Equality that tolerates either side being written in either vocabulary.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonicalAction(lhs) == canonicalAction(rhs)
    }
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
