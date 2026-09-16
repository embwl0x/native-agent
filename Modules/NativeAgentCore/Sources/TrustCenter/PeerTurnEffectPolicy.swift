import Foundation
import PersistenceCore

/// WHAT A PEER MAY MAKE HER DO — one classification, two call sites.
///
/// User's ruling, 2026-09-15: "anybody that connects gets the WHOLE Agent — her
/// memories, fluid context, her personality, everything that makes her Agent.
/// I didn't want to kill off her personality for that bridge." A peer turn is
/// an ORDINARY session of hers: same context assembly, same memory, same
/// recall/history/read tools, her full tool set loaded. The fence is for
/// EFFECTS only, and it is not a refusal — an effect a peer asks for RAISES
/// THE ORDINARY PERMISSION CARD to the person, the same path a Trust-gated
/// action takes today, with the peer named as the requester. Her own
/// behaviour is the safety: she comes to the person and asks.
///
/// So this is a denylist by design, not by oversight. An allowlist is the
/// right shape for a fence around a stranger; it is the wrong shape here,
/// because anything it forgets is something she loses. What it must catch is
/// the small, stable set of verbs that CHANGE something — and a verb-token
/// rule catches tomorrow's tool the day it lands, as long as it is named like
/// every other tool in this dispatcher.
public enum PeerTurnEffectPolicy {
    /// Effect tools whose NAME does not carry an effect verb, so the token
    /// rule below cannot see them. Durable writes to her own mind, to the
    /// person's configuration, and to the outside world.
    static let effectTools: Set<String> = [
        // Her mind and the person's configuration.
        "persona_write", "persona_append_section", "save_skill",
        "rewrite_memory", "forget_memory", "rebuild_knowledge_graph",
        "hold_view", "release_view",
        "studio_canon_resolve", "bot_ask", "answer_card",
        "mac_calendar_modify_event", "mac_nudge",
        // Desk STATE transitions whose names carry no effect verb.
        "desk_blocked_on", "desk_breakdown",
        // Shell, builder and Mac verbs. Sol, 2026-09-15: `screen`, `wait`,
        // `menu`, `mac_look`, `mac_view` and `mac_attention` are registered
        // READ/PERCEPTION tools — looking at the screen changes nothing, and
        // gating them made her blind on a peer turn for no safety. Only the
        // verbs that MOVE the Mac stay.
        "shell", "bash", "git", "apply_patch", "run_tests",
        "swift_build", "swift_test", "act", "go", "mac_wake",
        // Outward sends and other agents.
        "agent_message", "claude_message", "codex_message", "omp_message",
        "invoke_claude", "invoke_codex", "agent_swarm",
        "mail_reply", "mail_archive", "github_mutate",
        // Defaults `persist: true` and REPLACES the durable tracking config,
        // so the name's "discover" reads like a probe and is not one.
        "github_discover_tracking", "github_project_digest",
        // Self-evolution.
        "self_install", "evolution_propose", "evolution_withdraw",
    ]

    /// Underscore-separated name tokens that mean "this call changes
    /// something". Matched as whole tokens, never substrings, so
    /// `app_settings_list` (tokens: app, settings, list) stays a read while
    /// `app_setting_set` (…, set) does not.
    static let effectVerbs: Set<String> = [
        "send", "post", "write", "create", "update", "delete", "remove", "add",
        "set", "act", "notify", "install", "uninstall", "execute", "submit",
        "control", "click", "type", "keystroke", "scroll", "drag", "fill",
        "press", "keypress", "quit", "open", "navigate", "mutate", "run",
        "build", "restart", "propose", "withdraw", "connect", "invoke",
        "apply", "acquire", "release", "hold", "reply", "mark", "complete",
        "focus", "select", "renew", "mute", "unmute", "render", "generate",
        "pause", "amend", "defer", "close", "archive", "review", "save", "modify", "nudge",
    ]

    public static func normalized(_ tool: String) -> String {
        tool.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
    }

