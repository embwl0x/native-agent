import Foundation
import PersistenceCore
import ToolRegistry
// Blueprint: | `PeerTurnEffectPolicy.swift` | Peer-origin approval floors read only the declared call class; memory notes retain origin attribution without the former human-turn read-latch exception; ability changes/growth capture use CapabilityLifecycle's common write guard |

/// Peer sessions receive the ordinary full Agent context and tool policy.
/// What a peer the person has not trusted may do alone is read; every other
/// call it steers is the person's card, decided by the call's declared class.
public enum PeerTurnEffectPolicy {
    /// The declared contract, not a name or argument reading: a peer-steered
    /// call that is not a read needs the person.
    public static func requiresPeerApproval(
        _ tool: String,
        input: [String: JSONValue] = [:]
    ) -> Bool {
        // A folded door action is a read here: it re-enters under its own tool and is judged there.
        PermissionLaw.toolClass(tool, input: input) != .read
    }

    public static func normalized(_ tool: String) -> String {
        tool.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
    }

    /// The opening of the bridge turn header the transport prepends to a
    /// peer's message (`AgentBridgeSurface.turnHeader`). Shared with the
    /// reader below so writer and reader cannot drift.
    public static let turnHeaderOpening = "[Agent bridge — this turn came from "
    private static let turnHeaderPeerSuffix = ", another agent"

    /// The peer named in that header, or nil when this text is not one. Used
    /// to title the peer's session row with WHO rather than with sixty
    /// characters of the header itself.
    public static func peerName(inTurnHeader text: String) -> String? {
        let head = String(text.prefix(240))
        guard head.hasPrefix(turnHeaderOpening) else { return nil }
        let rest = head.dropFirst(turnHeaderOpening.count)
        guard let suffix = rest.range(of: turnHeaderPeerSuffix) else { return nil }
        let name = rest[rest.startIndex..<suffix.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Is this surface the peer bridge?
    public static func isPeerBridge(surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isAgentBridge
    }

    /// Who is asking, when the asker is not the person: an inbound peer turn
    /// on the bridge, or a continuation carrying that turn's origin.
    /// Nil on every other turn — which is what keeps all of this invisible to
    /// the person's own sessions.
    ///
    /// `taintSource` describes the untrusted origin steering this run, nil
    /// otherwise. Passed in rather than read here: the taint
    /// box lives in ChatTurnRuntime, which sits ABOVE this module.
    ///
    /// `peerName` is the contact name the person gave this peer in Trust →
    /// Connected agents, resolved from the peer directory by the caller. A
    /// UUID prefix told the person nothing about WHO was asking, so the name
    /// wins whenever the directory has one.
    public static func peerRequester(
        surface: String,
        peerID: String?,
        peerName: String? = nil,
        taintSource: String? = nil
    ) -> String? {
        if let taintSource, !taintSource.isEmpty { return taintSource }
        guard isPeerBridge(surface: surface) else { return nil }
        let name = peerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return "\(name) (another agent on the bridge)" }
        guard let peerID, !peerID.isEmpty else { return "another agent" }
        return "another agent (peer \(peerID.prefix(8)))"
    }

    /// The reason line the permission card carries. The peer is NAMED as the
    /// requester, so the person is deciding about a known asker rather than
    /// about a bare tool call.
    public static func approvalReason(tool: String, requester: String) -> String {
        let who = requester.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = who.isEmpty ? "another agent" : who
        return "\(name) asked for this on the agent bridge, not you. "
            + "\(tool) is not a read, so it waits for you."
    }

    /// The floor's card names the peer, quotes its request and states the call's declared class.
    public static func floorReason(tool: String, input: [String: JSONValue] = [:],
                                   requester: String, quote: String) -> String {
        let who = requester.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = quote.isEmpty ? "" : " It said: \"\(quote)\"."
        // Name the act itself: through the app door that is the action, not "app".
        var shown = tool
        if tool == "app", case .string(let action)? = input["action"] { shown = action }
        let ran = ToolNameAliases.ranCall(tool, input: input)
        let kind = switch PermissionLaw.toolClass(ran.tool, input: ran.input) {
        case .send: "a send"
        case .destructive: "a delete or something that can't be undone"
        case .read, .write: "a change"
        }
        return "This turn was steered by \(who.isEmpty ? "another agent" : who), not you.\(said) "
            + "\(shown) is \(kind), so it waits for you."
    }

    /// Peer identity comes from the verified transport credential and contact record, never message text.
    public struct PeerIdentity: Sendable, Equatable {
        public let id: String?
        public let name: String?

        public init(id: String? = nil, name: String? = nil) {
            self.id = id
            self.name = name
        }

        /// What she is told to write, and what the refusal calls the asker.
        public var display: String {
            for candidate in [name, id] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { return trimmed }
            }
            return "a peer"
        }

        /// The values `provenance_by` may carry for this peer. Empty when the
        /// transport could not attest anyone.
        var acceptedAttributions: [String] {
            [name, id]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
    }

    public static func provenanceRefusal(
        tool: String,
        input: [String: JSONValue],
        peer: PeerIdentity,
        readPeerData: Bool = false
    ) -> String? {
        let who = peer.display
        // Through the app door the save's own arguments sit under `args`.
        let ran = ToolNameAliases.ranCall(tool, input: input)
        guard normalized(ran.tool) == "commit_memory" else { return nil }
        // Peer-turn memory notes require provenance="told" and provenance_by naming the peer.
        let kind = string(ran.input["provenance"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard kind == "told" else {
            let origin = readPeerData ? "This turn read data from" : "The request came from"
            return "\(origin) \(who), a peer — you can keep your own "
                + "note about it, but a peer cannot speak for the person. Set "
                + "provenance=\"told\" and provenance_by=\"\(who)\", so the note "
                + "records what \(who) reported rather than established fact."
        }
        let by = string(ran.input["provenance_by"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !by.isEmpty else {
            return "Set provenance_by=\"\(who)\" — provenance=\"told\" without "
                + "who told you is the part that makes the note honest."
        }
        let accepted = peer.acceptedAttributions
        // Nothing attested: an honest attribution is the most this turn can
        // ask for, so any non-empty name passes rather than blocking her note.
        guard !accepted.isEmpty else { return nil }
        guard accepted.contains(by.lowercased()) else {
            let origin = readPeerData ? "This turn read data from" : "This turn came from"
            return "\(origin) \(who), so provenance_by has to be "
                + "\(who) — a peer cannot attribute its claim to someone else."
        }
        return nil
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }
}
