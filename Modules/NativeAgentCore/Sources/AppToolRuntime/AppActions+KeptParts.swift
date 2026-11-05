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
import Experiences
import TrustCenter
import ChatTurnContracts
import ChromeControl
import StandingBots
import Studio
// Blueprint: | `AppActions+KeptParts.swift` | Bounded kept-part glance |

extension AppActions {
    /// Autonomous parts collapse to one findable count so kept-part context stays bounded.
    static func parts(_ message: String, pages: [String: QuietToolPage], dataRoot: URL, memory: SwiftNativeMemoryV2,
                      turn: Turn?) async -> PreparedWorkspaceGlance {
        var timings: [String: JSONValue] = [:]
        var readStart = DispatchTime.now().uptimeNanoseconds
        func measured(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            timings[name] = .int(Int64((now - readStart) / 1_000_000)); readStart = now
        }
        defer { TurnTraceBus.fireFromContext(kind: "context.parts.summary", payload: .object(["stageMs": .object(timings)]), turn: turn) }
        func call(_ action: AppAction) -> String? { action.authored ? action.id : nil }
        do {
            let snapshot = try await inventory(dataRoot: dataRoot, turn: turn)
            measured("inventory")
            let own = snapshot.actions.compactMap { action in call(action).map { ($0, action) } }
            if own.isEmpty {
                return PreparedWorkspaceGlance(try AbilityStore(dataRoot: dataRoot).files(kind: .part).isEmpty
                    ? "Your abilities: no saved abilities."
                    : "Your abilities: none callable. Read ability.list for saved versions and their status.")
            }
            let rankedActions: [AppAction]
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rankedActions = []
            } else {
                let ranking = try await ranked(message, pages: pages, dataRoot: dataRoot, memory: memory, inventory: snapshot, turn: turn)
                rankedActions = ranking.actions
            }
            measured("ranking")
            let rank = Dictionary(rankedActions.compactMap(call).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let store = AbilityStore(dataRoot: dataRoot)
            let catalog = try store.catalog()
            let states = catalog.states
            let recent = Dictionary(uniqueKeysWithValues: states.compactMap { id, state in usedAt(state).map { (id, $0) } })
            let files = Dictionary(uniqueKeysWithValues: catalog.files.filter { $0.kind == .part }.map { ($0.id, $0) })
            let clock = DateFormatter()
            clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "h:mm a"
            let failures = Dictionary(uniqueKeysWithValues: files.values.compactMap { file in
                lastRunFailure(file, state: states[file.id], store: store, clock: clock).map { (file.id, $0) }
            })
            measured("states_kept")
            func onItsOwn(_ action: AppAction) -> Bool {
                guard let file = files[action.tool] else { return false }
                return file.metadata["resident"] == .bool(true) || !(file.metadata["wake"]?.arrayValue ?? []).isEmpty
            }
            let autonomous = own.filter { onItsOwn($0.1) }.count
            let ordered = own.enumerated().filter { !onItsOwn($0.element.1) }.sorted {
                let left = $0.element, right = $1.element
                let leftRank = rank[left.0] ?? .max, rightRank = rank[right.0] ?? .max
                if leftRank != rightRank { return leftRank < rightRank }
                if leftRank == .max {
                    let leftFailed = failures[left.1.tool] != nil, rightFailed = failures[right.1.tool] != nil
                    if leftFailed != rightFailed { return leftFailed }
                    let leftUsed = recent[left.1.tool] ?? .distantPast
                    let rightUsed = recent[right.1.tool] ?? .distantPast
                    if leftUsed != rightUsed { return leftUsed > rightUsed }
                }
                return $0.offset < $1.offset
            }.map(\.element)
            /// Include source-read guidance only when every part line has room.
            func line(_ call: String, _ action: AppAction, reads: Bool) -> String {
                var used = ""
                if case .int(let count)? = states[action.tool]?.objectValue?["useCount"] {
                    if count == 0 { used = ", never used" }
                    if count == 1 { used = ", used once" }
                }
                let failed = failures[action.tool].map { ", " + $0 } ?? ""
                return "- " + call + used + (reads ? " (read: ability.read " + action.tool + ")" : "")
                    + failed + " — " + partDescription(firstSentence(action.schema?.description ?? action.label))
            }
            var text = "Your abilities, best matches first, then failed and recent:"
            let autonomousLine = autonomous > 0 ? "\n+\(autonomous) run on their own (find)" : ""
            let reads = ordered.reduce(text.count + autonomousLine.count) { $0 + 1 + line($1.0, $1.1, reads: true).count } <= 900
            let lines = ordered.map { line($0.0, $0.1, reads: reads) }
            for (count, line) in lines.enumerated() {
                let more = count + 1 < lines.count ? "\n+\(lines.count - count - 1) more (find)" : ""
                if text.count + 1 + line.count + autonomousLine.count + more.count > 900 { text += "\n+\(lines.count - count) more (find)"; break }
                text += "\n" + line
            }
            text += autonomousLine
            measured("render")
            return PreparedWorkspaceGlance(text)
        } catch {
            return PreparedWorkspaceGlance("Your abilities could not be read: " + AgentWorkspacePorts.readFailure(error,
                reason: "ability_inventory_unavailable", remedy: Repair.remedy(owner: "ability inventory",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("ability.list")])]),
                    tap: nil, instruction: "Read ability.list for the affected source and its repair; preserve saved versions and owner authority.")))
        }
    }

    /// Truncation never splits a word; the ellipsis itself fits inside the 100 characters.
    private static func partDescription(_ text: String) -> String {
        guard text.count > 100 else { return text }
        let end = text.index(text.startIndex, offsetBy: 99)
        let prefix = text[..<end]
        let boundary = text[end].isWhitespace ? end : prefix.lastIndex(where: \.isWhitespace) ?? text.startIndex
        return text[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func usedAt(_ state: JSONValue?) -> Date? {
        switch state?.objectValue?["lastUsedAt"] {
        case .string(let iso)?: NativeTimestampFormat.parseISO8601(iso)
        case .double(let stamp)?: Date(timeIntervalSinceReferenceDate: stamp)
        default: nil
        }
    }

    /// Missing evidence is not a failure, and a replaced version owes no mark for its predecessor.
    private static func lastRunFailure(_ file: AbilityStore.File, state: JSONValue?, store: AbilityStore, clock: DateFormatter) -> String? {
        guard let row = state?.objectValue, let version = store.identity(file), row["lastRunVersion"] == .string(version),
              let last = row["lastRun"]?.objectValue, let status = last["status"]?.stringValue, !status.isEmpty else { return nil }
        let outcome = AbilityStore.runOutcome(.object(last))
        guard outcome != "ok" else { return nil }
        let fault = last["error"]?.objectValue ?? last["stopped"]?.objectValue ?? last
        let detail = fault["message"]?.stringValue ?? fault["detail"]?.stringValue ?? fault["reason"]?.stringValue
            ?? last["error"]?.stringValue ?? outcome
        let reason = ContextSecretContentPolicy.redactedFragment(detail).split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        let at = last["at"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601) ?? usedAt(state)
        let when = at.map { clock.string(from: $0) } ?? "(time unknown)"
        return "failed last run " + when + ": " + (reason.isEmpty ? outcome : reason)
    }
}