    /// External MCP tools (`mcp__server__tool`) are named by somebody else, so
    /// the verb rule above means nothing for them — `mcp__broker__place_order`
    /// and `mcp__docs__place_lookup` are the same shape. `externalToolIsEffect`
    /// asks the MCP registry for that tool's own risk metadata instead.
    ///
    /// Fail closed: no resolver, or a server that ships no metadata, means the
    /// call ASKS. That is the safe direction here — the worst case is the
    /// person seeing a card for a read, never a peer moving money unattended.
    static let ownNotes: Set<String> = [
        "commit_memory", "studio_journal", "studio_journal_amend", "studio_consult",
        "desk_note", "desk_work_log", "shelf_entry", "task_ledger_post",
    ]

    public static func isEffect(
        _ tool: String,
        externalToolIsEffect: ((String) -> Bool)? = nil
    ) -> Bool {
        let name = normalized(tool)
        if name.isEmpty { return false }
        if name.hasPrefix("mcp__") { return externalToolIsEffect?(name) ?? true }
        // Her OWN notes (Agent's ruling, 2026-09-15): a note of her own
        // volition appends to her own mind and never asks the person.
        // commit_memory carries its own provenance rule instead.
        if ownNotes.contains(name) { return false }
        if effectTools.contains(name) { return true }
        if name.split(separator: "_").contains(where: { effectVerbs.contains(String($0)) }) { return true }
        // Custom registry tools execute code regardless of their chosen name.
        return externalToolIsEffect?(tool) ?? false
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
        let name = normalized(surface)
        return name == "agent-bridge" || name == "agent_bridge"
    }

    /// Who is asking, when the asker is not the person: an inbound peer turn
    /// on the bridge, or an ordinary turn that has consumed a peer's words.
    /// Nil on every other turn — which is what keeps all of this invisible to
    /// the person's own sessions.
    ///
    /// `taintSource` is the latched peer description when this turn has read a
    /// peer's words, nil otherwise. Passed in rather than read here: the taint
    /// box lives in ChatOrchestration, which sits ABOVE this module.
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
            + "\(tool) changes something, so it waits for you."
    }

    /// Agent's ruling, 2026-09-15: her OWN memory notes stay allowed on a peer
    /// turn — attributed. What a peer cannot do is make her record its claims
    /// as established fact, or as something the person wants. So the only
    /// requirement on `commit_memory` here is PROVENANCE: the note has to say
    /// where it came from. Persona and preference writers are not exempted by
    /// wording — they are effects above, and they ask the person regardless.
    ///
    /// Provenance tagging plus the effect gate is the whole mechanism. There
    /// is deliberately no classifier trying to detect steering.
    /// The authenticated peer behind this turn. Identity comes from the
    /// credential the transport verified and the contact record it resolves
    /// to — never from anything the peer wrote in its message.
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

    public static func memoryProvenanceRefusal(
        tool: String,
        input: [String: JSONValue],
        peer: PeerIdentity
    ) -> String? {
        guard normalized(tool) == "commit_memory" else { return nil }
        let who = peer.display
        // Sol, 2026-09-15: this used to scan every argument for the substring
        // "peer", which any sentence satisfies by accident and which rejected
        // an honest "Sam told me…" because the turn only knew to look for the
        // literal word. `commit_memory` already HAS the fields — provenance
        // ∈ {verified, told, inferred} and provenance_by — so the requirement
        // is simply that they are set and name this peer. No string scanning,
        // and nothing the peer writes in prose can satisfy it.
        let kind = string(input["provenance"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard kind == "told" else {
            return "The request came from \(who), a peer — you can keep your own "
                + "note about it, but a peer cannot speak for the person. Set "
                + "provenance=\"told\" and provenance_by=\"\(who)\", so the note "
                + "records what \(who) reported rather than established fact."
        }
        let by = string(input["provenance_by"])?
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
            return "This turn came from \(who), so provenance_by has to be "
                + "\(who) — a peer cannot attribute its claim to someone else."
        }
        return nil
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }
}
