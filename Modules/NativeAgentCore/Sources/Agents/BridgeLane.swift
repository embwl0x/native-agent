import Foundation
import ChatOrchestration

/// The bridge's message lanes: who composed the words each lane carries, and
/// the surface its rows record as their origin. The bridge's own routes and a
/// delegate's notice on its behalf read the same table.
public enum BridgeLane {
    public static let claudeSurfaceName = "claude-bridge"
    public static let codexSurfaceName = "codex-bridge"

    /// Item 8 (2026-09-02) — LANE → AUTHORSHIP. Who composed the words that
    /// arrive on each message route, stated per lane rather than assumed once
    /// for the whole bridge.
    ///
    /// This is a trust input: `.agent` is what lets the affect layer treat a
    /// message as another person moving her instead of as User
    /// (`CognitiveSubstrate.relationalSource`). Getting it wrong in the
    /// permissive direction means Claude relaying "User says: ship it" is felt
    /// as Claude; in the conservative direction it means a peer is felt as
    /// him. So it is a table, and adding a route means answering the question.
    ///
    /// This bridge has four message routes — `/agent/message`,
    /// `/claude/message`, `/codex/message`, `/omp/message` — and every one of
    /// them is an AGENT lane by construction. `handleMessage` takes its sender
    /// from the ROUTE (`let sender = defaultSender`, never from the request
    /// body), the caller is the agent process itself, and the in-band text it
    /// writes is `[from: <sender>, via bridge]`. There is no route on this
    /// bridge that carries forwarded human text: `/…/tool`, `/…/state`,
    /// `/…/events` and `/…/organism/debug` write no transcript rows at all.
    ///
    /// If such a route is ever added — a relay endpoint, an SMS or email
    /// gateway, anything where the human is upstream of the agent — it belongs
    /// here as `.human`, or absent (which reads as the human anyway). Do not
    /// let it fall through to the default.
    private static let laneAuthorship: [String: ChatMessageAuthorship] = [
        "claude": .agent,
        "codex": .agent,
        "omp": .agent,
        "agent": .agent,
    ]

    /// Authorship for a message lane. An unlisted sender is UNSTATED, not
    /// agent-authored: a new route must claim peer standing on purpose, and
    /// failing closed here means the worst case is a peer felt as User rather
    /// than User felt as a peer.
    public static func laneAuthorship(forSender sender: String) -> ChatMessageAuthorship? {
        laneAuthorship[sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// 658.14: map a bridge sender to the surface recorded as message origin.
    /// Every lane gets a distinct, truthful string — including lanes added
    /// after this was written, which is why the fallback derives from the
    /// sender instead of defaulting to any named agent.
    public static func bridgeSurfaceName(forSender sender: String) -> String {
        switch sender {
        case "claude": return claudeSurfaceName
        case "codex": return codexSurfaceName
        default:
            let cleaned = sender
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return cleaned.isEmpty ? "bridge" : "\(cleaned)-bridge"
        }
    }
}
