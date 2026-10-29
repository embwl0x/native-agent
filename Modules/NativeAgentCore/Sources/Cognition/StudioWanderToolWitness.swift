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

/// Witnesses artifact attempts, real delivery and journal writes at the gated dispatch seam.
actor StudioWanderToolWitness: ToolDispatchClient {
    struct Report: Sendable, Equatable {
        var attemptedArtifact: Bool
        var obtainedArtifact: Bool
        var journalEntryID: String?
    }

    /// REACHING for a work. Navigation counts here: opening the page IS the
    /// attempt, and an attempt that never becomes a delivery is exactly the
    /// `no_artifact` ending.
    ///
    /// `screen` is absent on purpose. Glancing at whatever happens to be in
    /// front of her is not reaching for anything.
    static let artifactOrgans: Set<String> = deliveringOrgans.union([
        "browser.open",
        // Opening the consult User left on the table IS reaching for the work it
        // names. Whether it DELIVERS depends on what the envelope carries — see
        // `consultDelivered`.
        "studio.consult_read",
    ])

    /// RECEIVING one. Only these can prove she actually met the work: the page's
    /// text, its links, a picture of it, the document itself, the file itself,
    /// the window itself. Deliberately narrower than the turn's allowlist — a
    /// tool added tomorrow does not silently start counting as an encounter.
    ///
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
        surface: String
    ) async throws -> JSONValue {
        guard await shouldContinue(), !Task.isCancelled else { throw CancellationError() }
        guard Self.admits(tool: tool, input: input) else {
            throw AutonomyGateError.toolDenied(reason: Self.refusal())
        }
        let name = Self.action(tool: tool, input: input)
        let preview = tool == "app" && input["preview"] == .bool(true)
        // A screen glance is orientation, not reaching for a work.
        let artifact = !preview && tool != "screen"
        if artifact, Self.artifactOrgans.contains(name) { await noteArtifactAttempt() }
        do {
            let result = try await inner.dispatch(tool: tool, input: input, surface: surface)
            if artifact, Self.delivered(tool: name, result: result) { await noteArtifactObtained() }
            if !preview, name == "studio.journal",
               Self.succeeded(result), let id = Self.journalEntryID(in: result) {
                await noteJournalEntry(id)
            }
            return result
        } catch {
            // A refused or failed organ is exactly the `no_artifact` evidence
            // this witness exists to keep. Rethrow: she must see the failure.
            throw error
        }
    }

    nonisolated func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().filter(Self.advertises)
    }

    nonisolated func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().filter { Self.advertises($0.name) }
    }

    private func noteArtifactAttempt() { attempted = true }
    private func noteArtifactObtained() { obtained = true }
    private func noteJournalEntry(_ id: String) { journalEntryID = id }

    /// DID THIS CALL PUT THE WORK IN FRONT OF HER?
    ///
    /// Three rules, because three organs answer the question differently:
    ///
    ///   * A reading organ (`read`, `read_file`, `browser.read_text`, …) that
    ///     returned a real result delivered.
    ///   * `browser.open_url` delivers ONLY when it was asked to CAPTURE —
    ///     `sourceReceipt`/`screenshotReceipt` on the browser run receipt. A
    ///     bare navigation opened a window and returned; nothing came back to
    ///     her, so the page is not yet a work she has met.
    ///   * `studio_consult_read` discovers references, not artifact content.
    ///     Only a subsequent read or capture witnesses an encounter.
    static func delivered(tool: String, result: JSONValue) -> Bool {
        guard succeeded(result) else { return false }
        if tool == "browser.open" {
            return carriesCapture(result)
        }
        if tool == "studio.consult_read" { return false }
        // A cookie wall or script shell is a stub of the page, not the work.
        if tool == "web.read", isThinPage(result) { return false }
        return deliveringOrgans.contains(tool)
    }

    /// web.read's stub flag, wherever the reply carries it: the raw fields,
    /// an app envelope around them, or the page view's coverage text.
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

    /// A browser run that actually brought something back. The run receipt
    /// carries `sourceReceipt` / `screenshotReceipt` as an object when the call
    /// asked to capture, and `.null` when it did not
    /// (Browser+OperationStore.swift).
    static func carriesCapture(_ result: JSONValue) -> Bool {
        for key in ["sourceReceipt", "screenshotReceipt", "source_receipt", "screenshot_receipt"] {
            if case .object? = deepValue(result, key) { return true }
        }
        return false
    }

    /// Read a key from the payload or from one level of nesting (`consult`,
    /// `output`, `run`), which is how these executors wrap their bodies.
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

    /// Errors, refusals, previews and dry runs never prove delivery.
    static func succeeded(_ result: JSONValue) -> Bool {
        guard ChatToolOutcome.exactResultClass(result) == .succeeded else { return false }
        if case .object(let object) = result {
            if object["dryRun"] == .bool(true) || object["dry_run"] == .bool(true)
                || object["preview"] == .bool(true) { return false }
            if case .string(let status)? = object["status"],
               ["dry_run", "preview"].contains(status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return false }
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

/// Only named actions are advertised and dispatchable; refusals explain the boundary.
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

    // The internal Mac readers remain distinct native organs; the alias owner
    // maps the other tool spellings onto their app action.
    static let admittedOrgans = admittedActions.union(["mac_view", "mac_look"])

    static func advertises(_ tool: String) -> Bool {
        tool == "app" || tool == "workspace" || admittedOrgans.contains(action(tool: tool, input: [:]))
    }

    static func admits(tool: String, input: [String: JSONValue]) -> Bool {
        if tool == "workspace" { return input.allSatisfy { $0.key == "__session_id" || $0.value == .null } }
        guard tool == "app" else { return admittedOrgans.contains(action(tool: tool, input: input)) }
        // Home items can send or mutate at once; scripts hide their individual
        // actions from this witness. Use the bounded actions directly.
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
