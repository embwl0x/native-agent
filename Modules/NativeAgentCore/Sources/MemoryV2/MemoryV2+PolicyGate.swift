// The Trust Center / Setup memory switches, read at the point of use.
//
// Audit docs/audits/settings-audit-2026-09-04-memory.md: six memoryPolicy keys
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
// import it) and MemoryV2 does not depend on TrustCenter.

import Foundation
import PersistenceCore
import TrustCenter

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
        // TrustCenter+Defaults ships memoryPolicy.knowledge_graph_enabled TRUE.
        // This said false, so on a fresh root — where the key is simply absent —
        // the graph was off while Trust Center and Setup both showed it on.
        isEnabled("knowledge_graph_enabled", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Remember across conversations".
    public static func crossSessionRecallEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("cross_session_recall", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Nightly memory consolidation" (the weekly card).
    public static func consolidationEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("consolidation_enabled", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Memories that recur become facts".
    public static func adaptivePromotionEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("adaptive_promotion", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Keep consolidated memories without asking".
    public static func autoPromoteConsolidatedEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("auto_promote_consolidated", default: true, dataRoot: dataRoot)
    }

    /// Settings ▸ "Memory hygiene".
    public static func hygieneEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("hygiene_enabled", default: true, dataRoot: dataRoot)
    }

    /// The one sentence every knowledge-graph surface says when the switch is
    /// off, so the tools, the rebuild and any future reader cannot drift.
    public static let knowledgeGraphOffMessage =
        "The knowledge graph is off. Turn it on in Settings ▸ Memory to build or read it."
}
