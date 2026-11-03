// The Trust Center / Setup memory switches, read at the point of use.
//
// Every memory gate reads memoryPolicy through this reader.
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
// Blueprint: | `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate` enum; checked throwing graph/recall/promotion flags and explicit knowledgeGraphFailure distinguish unavailable Trust from operator-disabled memory; unavailable graph authority never authorizes projection retirement |

public enum MemoryPolicyGate {

    /// One boolean out of `memoryPolicy` in the saved trust policy. Missing
    /// file, missing block or missing key → `fallback`; unavailable, malformed
    /// or otherwise damaged saved authority throws its owner failure.
    ///
    /// Shared `SavedTrustPolicyAuthority` validation fails closed on damage anywhere in the saved policy.
    public static func isEnabled(
        _ key: String,
        default fallback: Bool,
        dataRoot: URL? = nil
    ) throws -> Bool {
        try SavedTrustPolicyAuthority.flag(
            block: "memoryPolicy",
            key: key,
            default: fallback,
            dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()
        )
    }

    /// Settings ▸ "Knowledge graph".
    public static func knowledgeGraphEnabled(dataRoot: URL? = nil) throws -> Bool {
        try isEnabled("knowledge_graph_enabled", default: true, dataRoot: dataRoot)
    }

    /// The checked authority distinguishes a person's switch from damaged Trust.
    public static func knowledgeGraphFailure(dataRoot: URL) -> ToolFailureError? {
        let authority = SavedTrustPolicyAuthority.read(dataRoot: dataRoot)
        // Match TrustCenter+Defaults for absent policy, block or key.
        do {
            if try authority.flag(block: "memoryPolicy", key: "knowledge_graph_enabled", default: true) { return nil }
        } catch let failure as ToolFailureError { return failure }
        catch { return SavedTrustPolicyAuthority.unavailable(error.localizedDescription) }
        return ToolFailureError(knowledgeGraphOffMessage, effects: .none,
            owner: "Knowledge graph", tap: "Trust ▸ Living Memory ▸ Knowledge graph", personDecides: true,
            code: "knowledge_graph_disabled", status: .refused,
            instruction: "Ask the person to enable Knowledge graph.")
    }

    /// Settings ▸ "Remember across conversations".
    public static func crossSessionRecallEnabled(dataRoot: URL? = nil) throws -> Bool {
        try isEnabled("cross_session_recall", default: true, dataRoot: dataRoot)
    }

    /// Trusted facts are accepted immediately; untrusted facts wait for review.
    public static func adaptivePromotionEnabled(dataRoot: URL? = nil) throws -> Bool {
        try isEnabled("adaptive_promotion", default: true, dataRoot: dataRoot)
    }

    /// The one sentence every knowledge-graph surface says when the switch is
    /// off, so the tools, the rebuild and any future reader cannot drift.
    public static let knowledgeGraphOffMessage =
        "The knowledge graph is off. Enable Trust ▸ Living Memory ▸ Knowledge graph to build or read it."
}
