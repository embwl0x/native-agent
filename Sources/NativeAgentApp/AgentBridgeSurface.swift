import Foundation
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - The inbound peer surface

/// A REMOTE PEER IS NEVER THE PERSON — BUT SHE IS ALWAYS HERSELF.
///
/// `/agent/mcp`, `/a2a` and `/agent/message` accept messages from other
/// agents. Those turns used to run as surface "chat" — the Mac operator's own
/// surface, which `SecurityCenter+FullMacPolicy` treats as local and Full
/// Mac/YOLO opens completely. The bridge bearer does not attest the caller
/// (see the note at ClaudeBridge.route), so "authenticated" there means only
/// "reached this port". `agent-bridge` is that lane's own surface: declared
/// remote, absent from the Full Mac local AND trusted-remote sets. Claude's
/// own bridge lane (`/claude/message`) keeps `claude-bridge` and today's
/// authority exactly.
///
/// What that surface is NOT, since User's ruling of 2026-09-15, is a smaller
/// agent. The first cut of this file answered the risk with a six-tool
/// allowlist, and the price was the wrong one: a peer met an Agent with no
/// memory, no history, no persona kernel and nothing to say. "Anybody that
/// connects gets the WHOLE Agent — her memories, fluid context, her
/// personality, everything that makes her Agent."
///
/// So there is no tool fence here any more. Her full tool set loads, and the
/// fence moved to the one place it belongs: an EFFECT asked for by a peer
/// raises the person's ordinary permission card instead of running, with the
/// peer named as the requester (`PeerTurnEffectPolicy`, applied in
/// `AutonomyGatedDispatcher`). Her own behaviour is the rest of the safety —
/// when another agent asks her for something destructive, she comes to the
/// person and asks.
enum AgentBridgeSurface {
    static let id = ConversationSurfaceProfile.agentBridgeID

    static func isAgentBridge(_ surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isAgentBridge
    }

    /// The turn's opening context line, so she knows who she is talking to
    /// before she says a word. Prepended to the peer's message in the bracket
    /// form the persona engine already recognises and strips from voice
    /// learning (`[… — …]` at the very start of a turn).
    static func turnHeader(peerName: String?, elevated: Bool) -> String {
        let who = (peerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "another agent"
        let acting = elevated
            ? "The person has trusted this peer in Trust → Connected agents, so you can act here as you would for the person."
            : "Acting — writing, changing settings, running anything on this Mac, sending anything outward — raises a permission card to the person first; tell the peer you have asked."
        return PeerTurnEffectPolicy.turnHeaderOpening + """
        \(who), another agent, not from the \
        person. You are fully yourself here: your memory, your context, your \
        judgment, your voice. Read, recall and think as yourself, and decide \
        for yourself what is worth sharing. \(acting)]

        """
    }
}

// MARK: - Who is calling

/// The principal behind one inbound peer request.
///
/// The bridge bearer is a TRANSPORT credential shared by every route; it says
/// the caller reached the port, never who it is. A peer therefore earns an
/// identity only by presenting its OWN scoped credential — the per-peer secret
/// in `AgentPeerCredentials`, which `agent_connect` already mints — and earns
/// authority only when the person has also turned that peer's elevation on in
/// Trust Center. Either half missing means `agent-bridge`.
struct AgentBridgePrincipal: Sendable {
    /// Stable id used in the replay claim key. "shared-bearer" when the caller
    /// presented nothing but the transport credential.
    let id: String
    let peerID: String?
    let elevated: Bool
    /// Presentation only, for the turn header she reads. Never identity.
    let displayName: String?

    static let anonymous = AgentBridgePrincipal(
        id: "shared-bearer", peerID: nil, elevated: false, displayName: nil
    )

    /// The surface this principal's turns run on. Elevation — and ONLY
    /// elevation — restores today's `chat` behaviour.
    var surface: String { elevated ? "chat" : AgentBridgeSurface.id }

    static let peerIDHeader = "x-nativeagent-peer-id"
    static let peerSecretHeader = "x-nativeagent-peer-secret"

    static func resolve(headers: [String: String], dataRoot: URL) -> AgentBridgePrincipal {
        guard let rawID = headers[peerIDHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = headers[peerSecretHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty, !secret.isEmpty else { return .anonymous }
        let peerID = rawID.lowercased()
        guard UUID(uuidString: peerID)?.uuidString.lowercased() == peerID,
              let peer = try? AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peerID }),
              let stored = (try? AgentPeerCredentials.read(peerID: peerID)) ?? nil,
              constantTimeEquals(stored, secret) else {
            // A wrong or unknown credential is not an error the caller learns
            // anything from: it simply stays anonymous on agent-bridge.
            return .anonymous
        }
        return AgentBridgePrincipal(
            id: peerID,
            peerID: peerID,
            elevated: peer.elevationAllowed,
            displayName: peer.name
        )
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}
