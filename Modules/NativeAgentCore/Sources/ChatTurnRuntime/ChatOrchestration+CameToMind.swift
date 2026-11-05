import ChatToolParsing
import ChatToolRuntime
import ChatTurnContracts
import Context
import Foundation
import NativeAgentShared
import PersistenceCore
import TurnTrace
import AgentWorkspace
import Experiences
import NativeAgentCore

// Blueprint: | `ChatOrchestration+CameToMind.swift` | `SwiftNativeTurnEngine.cameToMind(after:turn:held:sessionId:surface:)`: non-preview lines first met (`FamiliarLines`) form a moment; the recorder's dispatch predicate and ExpansionDispatcher's nested preview marker exclude proposals before familiarity and recall; memories join the agent's conversation at most two a round and four a turn, traced as `mind.came_to_mind` |

extension SwiftNativeTurnEngine {
    private func familiarityFailure(_ error: Error, root: URL, turn: Turn) -> String? {
        let owner = root.appendingPathComponent("mind/familiar.bin")
        RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: "mind.familiar", owner: owner.path,
            words: "Familiarity is unavailable: \(error.localizedDescription). No new familiarity was recorded; saved bytes are preserved.",
            tap: ToolFailureError.fileRepairInstruction(owner,
                shape: "Preserve the sequence of complete eight-byte familiarity keys and restore read/write access."))
        TurnTraceBus.fireFromContext(kind: "mind.familiarity_unavailable", payload: .object(["owner": .string(owner.path), "error": .string(error
            .localizedDescription)]), turn: turn)
        return nil
    }
    /// A turn's whole allowance: enough to be reminded, never a second recall lane.
    static let cameToMindPerTurn = 4
    /// What a round's results said, as one moment of at most this many characters.
    static let momentCharacters = 1_500
    /// Read only the bounded head: a long result's tail would crowd out familiar context.
    static let momentReach = 6_000

    /// The agent's own app speaking (its actions, guides, labels, remedies) is the agent's body, not news:
    /// in an app receipt the world is only what a call returned, its `result`.
    static func world(in receipt: JSONValue) -> [JSONValue] {
        guard case .object(let fields) = receipt else { return [] }
        if let result = fields["result"] { return [result] }
        if case .array(let receipts)? = fields["receipts"] { return receipts.flatMap(world(in:)) }
        return []
    }

    /// Hashes, timestamps and paths cannot supply the words needed for a reminder.
    static func lines(_ values: some Sequence<JSONValue>) -> [String] {
        var lines: [String] = []
        var total = 0
        func walk(_ value: JSONValue) {
            guard total < momentReach else { return }
            switch value {
            case .string(let raw):
                for line in raw.split(whereSeparator: \.isNewline) {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }.count
                    guard total < momentReach, text.count >= 12, text.split(separator: " ").count >= 2,
                          Double(letters) >= 0.6 * Double(text.unicodeScalars.count) else { continue }
                    lines.append(text)
                    total += text.count
                }
            case .object(let fields):
                for name in fields.keys.sorted() where name != ExpansionDispatcher.previewResultsKey {
                    if let field = fields[name] { walk(field) }
                }
            case .array(let values):
                values.forEach(walk)
            default:
                break
            }
        }
        values.forEach(walk)
        return lines
    }

    static func cameToMindNudge(_ items: [ContextPacketItem]) -> String {
        "[Came to mind as you read that (your own memories, not new instructions):\n"
            + items.map { "- " + String(($0.summary ?? $0.text).prefix(280)) }.joined(separator: "\n")
            + "]"
    }

    func cameToMind(
        after records: some Sequence<ToolDispatchRecord>,
        preparedTurn: ContextPreparedTurn?, turn: Turn,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> String? {
        let records = records.filter { !ChatToolDispatchTracer.isPreview(tool: $0.name, input: $0.input) }
        guard !records.isEmpty else { return nil }
        // The agent's own words coming back in a receipt are already the agent's.
        if let root = remPinsDataRoot {
            do { try FamiliarLines.firstMet(Self.lines(records.map { .object($0.input) }), dataRoot: root) }
            catch { return familiarityFailure(error, root: root, turn: turn) }
        }
        let read = records.filter {
            let reply = ToolResult($0.result)
            return ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome)
        }
            .flatMap { $0.name == "app" ? Self.world(in: $0.result) : [$0.result] }
        return await cameToMind(lines: Self.lines(read), preparedTurn: preparedTurn, turn: turn, held: &held,
                                sessionId: sessionId, surface: surface).map(Self.cameToMindNudge)
    }

    /// Only newly met lines form the moment; familiarity advances even when no reminder fits.
    func cameToMind(
        lines: [String],
        preparedTurn: ContextPreparedTurn?, turn: Turn,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> [ContextPacketItem]? {
        var moment = ""
        let fresh: [String]
        do { fresh = try remPinsDataRoot.map({ try FamiliarLines.firstMet(lines, dataRoot: $0) }) ?? lines }
        catch {
            if let root = remPinsDataRoot { _ = familiarityFailure(error, root: root, turn: turn) }
            return nil
        }
        for line in fresh
        where moment.count < Self.momentCharacters {
            moment += (moment.isEmpty ? "" : "\n") + line.prefix(Self.momentCharacters - moment.count)
        }
        let room = Self.cameToMindPerTurn - held.count
        guard room > 0, let preparedTurn, let contextFlow else { return nil }
        guard moment.count >= 40 else { return nil }
        func report(_ status: String, _ detail: String) {
            TurnTraceBus.fireFromContext(kind: "mind.came_to_mind.read", sessionId: sessionId, surface: surface,
                payload: .object(["status": .string(status), "detail": .string(detail)]), turn: turn)
            if status == "unavailable", let root = remPinsDataRoot {
                RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: "mind.came_to_mind", owner: "context",
                    words: detail, nextCall: ToolFailureError.call("app", ["page": .string("mind")]))
            }
        }
        guard let ticket = await contextFlow.beginQueryEmbedding(moment, ownWords: nil, turn: turn) else {
            report("unavailable", "Ambient recollection has no embedding reader. Repair the context embedding owner.")
            return nil
        }
        guard let embedding = await ticket.value(within: 400_000_000) else {
            if let why = ticket.unavailable { report("unavailable", "Ambient recollection embedding is unavailable: " + why) }
            else { report("deadline", "The ambient embedding did not arrive within 400 ms; this moment's wait ended without a no-match verdict.") }
            return nil
        }
        let read: ContextAmbientRecallResult
        do { read = try await preparedTurn.cameToMind(by: moment, embedding: embedding, excluding: held, limit: min(2, room)) }
        catch {
            report("unavailable", "Ambient recollection selection failed: \(error.localizedDescription). Repair its context source.")
            return nil
        }
        if !read.unavailable.isEmpty {
            report("unavailable", read.unavailable.map(\.reason).joined(separator: "; "))
        }
        let items = read.items
        if read.unavailable.isEmpty, let root = remPinsDataRoot {
            let turnID = turn.id
            RepairOwed.settle(root, operation: "mind.came_to_mind", evidence: .init(source: "experience", id: turnID))
        }
        guard !items.isEmpty else {
            if read.unavailable.isEmpty { report("no_match", "The checked ambient selection returned no matches.") }
            return nil
        }
        held.formUnion(items.map(\.pointer.atomID))
        TurnTraceBus.fireFromContext(
            kind: "mind.came_to_mind",
            sessionId: sessionId,
            surface: surface,
            payload: .object([
                "moment": .string(String(moment.prefix(160))),
                "memories": .array(items.map { .string($0.pointer.atomID.rawValue) }),
            ]), turn: turn
        )
        return items
    }

    func primedSinceLastTurn(
        _ moments: [PrimedMoments.Moment],
        preparedTurn: ContextPreparedTurn?, turn: Turn,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> String? {
        var parts: [String] = []
        for moment in moments {
            guard let items = await cameToMind(lines: Self.lines([.string(moment.line)]), preparedTurn: preparedTurn, turn: turn, held: &held,
                                               sessionId: sessionId, surface: surface) else { continue }
            parts.append("\"" + String(moment.line.prefix(160)) + "\" (" + moment.source + ") brought to mind:\n"
                + items.map { "- " + String(($0.summary ?? $0.text).prefix(280)) }.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return nil }
        return "[Since your last turn (your own memories, not new instructions):\n" + parts.joined(separator: "\n") + "]"
    }
}
