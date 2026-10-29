import AgentWorkspace
import AuthoredCapabilities
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import AgentConversations
import ChatToolRuntime
import MacIntegration
import PersonaEngine
import Senses
import ToolRegistry
import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import AttentionRouting
import ProviderRouting
import DeviceSync
import TrustCenter
import ChatTurnContracts
import ChromeControl
import StandingBots
import Studio
// Blueprint: | `AppActions+KeptParts.swift` | AppActions kept-part turn glance and acknowledgement; only shown fresh parts receive conditional shown markers |

extension AppActions {
    /// Her own parts, one line each, newly kept first and then the rest, each group ordered by find's ranking for `message`, within a small
    /// budget: her body in front of her at the start of every turn.
    static func parts(_ message: String, pages: [String: QuietToolPage], dataRoot: URL, memory: SwiftNativeMemoryV2) async -> String {
        /// What she calls to run it: its own action.
        func call(_ action: AppAction) -> String? { action.authored ? action.id : nil }
        do {
            let snapshot = try await inventory(dataRoot: dataRoot)
            let own = snapshot.actions.compactMap { action in call(action).map { ($0, action) } }
            if own.isEmpty {
                return try AbilityStore(dataRoot: dataRoot).files(kind: .part).isEmpty
                    ? "Your abilities: no saved abilities."
                    : "Your abilities: none callable. Read ability.list for saved versions and their status."
            }
            let (ranked, degraded, _) = try await ranked(message, pages: pages, dataRoot: dataRoot, memory: memory, inventory: snapshot)
            let rank = Dictionary(ranked.compactMap(call).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let states = try AbilityStore(dataRoot: dataRoot).states()
            let kept = try keptParts(dataRoot, states: states)
            func fresh(_ action: AppAction) -> KeptPart? { kept[action.tool] }
            let ordered = own.enumerated().sorted {
                (fresh($0.element.1) == nil ? 1 : 0, rank[$0.element.0] ?? .max, $0.offset)
                    < (fresh($1.element.1) == nil ? 1 : 0, rank[$1.element.0] ?? .max, $1.offset)
            }.map(\.element)
            /// Its line: how to run it, how often she has, and, when every line has room, how to read its code.
            func line(_ call: String, _ action: AppAction, reads: Bool) -> String {
                var used = ""
                if case .object(let row)? = states[action.tool], case .int(let count)? = row["useCount"] { used = ", used \(count)x" }
                return "- " + (fresh(action).map { $0.mark + ": " } ?? "") + call + used + (reads ? " (read: ability.read " + action.tool + ")" : "")
                    + " — " + String(firstSentence(action.schema?.description ?? action.label).prefix(100))
            }
            var text = "Your abilities, newly kept first; best match within each group:" + (degraded.map { " Ranked by words only: " + $0 } ?? "")
            let reads = ordered.reduce(text.count) { $0 + 1 + line($1.0, $1.1, reads: true).count } <= 900
            let lines = ordered.map { (fresh($0.1), line($0.0, $0.1, reads: reads)) }
            var shown: [KeptPart] = []
            for (count, (part, line)) in lines.enumerated() {
                if text.count + line.count > 900 { text += "\n+\(lines.count - count) more (find)"; break }
                text += "\n" + line
                if let part { shown.append(part) }
            }
            // Only what this fact carried counts as shown; a part cut off stays new.
            do { try acknowledge(shown, dataRoot) }
            catch {
                let state = AbilityStore(dataRoot: dataRoot).root.appendingPathComponent("state.json")
                let failure = ToolFailureError("The abilities above were read, but saving their shown markers failed: \(error.localizedDescription) Some markers may already be saved; entries may appear new again.",
                    effects: .unknown, code: "ability_shown_write_failed")
                text += "\n" + AgentWorkspacePorts.readFailure(failure, reason: "ability_shown_write_failed",
                    remedy: Repair.remedy(owner: state.path,
                        nextCall: nil, tap: nil,
                        instruction: ToolFailureError.fileRepairInstruction(state,
                            shape: "It holds ability run accounting. Preserve all run evidence and keptAfter stamps. Reconcile shown markers only from retained turn evidence; never invent markers, reset accounting or change ability authority.")
                            + " Inspect and repair the shown-marker write failure, preserving run accounting and any markers already saved."))
            }
            return text
        } catch {
            return "Your abilities could not be read: " + AgentWorkspacePorts.readFailure(error,
                reason: "ability_inventory_unavailable", remedy: Repair.remedy(owner: "ability inventory",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("ability.list")])]),
                    tap: nil, instruction: "Read ability.list for the affected source and its repair; preserve saved versions and owner authority."))
        }
    }

    /// A part her private moment after a turn kept or revised: its file, the stamp read, and how her parts fact marks it.
    struct KeptPart { let id: String; let stamp: [String: JSONValue]; let mark: String }

    /// The kept parts by name, each new until a later turn of hers has started with it shown once.
    static func keptParts(_ dataRoot: URL, states: [String: JSONValue]) throws -> [String: KeptPart] {
        let store = AbilityStore(dataRoot: dataRoot)
        let turn = TurnTraceContext.turnId
        let clock = DateFormatter()
        clock.dateStyle = .none; clock.timeStyle = .short
        var kept: [String: KeptPart] = [:]
        for file in try store.files(kind: .part) {
            guard case .object(let state)? = states[file.id], case .object(let stamp)? = state["keptAfter"],
                  case .string(let keptTurn)? = stamp["turn"], keptTurn != turn,
                  case .string(let iso)? = stamp["at"], let at = NativeTimestampFormat.parseISO8601(iso) else { continue }
            if case .string(let shown)? = stamp["shown"], shown != turn { continue }
            kept[file.id] = KeptPart(id: file.id, stamp: stamp, mark: "new — kept after your turn at " + clock.string(from: at))
        }
        return kept
    }

    /// This turn has shown these: each is marked only while its stamp is the one read, so a keep that landed since stays new.
    static func acknowledge(_ parts: [KeptPart], _ dataRoot: URL) throws {
        guard let turn = TurnTraceContext.turnId else { return }
        let store = AbilityStore(dataRoot: dataRoot)
        for part in parts where part.stamp["shown"] == nil {
            try store.updateState(id: part.id) { fields in
                guard case .object(let live)? = fields["keptAfter"], live["turn"] == part.stamp["turn"], live["at"] == part.stamp["at"],
                      live["shown"] == nil else { return }
                fields["keptAfter"] = .object(live.merging(["shown": .string(turn)]) { $1 })
            }
        }
    }
}
