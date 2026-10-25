// The Trust Center / Setup memory switches, read at the point of use.
//
// The 2026-09-04 settings audit found six memoryPolicy keys
// round-tripped to <dataRoot>/trust/policy.json and nothing in the runtime ever
// read them. This is the one reader every gate goes through.
//
// FRESH ON EVERY CALL, deliberately. There is no launch-time snapshot and no
// cache: a flip in Setup or Trust Center is written atomically to policy.json
// and the next turn / next run reads the new value. The file is small and the
// call sites are per-turn or rarer, so the read costs nothing that matters.
//
// Defaults match SwiftNativeTrustCenter's DEFAULT_TRUST_POLICY["memoryPolicy"]
// (TrustCenter+Defaults.swift) so an absent key behaves exactly as the Settings
// card shows it — the gate and the switch can never disagree about "unset".
//
// It lives in MemoryV2 rather than TrustCenter because MemoryV2 is the module
// every consumer already depends on (ChatOrchestration and the app target both
// import it).

import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate` enum; `isEnabled`, `knowledgeGraphEnabled` |

public enum MemoryPolicyGate {

    /// One boolean out of `memoryPolicy` in the saved trust policy. Missing
    /// file, missing block or missing key → `fallback`; unavailable, malformed
    /// or otherwise damaged saved authority → false.
    ///
    /// 2026-09-13: this validated only the memoryPolicy block, so a policy
    /// TrustCenter rejects WHOLE — `{"securityPolicy": false}` — closed
    /// canonical trust while every memory feature still read as on (and the
    /// startup KG backfill ran). It now goes through the shared
    /// `SavedTrustPolicyAuthority` predicate, the same one TrustCenter's own
    /// shape validation and the dream gate use, so damage anywhere in the
    /// saved policy fails closed here too.
    public static func isEnabled(
        _ key: String,
        default fallback: Bool,
        dataRoot: URL? = nil
    ) -> Bool {
        SavedTrustPolicyAuthority.flag(
            block: "memoryPolicy",
            key: key,
            default: fallback,
            dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()
        )
    }

    /// Settings ▸ "Knowledge graph".
    public static func knowledgeGraphEnabled(dataRoot: URL? = nil) -> Bool {
        knowledgeGraphFailure(dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()) == nil
    }

    /// The checked authority distinguishes a person's switch from damaged Trust.
    public static func knowledgeGraphFailure(dataRoot: URL) -> ToolFailureError? {
        let authority = SavedTrustPolicyAuthority.read(dataRoot: dataRoot)
        if case .damaged = authority {
            return ToolFailureError(
                "Knowledge graph authority is unavailable: the saved Trust policy is unreadable or invalid.",
                effects: .none, owner: "Trust policy",
                nextCall: ToolFailureError.call("app", ["action": .string("doctor.run")]),
                code: "memory_trust_unavailable",
                instruction: "Repair the saved Trust policy, preserving its original bytes; enabling the graph cannot repair it.")
        }
        // Match TrustCenter+Defaults for absent policy, block or key.
        if authority.flag(block: "memoryPolicy", key: "knowledge_graph_enabled", default: true) { return nil }
        return ToolFailureError(knowledgeGraphOffMessage, effects: .none,
            owner: "Knowledge graph", tap: "Trust ▸ Living Memory ▸ Knowledge graph", personDecides: true,
            code: "knowledge_graph_disabled", status: .refused,
            instruction: "Ask the person to enable Knowledge graph.")
    }

    /// Settings ▸ "Remember across conversations".
    public static func crossSessionRecallEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("cross_session_recall", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Nightly memory consolidation" (the weekly card).
    public static func consolidationEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("consolidation_enabled", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Recurring memories are proposed as facts" (review required).
    public static func adaptivePromotionEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("adaptive_promotion", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Memory hygiene".
    public static func hygieneEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("hygiene_enabled", default: true, dataRoot: dataRoot)
    }

    /// The one sentence every knowledge-graph surface says when the switch is
    /// off, so the tools, the rebuild and any future reader cannot drift.
    public static let knowledgeGraphOffMessage =
        "The knowledge graph is off. Enable Trust ▸ Living Memory ▸ Knowledge graph to build or read it."
}
