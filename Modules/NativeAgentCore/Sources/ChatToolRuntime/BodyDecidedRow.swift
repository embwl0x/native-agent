import Foundation
import NativeAgentShared
import NativeAgentCore
import ChatTurnContracts
import Experiences
import PersistenceCore
import PersonaEngine
import AgentConversations
import ChatToolParsing

// Blueprint: | `BodyDecidedRow.swift` | Rolling decision matters keep their count on the face; settled rollups get new identities |

/// One rolling info row per requester/tool shows the agent's decision without a push. The detail names the session; the write stays off the tool gate's path.
public enum BodyDecidedRow {
    /// The part that tells these rows: their face's `from` and the first part of their identity.
    static let source = "body_decided"

    /// A decision row's kind: its identity (`body_decided.<requester>.<tool>.<uuid>`) without its last two parts, so two requesters never
    /// share a kind. A tool whose own name holds a dot splits its requester's rows by that name's beginning. Nil for any other matter.
    public static func kind(of matter: Experience) -> String? {
        // Rows written under this part's earlier name are the same rows: they group with today's, kind for kind.
        guard let from = matter.face?.from, from == source || from == "harness_decided", matter.id.hasPrefix(from + ".") else { return nil }
        let parts = matter.id.dropFirst(from.count + 1).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return nil }
        return parts.dropLast(2).joined(separator: ".")
    }

    public static func post(turn: Turn, requester: String, tool: String, sessionID: String?, dataRoot: URL, ran: Bool = false) {
        Task { [turn] in _ = await record(turn: turn, requester: requester, tool: tool, sessionID: sessionID, dataRoot: dataRoot, ran: ran) }
    }

    /// A receipt claiming recording must await the row write; an archived row requires a new visible row. Unwritten inboxes return no record.
    public static func record(turn: Turn,
        requester: String, tool: String, sessionID: String?, dataRoot: URL, ran: Bool = false
    ) async -> (id: String, decisions: Int)? {
        let envelope = TurnEnvelope.current(turn: turn, surface: "")
        let requester: String = {
            guard let work = turn.envelope?.workIdentity,
                  work.hasPrefix("carry."), work.count > 6 else { return requester }
            return "house." + work.dropFirst(6)
        }()
        guard requester.hasPrefix("house.") && envelope.agent == "self"
            || (!PeerDataTaint.trustedTurn(turn) && !PeerDataTaint.ownerTrusts(requester)) else { return nil }
        let peerID = requester.hasPrefix("peer:") ? String(requester.dropFirst(5)) : envelope.verifiedUserId
        let contactRead: Result<[AgentPeerContact], any Error> = Result { try AgentPeerStore(dataRoot: dataRoot).list() }
        let peer: AgentPeerContact?
        let displayName: String
        let contactFailure: (any Error)?
        switch contactRead {
        case .success(let peers):
            peer = peers.first { $0.id == peerID || $0.name.caseInsensitiveCompare(requester) == .orderedSame }
            displayName = peer?.name ?? requester
            contactFailure = nil
        case .failure(let error):
            peer = nil
            displayName = requester
            contactFailure = error
        }
        let key = "\(source).\(requester).\(tool)"
        // The agent's own decision, in its own voice, like every row it leaves the person.
        let title = "I \(ran ? "ran" : "allowed"): \(displayName) → \(tool)"
        var words = sessionID.map { "Session: " + $0 } ?? ""
        if let contactFailure { words += "\nContact lookup unavailable: " + contactFailure.localizedDescription }
        do {
            return try await BodyDecisionRollups.shared.tell(key: key, title: String(title.prefix(200)), words: words,
                                                                dataRoot: dataRoot)
        } catch {
            FileHandle.standardError.write(Data("BodyDecidedRow: \(key) not recorded: \(error)\n".utf8))
            return nil
        }
    }
}


/// Serializes increments, while the matter's own badge is the only count.
private actor BodyDecisionRollups {
    static let shared = BodyDecisionRollups()
    private typealias Receipt = (id: String, decisions: Int)
    private var pending: [String: (token: UUID, work: Task<Result<Receipt, Error>, Never>)] = [:]

    func tell(key: String, title: String, words: String, dataRoot: URL) async throws -> (id: String, decisions: Int) {
        let scope = dataRoot.standardizedFileURL.path + "#" + key
        let previous = pending[scope]?.work
        let token = UUID()
        let work = Task { () -> Result<Receipt, Error> in
            _ = await previous?.value
            do { return .success(try await self.file(key: key, title: title, words: words, dataRoot: dataRoot)) }
            catch { return .failure(error) }
        }
        pending[scope] = (token, work)
        let result = await work.value
        if pending[scope]?.token == token { pending[scope] = nil }
        return try result.get()
    }

    private func file(key: String, title: String, words: String, dataRoot: URL) async throws -> Receipt {
        let forPerson = ForPerson.at(dataRoot)
        let open = try await forPerson.matters().first {
            $0.face?.from == BodyDecidedRow.source && $0.id.hasPrefix(key + ".")
                && (ForPerson.reading($0) == .unread || ForPerson.reading($0) == .read)
        }
        let previous: Int
        if let open {
            guard let badge = open.face?.row?.value, let count = Int(badge), count > 0 else {
                throw JSONRow.Malformed.field("body_decided count")
            }
            previous = count
        } else { previous = 0 }
        let count = previous + 1
        var id = open?.id ?? key + "." + UUID().uuidString.lowercased()
        func matter(_ id: String, _ count: Int) -> Matter {
            Matter(id: id, form: .done, from: BodyDecidedRow.source, title: title,
                summary: "\(count) decision\(count == 1 ? "" : "s")", words: words, badge: String(count))
        }
        if try await forPerson.tell(matter(id, count), doors: []) == .settled {
            id = key + "." + UUID().uuidString.lowercased()
            try await forPerson.tell(matter(id, 1), doors: [])
            return (id, 1)
        }
        return (id, count)
    }
}
