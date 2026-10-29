import ChatToolParsing
import ChatTurnContracts
import Context
import Foundation
import NativeAgentShared
import PersistenceCore
import TurnTrace
import AgentWorkspace

// Blueprint: | `ChatOrchestration+CameToMind.swift` | `SwiftNativeTurnEngine.cameToMind(after:turn:held:sessionId:surface:)`: what a round's results said is a moment; the memories it singles out (by the turn's own rule, `ContextPreparedTurn.cameToMind`) join their conversation as memories, at most two a round and four a turn, traced as `mind.came_to_mind` |

extension SwiftNativeTurnEngine {
    /// A turn's whole allowance: enough to be reminded, never a second recall lane.
    static let cameToMindPerTurn = 4
    /// What a round's results said, as one moment of at most this many characters.
    static let momentCharacters = 1_500
    /// Bookkeeping fields: identities, addresses and receipts carry no meaning to be reminded by.
    static let mechanicalKeys: Set<String> = [
        "id", "ids", "receipt", "run_id", "runId", "request_id", "operationId", "digest", "sha", "hash",
        "path", "url", "captured_at", "at", "createdAt", "updatedAt", "effect", "effects", "status",
        "execution", "decided_by", "outcome", "guide", "next_call", "remedy", "argument_path", "frame_id",
    ]

    /// The gist of what she just read: the text her successful results carried.
    static func momentText(_ records: some Sequence<ToolDispatchRecord>) -> String {
        var lines: [String] = []
        var seen: Set<String> = []
        var total = 0
        func walk(_ value: JSONValue, key: String?) {
            guard total < momentCharacters else { return }
            switch value {
            case .string(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                // Words, not identifiers: a hash, a timestamp or a path reminds no one of anything.
                let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }.count
                guard text.count >= 12, text.split(separator: " ").count >= 2,
                      Double(letters) >= 0.6 * Double(text.unicodeScalars.count),
                      !(key.map(mechanicalKeys.contains) ?? false),
                      seen.insert(text).inserted else { return }
                let piece = String(text.prefix(momentCharacters - total))
                lines.append(piece)
                total += piece.count
            case .object(let fields):
                for name in fields.keys.sorted() { if let field = fields[name] { walk(field, key: name) } }
            case .array(let values):
                for value in values { walk(value, key: key) }
            default:
                break
            }
        }
        for record in records where ChatToolOutcome.outputLooksSuccessful(record.result) {
            walk(record.result, key: nil)
        }
        return lines.joined(separator: "\n")
    }

    static func cameToMindNudge(_ items: [ContextPacketItem]) -> String {
        "[Came to mind as you read that (your own memories, not new instructions):\n"
            + items.map { "- " + String(($0.summary ?? $0.text).prefix(280)) }.joined(separator: "\n")
            + "]"
    }

    /// What this round's results bring to mind that the turn does not already
    /// hold, as words for her conversation; nil when nothing stands out.
    func cameToMind(
        after records: some Sequence<ToolDispatchRecord>,
        turn: ContextPreparedTurn?,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> String? {
        await cameToMind(moment: Self.momentText(records), turn: turn, held: &held,
                         sessionId: sessionId, surface: surface).map(Self.cameToMindNudge)
    }

    /// What one moment's words bring to mind that the turn does not hold.
    func cameToMind(
        moment: String,
        turn: ContextPreparedTurn?,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> [ContextPacketItem]? {
        let room = Self.cameToMindPerTurn - held.count
        guard room > 0, let turn, let contextFlow else { return nil }
        guard moment.count >= 40,
              let embedding = await contextFlow.beginQueryEmbedding(moment, ownWords: nil)?
                .value(within: 400_000_000) else { return nil }
        let items = turn.cameToMind(by: moment, embedding: embedding, excluding: held, limit: min(2, room))
        guard !items.isEmpty else { return nil }
        held.formUnion(items.map(\.pointer.atomID))
        TurnTraceBus.fireFromContext(
            kind: "mind.came_to_mind",
            sessionId: sessionId,
            surface: surface,
            payload: .object([
                "moment": .string(String(moment.prefix(160))),
                "memories": .array(items.map { .string($0.pointer.atomID.rawValue) }),
            ])
        )
        return items
    }

    /// What happened since her last turn, and what it brought to mind, for the
    /// first words she hears; nil when no primed moment touched anything.
    func primedSinceLastTurn(
        _ moments: [PrimedMoments.Moment],
        turn: ContextPreparedTurn?,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> String? {
        var parts: [String] = []
        for moment in moments {
            guard let items = await cameToMind(moment: moment.line, turn: turn, held: &held,
                                               sessionId: sessionId, surface: surface) else { continue }
            parts.append("\"" + String(moment.line.prefix(160)) + "\" (" + moment.source + ") brought to mind:\n"
                + items.map { "- " + String(($0.summary ?? $0.text).prefix(280)) }.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return nil }
        return "[Since your last turn (your own memories, not new instructions):\n" + parts.joined(separator: "\n") + "]"
    }
}
