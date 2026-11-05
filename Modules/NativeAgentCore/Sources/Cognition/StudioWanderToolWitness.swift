import Foundation
import ChatTurnContracts
import ChatToolParsing
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import BackgroundLoops
import CognitiveSubstrate
import Context
import PersonaEngine
import ProviderRouting
import Experiences
import MemoryV2
import ChatTurnRuntime
import AgentWorkspace
import AgentConversations
import Desk
import DreamREMCycle
import Transcripts
import TurnTrace
import NativeAgentShared
import Studio
import ApprovalInbox
import ChatToolRuntime
import ContextFlow
import AuthoredCapabilities
// Blueprint: | `StudioWanderToolWitness.swift` | `StudioWanderToolWitness`: hour action admission and encounter evidence at the gated dispatch seam |

/// Witness attempts, actual delivery and journal writes at gated dispatch, never from reply claims.
actor StudioWanderToolWitness: ToolDispatchClient {
    struct Report: Sendable, Equatable {
        var attemptedArtifact: Bool
        var obtainedArtifact: Bool
        var journalEntryID: String?
    }

    /// Navigation establishes an artifact attempt; a screen glance is orientation and cannot establish reaching for a work.
    static let artifactOrgans: Set<String> = deliveringOrgans.union([
        "browser.open",
        // Reading a consult establishes an attempt; only its delivered content can establish an encounter.
        "studio.consult_read",
    ])

    /// Count delivery only from explicit content-bearing actions so newly allowed tools cannot silently become encounter proof.
    static let deliveringOrgans: Set<String> = [
        "browser.text", "browser.links", "browser.screenshot",
        "mac.read", "mac.look", "files.read", "files.excerpt", "web.read",
        "mac_view", "mac_look",
    ]

    private let inner: any ToolDispatchClient
    private let shouldContinue: @Sendable () async -> Bool
    private var attempted = false
    private var obtained = false
    private var journalEntryID: String?

    init(inner: any ToolDispatchClient, shouldContinue: @escaping @Sendable () async -> Bool = { true }) {
        self.inner = inner
        self.shouldContinue = shouldContinue
    }

    func report() -> Report {
        Report(
            attemptedArtifact: attempted,
            obtainedArtifact: obtained,
            journalEntryID: journalEntryID
        )
    }

    nonisolated func dispatch(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        turn: Turn,
        invocation: ChatToolInvocation
    ) async throws -> JSONValue {
        guard await shouldContinue(), !Task.isCancelled else { throw CancellationError() }
        guard Self.admits(tool: tool, input: input) else {
            throw AutonomyGateError.toolDenied(reason: Self.refusal())
        }
        let name = Self.action(tool: tool, input: input)
        let preview = tool == "app" && input["preview"] == .bool(true)
        // A screen glance is orientation rather than an artifact attempt.
        let artifact = !preview && tool != "screen"
        if artifact, Self.artifactOrgans.contains(name) { await noteArtifactAttempt() }
        do {
            let result = try await inner.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
            if artifact, Self.delivered(tool: name, result: result) { await noteArtifactObtained() }
            if !preview, name == "studio.journal",
               Self.succeeded(result), let id = Self.journalEntryID(in: result) {
                await noteJournalEntry(id)
            }
            return result
        } catch {
            // Retain refusal as no_artifact evidence and rethrow so the agent sees the failure.
            throw error
        }
    }

    nonisolated func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await inner.listAvailableTools(turn: turn, surface: surface).filter(Self.advertises)
    }

    nonisolated func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(turn: turn, surface: surface).filter { Self.advertises($0.name) }
    }

    private func noteArtifactAttempt() { attempted = true }
    private func noteArtifactObtained() { obtained = true }
    private func noteJournalEntry(_ id: String) { journalEntryID = id }

    /// Content-bearing reads can prove delivery; bare navigation and consult-reference discovery cannot.
    /// Browser navigation requires a captured source or screenshot receipt before it counts as an encounter.
    static func delivered(tool: String, result: JSONValue) -> Bool {
        guard succeeded(result) else { return false }
        if tool == "browser.open" {
            return carriesCapture(result)
        }
        if tool == "studio.consult_read" { return false }
        // Cookie walls and script shells are page stubs rather than the requested work.
        if tool == "web.read", isThinPage(result) { return false }
        return deliveringOrgans.contains(tool)
    }

    /// Read the stub flag through its actual raw, envelope and page-coverage shapes.
    static func isThinPage(_ result: JSONValue) -> Bool {
        switch result {
        case .string(let text): return text.contains("\"thin_page\":true")
        case .object(let object):
            return object["thin_page"] == .bool(true) || object["reason"] == .string("thin_page")
                || object.values.contains(where: isThinPage)
        case .array(let values): return values.contains(where: isThinPage)
        default: return false
        }
    }

    /// Capture receipts establish returned content; null receipts prove only navigation.
    static func carriesCapture(_ result: JSONValue) -> Bool {
        for key in ["sourceReceipt", "screenshotReceipt", "source_receipt", "screenshot_receipt"] {
            if case .object? = deepValue(result, key) { return true }
        }
        return false
    }

    /// Read payload keys through one executor-owned wrapper level only.
    static func deepValue(_ result: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let object) = result else { return nil }
        if let direct = object[key] { return direct }
        for wrapper in ["consult", "output", "run", "receipt"] {
            if case .object(let nested)? = object[wrapper], let found = nested[key] {
                return found
            }
        }
        return nil
    }

    /// Errors, refusals, previews and dry runs cannot prove delivery.
    static func succeeded(_ result: JSONValue) -> Bool {
        let reply = ToolResult(result)
        guard reply.outcome == .succeeded else { return false }
        if case .object(let object) = reply.payload {
            if object["dryRun"] == .bool(true) || object["dry_run"] == .bool(true)
                || object["preview"] == .bool(true) { return false }
            if object["status"]?.stringValue != nil,
               reply.said("dry_run") || reply.said("preview") { return false }
        }
        return true
    }

    static func journalEntryID(in result: JSONValue) -> String? {
        guard case .object(let object) = result else { return nil }
        for key in ["entry_id", "id"] {
            if case .string(let value)? = object[key], !value.isEmpty { return value }
        }
        if case .object(let entry)? = object["entry"],
           case .string(let value)? = entry["id"], !value.isEmpty {
            return value
        }
        return nil
    }
}

