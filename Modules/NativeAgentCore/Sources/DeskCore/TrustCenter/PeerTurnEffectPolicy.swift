import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PeerTurnEffectPolicy.swift` | Untrusted peer effects ask; memory retains provenance. |

/// Peer sessions keep ordinary agent context, but untrusted peer-steered effects require the person's decision.
public enum PeerTurnEffectPolicy {
    /// The declared contract, not a name or argument reading: a peer-steered call that is not a read needs the person, except the agent's own
    /// words to its own person (`voice`), which no one's steering turns into the person's approval.
    public static func requiresPeerApproval(
        _ tool: String,
        input: [String: JSONValue] = [:],
        turn: Turn?
    ) throws -> Bool {
        // A folded door action is a read here: it re-enters under its own tool and is judged there.
        try PermissionLaw.toolClass(tool, input: input, turn: turn) != .read && !PermissionLaw.voice(tool: tool, input: input, turn: turn)
    }

    public static func normalized(_ tool: String) -> String {
        tool.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
    }

    /// Share the transport's header marker so writer and reader cannot drift.
    public static let turnHeaderOpening = "[Agent bridge — this turn came from "
    /// Content after the contact record. The caller decides whether this is a persisted bridge turn.
    public static func contactMessage(in text: String) -> String? {
        guard let contact = text.range(of: "\n[Contact: "),
              let end = text.range(of: "]\n", range: contact.upperBound..<text.endIndex) else { return nil }
        return String(text[end.upperBound...])
    }
    private static let turnHeaderPeerSuffix = ", another agent"

    /// Session titles name the peer instead of exposing its transport header.
    public static func peerName(inTurnHeader text: String) -> String? {
        let head = String(text.prefix(240))
        guard head.hasPrefix(turnHeaderOpening) else { return nil }
        let rest = head.dropFirst(turnHeaderOpening.count)
        guard let suffix = rest.range(of: turnHeaderPeerSuffix) else { return nil }
        let name = rest[rest.startIndex..<suffix.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public static func isPeerBridge(surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isAgentBridge
    }

    /// Attribute bridge turns and continuations without adding peer framing to the person's own sessions. Callers supply taint from the higher-level runtime
    /// and the contact name resolved from Trust.
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

    /// Name the requester so the person decides about a known peer rather than a bare call.
    public static func approvalReason(requester: String) -> String {
        let who = requester.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(who.isEmpty ? "Another agent" : who) is not a trusted agent, so this waits for you."
    }

    /// The floor's card names the peer, quotes its request and states the call's declared class.
    public static func floorReason(tool: String, input: [String: JSONValue] = [:],
                                   requester: String, quote: String, turn: Turn?) throws -> String {
        let who = requester.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = quote.isEmpty ? "" : " It said: \"\(quote)\"."
        let ran = ToolNameAliases.ranCall(tool, input: input)
        let kind = switch try PermissionLaw.toolClass(ran.tool, input: ran.input, turn: turn) {
        case .send: "a send"
        case .destructive: "a delete or something that can't be undone"
        case .read, .write: "a change"
        }
        return "\(who.isEmpty ? "Another agent" : who) is not a trusted agent and is steering this.\(said) "
            + "This is \(kind), so it waits for you."
    }

    /// Peer identity comes from the verified transport credential and contact record, never message text.
    public struct PeerIdentity: Sendable, Equatable {
        public let id: String?
        public let name: String?

        public init(id: String? = nil, name: String? = nil) {
            self.id = id
            self.name = name
        }

        fileprivate func matches(_ by: String) -> Bool {
            guard let id, !id.isEmpty else { return false }
            if by.hasPrefix("peer:") { return by == "peer:" + id.lowercased() }
            return by == id.lowercased() || by == name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    public static func judgesProvenance(tool: String, input: [String: JSONValue]) -> Bool {
        ["commit_memory", "rewrite_memory"].contains(normalized(ToolNameAliases.ranCall(tool, input: input).tool))
    }

    public static func memoryTellers(
        tool: String, input: [String: JSONValue], peers: [PeerIdentity], readPeerData: Bool, rewriteChangesText: Bool? = nil
    ) throws(ToolFailureError) -> [String]? {
        let ran = ToolNameAliases.ranCall(tool, input: input)
        let action = normalized(ran.tool)
        guard action == "commit_memory" || action == "rewrite_memory" else { return nil }
        let hasRoots = ran.input["roots"] != nil && ran.input["roots"] != .null
        let simple = action == "commit_memory" && !hasRoots
        let rewriteText = action == "rewrite_memory" && (rewriteChangesText ?? (ran.input["text"]?.trimmedString != nil))
        guard (action == "commit_memory" && hasRoots) || (!peers.isEmpty && (simple || hasRoots || rewriteText)) else { return nil }

        func refusal(_ message: String, path: String) -> ToolFailureError {
            ToolFailureError(message, argumentPath: path, effects: .none, code: "memory_teller_steered", status: .refused,
                recovery: .correctArguments)
        }

        let roots: [JSONValue]
        if simple {
            roots = [.object(["how": ran.input["provenance"], "by": ran.input["provenance_by"], "since": ran.input["since"]]
                .compactMapValues { $0 })]
        } else {
            guard case .array(let listed)? = ran.input["roots"], !listed.isEmpty else {
                throw refusal("Use a nonempty roots list, with how and by for each root.", path: "args.roots")
            }
            if action == "commit_memory", ["provenance", "provenance_by", "since"].contains(where: {
                ran.input[$0] != nil && ran.input[$0] != .null
            }) {
                throw refusal("Use roots by itself, or use provenance, provenance_by and since.", path: "args.roots")
            }
            roots = listed
        }

        var tellers: [String] = []
        for (index, root) in roots.enumerated() {
            let path = simple ? "args.provenance_by" : "args.roots[\(index)]"
            let fields = root.objectValue
            let by = fields?["by"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let how = fields?["how"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let since = fields?["since"]
            if how == "told", since == nil || since == .null, let by, !by.isEmpty, by != "user", by != "self" {
                let matches = peers.filter { $0.matches(by) }
                if matches.count == 1, let id = matches.first?.id {
                    tellers.append("peer:" + id)
                    continue
                }
            }
            let choices = peers.compactMap { $0.id.map { "peer:" + $0 } }.joined(separator: ", ")
            let unattested = readPeerData ? "This Ask's sources attest no peer teller." : "The request's origin attests no peer teller."
            throw refusal(choices.isEmpty ? unattested
                : "State told without since and name one attested peer who told you (\(choices)).", path: path)
        }
        return tellers
    }
}
