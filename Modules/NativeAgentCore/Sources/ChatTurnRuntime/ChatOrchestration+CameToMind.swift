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

// Blueprint: | `ChatOrchestration+CameToMind.swift` | `SwiftNativeTurnEngine.cameToMind(after:turn:held:sessionId:surface:)`: non-preview lines first met (`FamiliarLines`) form a moment; the recorder's dispatch predicate and ExpansionDispatcher's nested preview marker exclude proposals before familiarity and recall; memories join their conversation at most two a round and four a turn, traced as `mind.came_to_mind` |

extension SwiftNativeTurnEngine {
    private func familiarityFailure(_ error: Error, root: URL) -> String? {
        let owner = root.appendingPathComponent("mind/familiar.bin")
        RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: "mind.familiar", owner: owner.path,
            words: "Familiarity is unavailable: \(error.localizedDescription). No new familiarity was recorded; saved bytes are preserved.",
            tap: ToolFailureError.fileRepairInstruction(owner, shape: "Preserve the sequence of complete eight-byte familiarity keys and restore read/write access."))
        TurnTraceBus.fireFromContext(kind: "mind.familiarity_unavailable", payload: .object(["owner": .string(owner.path), "error": .string(error.localizedDescription)]))
        return nil
    }
    /// A turn's whole allowance: enough to be reminded, never a second recall lane.
    static let cameToMindPerTurn = 4
    /// What a round's results said, as one moment of at most this many characters.
    static let momentCharacters = 1_500
    /// How far into a round she reads for it: a long page's tail is never the
    /// moment, and meeting all of it would crowd out what she knows by heart.
    static let momentReach = 6_000

    /// The lines of words in what she read or wrote: a hash, a timestamp or a
    /// path reminds no one of anything.
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

    /// What this round's results bring to mind that the turn does not already
    /// hold, as words for her conversation; nil when nothing stands out.
    func cameToMind(
        after records: some Sequence<ToolDispatchRecord>,
        turn: ContextPreparedTurn?,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> String? {
        let records = records.filter { !ChatToolDispatchTracer.isPreview(tool: $0.name, input: $0.input) }
        guard !records.isEmpty else { return nil }
        // Her own words coming back in a receipt are already hers.
        if let root = remPinsDataRoot {
            do { try FamiliarLines.firstMet(Self.lines(records.map { .object($0.input) }), dataRoot: root) }
            catch { return familiarityFailure(error, root: root) }
        }
        let read = records.map(\.result).filter { ChatToolOutcome.outputLooksSuccessful($0) }
        return await cameToMind(lines: Self.lines(read), turn: turn, held: &held,
                                sessionId: sessionId, surface: surface).map(Self.cameToMindNudge)
    }

    /// What one moment brings to mind that the turn does not hold. Only the
    /// lines she meets for the first time are the moment (`FamiliarLines`):
    /// she gets used to the rest, whether or not anything has room.
    func cameToMind(
        lines: [String],
        turn: ContextPreparedTurn?,
        held: inout Set<ContextAtomID>,
        sessionId: String?,
        surface: String
    ) async -> [ContextPacketItem]? {
        var moment = ""
        let fresh: [String]
        do { fresh = try remPinsDataRoot.map({ try FamiliarLines.firstMet(lines, dataRoot: $0) }) ?? lines }
        catch {
            if let root = remPinsDataRoot { _ = familiarityFailure(error, root: root) }
            return nil
        }
        for line in fresh
        where moment.count < Self.momentCharacters {
            moment += (moment.isEmpty ? "" : "\n") + line.prefix(Self.momentCharacters - moment.count)
        }
        let room = Self.cameToMindPerTurn - held.count
        guard room > 0, let turn, let contextFlow else { return nil }
        guard moment.count >= 40 else { return nil }
        func report(_ status: String, _ detail: String) {
            TurnTraceBus.fireFromContext(kind: "mind.came_to_mind.read", sessionId: sessionId, surface: surface,
                payload: .object(["status": .string(status), "detail": .string(detail)]))
            if status == "unavailable", let root = remPinsDataRoot {
                RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: "mind.came_to_mind", owner: "context",
                    words: detail, nextCall: ToolFailureError.call("app", ["page": .string("mind")]))
            }
        }
        guard let ticket = await contextFlow.beginQueryEmbedding(moment, ownWords: nil) else {
            report("unavailable", "Ambient recollection has no embedding reader. Repair the context embedding owner.")
            return nil
        }
        guard let embedding = await ticket.value(within: 400_000_000) else {
            if let why = ticket.unavailable { report("unavailable", "Ambient recollection embedding is unavailable: " + why) }
            else { report("deadline", "The ambient embedding did not arrive within 400 ms; this moment's wait ended without a no-match verdict.") }
            return nil
        }
        let read: ContextAmbientRecallResult
        do { read = try await turn.cameToMind(by: moment, embedding: embedding, excluding: held, limit: min(2, room)) }
        catch {
            report("unavailable", "Ambient recollection selection failed: \(error.localizedDescription). Repair its context source.")
            return nil
        }
        if !read.unavailable.isEmpty {
            report("unavailable", read.unavailable.map(\.reason).joined(separator: "; "))
        }
        let items = read.items
        if read.unavailable.isEmpty, let root = remPinsDataRoot, let turnID = TurnTraceContext.turnId {
            RepairOwed.settle(root, operation: "mind.came_to_mind", evidence: .init(source: "turn_traces", id: turnID))
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
            guard let items = await cameToMind(lines: Self.lines([.string(moment.line)]), turn: turn, held: &held,
                                               sessionId: sessionId, surface: surface) else { continue }
            parts.append("\"" + String(moment.line.prefix(160)) + "\" (" + moment.source + ") brought to mind:\n"
                + items.map { "- " + String(($0.summary ?? $0.text).prefix(280)) }.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return nil }
        return "[Since your last turn (your own memories, not new instructions):\n" + parts.joined(separator: "\n") + "]"
    }
}