/// Advertise and dispatch only named actions; explain refused boundaries.
extension StudioWanderToolWitness {
    static let admittedActions: Set<String> = [
        "mac.look", "mac.read", "files.read", "files.excerpt", "web.read",
        "browser.status", "browser.open", "browser.text", "browser.links", "browser.screenshot",
        "studio.journal", "studio.recall", "studio.consult_read",
        "memory.recall", "graph.search", "context.expand", "ability.list", "ability.read",
        "time.now", "mind.inner_state", "result.page",
    ]

    static func action(in input: [String: JSONValue]) -> String {
        guard case .string(let action)? = input["action"] else { return "" }
        return action.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func action(tool: String, input: [String: JSONValue]) -> String {
        tool == "app" ? action(in: input)
            : ToolNameAliases.appAction(tool, input: input) ?? ToolNameAliases.canonical(tool)
    }

    // Keep native Mac readers distinct while the alias owner maps other tool spellings to app actions.
    static let admittedOrgans = admittedActions.union(["mac_view", "mac_look"])

    static func advertises(_ tool: String) -> Bool {
        tool == "app" || tool == "workspace" || admittedOrgans.contains(action(tool: tool, input: [:]))
    }

    static func admits(tool: String, input: [String: JSONValue]) -> Bool {
        if tool == "workspace" { return input.allSatisfy { $0.key == "__session_id" || $0.value == .null } }
        guard tool == "app" else { return admittedOrgans.contains(action(tool: tool, input: input)) }
        // Use bounded actions because home items may mutate immediately and scripts conceal nested actions from this witness.
        for key in ["script", "item"] {
            if let value = input[key], value != .null && value != .string("") { return false }
        }
        let action = action(in: input)
        return action.isEmpty || admittedActions.contains(action)
    }


    static func refusal() -> String {
        "That call is not available in your own hour. This time is for looking and, if you "
        + "want to, writing in your journal. You may open a browser page to read it, "
        + "but cannot send, use other controls, or change your memory. Use app with one of these actions: "
        + admittedActions.sorted().joined(separator: ", ")
        + ". Nothing was done."
    }
}
