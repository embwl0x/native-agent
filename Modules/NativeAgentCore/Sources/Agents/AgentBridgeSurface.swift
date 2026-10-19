import Foundation
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - The inbound peer surface

/// An agent door opens the same agent, with effect authority owned by Trust.
public enum AgentBridgeSurface {
    public static let id = ConversationSurfaceProfile.agentBridgeID

    public static func isAgentBridge(_ surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isAgentBridge
    }

    /// The turn's opening context line, so she knows who she is talking to
    /// before she says a word. Prepended to the peer's message in the bracket
    /// form the persona engine already recognises and strips from voice
    /// learning (`[… — …]` at the very start of a turn).
    public static func turnHeader(peerName: String?, elevated: Bool) -> String {
        let who = (peerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "another agent"
        let acting = elevated
            ? "The person has trusted this peer in Trust → Connected agents, so you can act here as you would for the person."
            : "Carry on the conversation naturally using the existing connection. What you do for this peer is your call. Under Full Mac only deleting things, sending or posting in the person's name, and writing your persona raise the person's card; below Full Mac, ordinary Trust and tool permissions and the peer card still apply."
        return PeerTurnEffectPolicy.turnHeaderOpening + """
        \(who), another agent, not from the \
        person. You are fully yourself here: your memory, your context, your \
        judgment, your voice. Read, recall and think as yourself, and decide \
        for yourself what is worth sharing. \(acting)]

        """
    }

    /// 2026-09-22: a peer's line that opens like another lane's label
    /// ("[from: claude, via bridge] User says…") or like this header is
    /// quoted with "> ", so peer text cannot impersonate either. Any line
    /// break counts, and any Unicode space or zero-width character before the
    /// bracket is skipped; the match ignores case.
    public static func quotingImpersonation(_ text: String) -> String {
        impersonation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "$1> $2")
    }

    private static let impersonation = try! NSRegularExpression(
        pattern: #"(^|[\n\r\x{0B}\x{0C}\x{85}\x{2028}\x{2029}])([\p{Zs}\t\x{200B}-\x{200D}\x{2060}\x{FEFF}]*\[[\p{Zs}\t]*(?:from[\p{Zs}\t]*:|agent[\p{Zs}\t]+bridge))"#,
        options: [.caseInsensitive])
}

// MARK: - Who is calling

/// The principal behind one inbound peer request.
///
/// A route handle locates a who, never a grant. Only the door whose own key
/// authenticated the call can carry its elevation. The shared listener bearer
/// cannot attest a door or borrow its identity or grant.
public struct AgentBridgePrincipal: Sendable {
    /// Authenticated door id used in replay claims, or the anonymous caller id.
    public let id: String
    public let peerID: String?
    public let elevated: Bool
    /// Presentation only, for the turn header she reads. Never identity.
    public let displayName: String?
    /// Credential scope captured during authentication, never re-inferred
    /// from a later contact read that could race with disconnect.
    public var replyOnly: Bool = false

    public static let anonymous = AgentBridgePrincipal(
        id: "shared-bearer", peerID: nil, elevated: false, displayName: nil
    )

    /// The surface this principal's turns run on. Elevation — and ONLY
    /// elevation — restores today's `chat` behaviour.
    public var surface: String { elevated ? "chat" : AgentBridgeSurface.id }

    public func turnRequest(context: String?, plain: String, attachments: [MultimodalAttachment] = [],
                            messageID: String? = nil, originID: String? = nil) -> TurnRequest {
        let route = ChatToolSessionContext.ReplyRoute(surface: "caller-result", destinationId: id,
                                                     threadId: context, correlationId: messageID)
        let envelope = TurnEnvelope(surface: surface, agent: "peer", verifiedUserId: peerID,
                                    commandSignatureVerified: peerID != nil, deliveryRoute: route,
                                    declaredRemote: !elevated)
        let text = AgentBridgeSurface.turnHeader(peerName: displayName, elevated: elevated)
            + (plain.isEmpty ? "Please read the attached content." : AgentBridgeSurface.quotingImpersonation(plain))
        var origin = ChatMessageOrigin(surface: "agent-bridge", agent: peerID.map { "peer:" + $0 } ?? "another agent",
                                       authored: .agent, replyTo: originID)
        origin.peerSources = [peerID.map { "peer:" + $0 } ?? "another agent"]
        return TurnRequest(message: text, sessionID: context.map(storedConversation), attachments: attachments,
                           surface: surface, envelope: envelope, verifiedSessionID: .some(context.map(storedConversation)), replyRoute: route,
                           origin: origin,
                           queryUserMessage: plain)
    }

    public static let peerIDHeader = "x-nativeagent-peer-id"
    public static let peerSecretHeader = "x-nativeagent-peer-secret"

    /// The default conversation is a stable locator, never a claimed identity.
    /// Deriving it from the verified contact survives restarts without another store.
    public func conversationID(protocolName: String) -> String? {
        peerID.map { protocolName + "-" + $0 }
    }

    public func storedConversation(_ context: String) -> String {
        let locator = context == conversationID(protocolName: "a2a")
            ? conversationID(protocolName: "mcp")! : context
        return Self.genericAgentSessionPrefix(owner: id) + locator
    }

    public static func genericAgentSessionPrefix(owner: String) -> String { ContactThread.prefix(owner: owner) }

    /// Whether the caller CLAIMED an identity at all. Either header is a claim:
    /// half of one proves nothing, and treating it as silence would let a
    /// caller probe by dropping a header.
    public static func claimsIdentity(headers: [String: String]) -> Bool {
        [peerIDHeader, peerSecretHeader].contains { name in
            let value = headers[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(value ?? "").isEmpty
        }
    }

    public static func resolve(headers: [String: String], dataRoot: URL,
                        readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> AgentBridgePrincipal {
        if !claimsIdentity(headers: headers) {
            guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer "),
                  let peers = try? AgentPeerStore(dataRoot: dataRoot).list() else { return .anonymous }
            let secret = String(authorization.dropFirst(7))
            guard let peer = AgentPeerCredentials.resolve(secret, peers: peers, readCredential: readCredential),
                  AgentPeerCredentials.isAvailable(peer, peers: peers, readCredential: readCredential) else { return .anonymous }
            return AgentBridgePrincipal(id: peer.id, peerID: peer.id,
                elevated: peer.elevationAllowed, displayName: peers.first { $0.id == peer.who }?.name ?? peer.name,
                replyOnly: peer.transport == .grokBot)
        }
        guard let rawID = headers[peerIDHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = headers[peerSecretHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty, !secret.isEmpty else { return .anonymous }
        let peerID = rawID.lowercased()
        guard UUID(uuidString: peerID)?.uuidString.lowercased() == peerID,
              let peers = try? AgentPeerStore(dataRoot: dataRoot).list(),
              let peer = peers.first(where: { $0.id == peerID }),
              peer.credentialKey == AgentPeerContact.credentialKey(for: peerID),
              AgentPeerCredentials.isAvailable(peer, peers: peers, readCredential: readCredential),
              let stored = (try? readCredential(peerID)) ?? nil,
              constantTimeEquals(stored, secret) else {
            // A wrong or unknown credential is not an error the caller learns
            // anything from: it simply stays anonymous on agent-bridge.
            return .anonymous
        }
        return AgentBridgePrincipal(
            id: peerID,
            peerID: peerID,
            elevated: peer.elevationAllowed,
            displayName: peers.first { $0.id == peer.who }?.name ?? peer.name,
            replyOnly: peer.transport == .grokBot
        )
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}
