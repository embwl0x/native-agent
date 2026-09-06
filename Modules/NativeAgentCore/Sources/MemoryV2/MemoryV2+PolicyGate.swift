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

public enum MemoryPolicyGate {

    /// One boolean out of `memoryPolicy` in the saved trust policy. Missing
    /// file, missing block, missing key or wrong type → `fallback`.
    public static func isEnabled(
        _ key: String,
        default fallback: Bool,
        dataRoot: URL? = nil
    ) -> Bool {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let path = root
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        // Missing file → defaults. A file that EXISTS but cannot be read is
        // not "unset"; it is unavailable, and that fails closed like a file
        // that does not parse (Codex review 2026-09-05).
        guard FileManager.default.fileExists(atPath: path.path) else { return fallback }
        guard let data = try? Data(contentsOf: path) else { return false }
        // A file that exists but does not parse is what TrustCenter treats as
        // fail-closed (every switch off); the gate agrees, so the runtime
        // never runs what the UI shows as off (reviewer, 2026-09-05).
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        // 2026-09-06: an ABSENT memoryPolicy block is "unset" → fallback, but a
        // block that is PRESENT and wrongly typed ("memoryPolicy": false) is a
        // policy TrustCenter rejects outright — TrustCenter+PolicyLoading's
        // failure projection renders all six switches OFF. Treating it like an
        // absent block returned each feature's fallback, so Trust showed memory
        // off while the gate ran it on.
        let presentBlock = top["memoryPolicy"]
        if presentBlock != nil, !(presentBlock is [String: Any]) { return false }
        guard let block = presentBlock as? [String: Any] else { return fallback }
        guard let raw = block[key] else { return fallback }
        // A key that is present but not a Bool ("false" as a string) is a
        // policy TrustCenter rejects; the gate refuses it too rather than
        // quietly running the default.
        guard let value = raw as? Bool else { return false }
        return value
    }

    /// Settings ▸ "Knowledge graph".
    public static func knowledgeGraphEnabled(dataRoot: URL? = nil) -> Bool {
        isEnabled("knowledge_graph_enabled", default: false, dataRoot: dataRoot)
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
