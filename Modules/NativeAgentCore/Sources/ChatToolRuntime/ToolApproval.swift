import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import Desk
import MacControl
import SwarmRuns
import MacIntegration
import ToolExecution
import Studio
import Senses
import Research
import TurnTrace
// Blueprint: | `ToolApproval.swift` | PreApprovalToolValidating contract and SwiftToolDispatcher refusal/proposal wording before approval admission |
/// Reject unavailable tools and malformed arguments before filing an approval card.
public protocol PreApprovalToolValidating: Sendable {
    func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue?

    /// The words the person should read on the card for THIS call, when the
    /// generic "autonomy=confirm" reason cannot say what is about to happen.
    /// A setup that writes into another program's settings has to disclose the
    /// exact file, the exact entry and the exact access before anyone presses
    /// anything, and only the implementation knows those. Nil keeps the
    /// caller's own reason, which is every existing tool.
    func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String?
}
public extension PreApprovalToolValidating {
    func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? { nil }
}
extension SwiftToolDispatcher: PreApprovalToolValidating {
    /// Everything that must be true before a tool call is worth a person's
    /// attention: its arguments are ones the
    /// implementation will accept. Returns the tool error to hand back to the
    /// model, or nil to go on and file the approval.
    public func preApprovalRefusal(
        tool requestedTool: String, input rawInput: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        let tool = CanonicalToolNameDispatcher.canonical(requestedTool)
        let input = ChatToolSessionInjection.apply(toolName: tool, input: rawInput)
        do {
            if let refusal = try await MacAppActGate.requestRefusal(tool: tool, input: input, dataRoot: dataRoot) {
                return .object(refusal.fields)
            }
        } catch { return ChatToolOutcome.failure(error: error, effects: .none) }
        // A switch User turned off is admission, not an inside check: a preview
        // refuses exactly what the act would.
        if let gate = MacIntegrationGates.byTool[tool] {
            do {
                if let refusal = try await Self.switchRefusal(integration: gate.integration, mode: gate.mode,
                                                              store: macIntegrationPermissionStore) { return refusal }
            } catch { return ChatToolOutcome.failure(error: error, effects: .none) }
        }
        if let refusal = await argumentRefusal(tool: tool, input: input) { return refusal }
        if tool == "studio_canon_resolve",
           case .failure(let refusal) = StudioCanonSeatGate.liveTurnProvenance(dispatchSurface: surface) {
            return .object(["status": .string("refused"), "refusal": .string(refusal.rawValue),
                "reason": .string("\(tool): \(refusal.spoken). It is done from inside your own conversation, in your own turn.")])
        }
        if tool == "studio_shelf_set" {
            let result = await impl_studio_shelf(input: input, surface: surface, set: true, preview: true)
            if case .object(let fields) = result, fields["status"] != .string("would") { return result }
        }
        if let refusal = agentHostSetupRefusal(tool: tool, input: input) { return refusal }
        if let refusal = await standingBotsArgumentRefusal(tool: tool, input: input) { return refusal }
        // Unavailable Mac-control categories answer before approval admission,
        // using the tool's same Full Mac and surface-trigger access verdict.
        if Self.screenControlToolNames.contains(tool) || Self.fileAccessGatedToolNames.contains(tool) {
            do {
                let access = try await fullMacToolAccess(surface: surface)
                if Self.screenControlToolNames.contains(tool), !access.accessibilityAllowed,
                   let need = macControlCategoryNeedEnvelope(
                       categories: ["accessibility"], mode: Self.screenControlReadToolNames.contains(tool) ? .read : .write,
                       why: "Screen control lets me read and control apps on your Mac.") {
                    return need
                }
                if Self.fileAccessGatedToolNames.contains(tool), !access.fileOpsAllowed {
                    return builderFullMacRequired(tool: tool, input: input)
                }
            } catch { return ChatToolOutcome.failure(error: error) }
        }
        return nil
    }
    /// Every chat tool whose own gate is `builderFullMacRequired` whatever
    /// its input (dispatch: shell, bash, git, apply_patch, the build and
    /// remote-node tools, install and restart).
    static let fileAccessGatedToolNames: Set<String> = ["shell", "bash", "git", "apply_patch", "swift_build", "swift_test",
        "remote_node_list", "remote_node_execute", "install_app", "restart_app"]

    /// Every chat tool whose own gate needs the accessibility category, and
    /// those of them that only read. A part's hands on its watch are act's.
    static let screenControlReadToolNames = Set(fullMacAccessibilityReadToolNames + macMenuReadToolNames
        + macClipboardReadToolNames + macReadToolNames)
    static let screenControlToolNames = screenControlReadToolNames.union(["act", "go"] + fullMacAccessibilityInjectionToolNames
        + macClipboardWriteToolNames + macMenuPressToolNames).union(AuthoredToolEffects.handOperations)

    /// Connect-by-name, before a card exists. An agent this build has no row
    /// for, or one that is not installed, is a certain "no" — the person should
    /// never be asked to approve a setup that was always going to fail.
    private func agentHostSetupRefusal(tool: String, input: [String: JSONValue]) -> JSONValue? {
        guard let proposal = agentHostProposal(tool: tool, input: input) else { return nil }
        switch proposal {
        case .success: return nil
        case .failure(let error):
            if let failure = error as? ToolFailureError { return ChatToolOutcome.failure(error: failure) }
            guard error is AgentHostConnection.Refusal else {
                return ChatToolOutcome.failure(error: ToolFailureError(
                    "The named agent's setup could not be prepared: \(error.localizedDescription). Nothing was changed.",
                    effects: .none, owner: "Agent connection setup", code: "agent_setup_unavailable",
                    instruction: "Repair the reported contact or setup storage error, then request this connection again.", recovery: .repair))
            }
            return .object(["status": .string("not_supported"),
                            "tool": .string(tool),
                            "changed": .bool(false),
                            "known_agents": .array(AgentHostDirectory.knownNames.map(JSONValue.string)),
                            "detail": .string(error.localizedDescription)])
        }
    }
    /// Nil unless this really is an `agent_connect` with a name and nothing
    /// else — the by-name setup path and no other shape of the call.
    private func agentHostProposal(tool: String, input: [String: JSONValue])
        -> Result<AgentHostConnection.Proposal, any Error>? {
        guard usesCanonicalBody, AgentHostConnection.isNamedConnect(tool: tool, input: input),
              case .string(let name)? = input["name"] else { return nil }
        let folder: String?
        if case .string(let path)? = input["working_directory"] { folder = path } else { folder = nil }
        let workspace: String?
        if case .string(let value)? = input["workspace"] { workspace = value } else { workspace = nil }
        do { return .success(try AgentHostConnection.propose(name: name, store: AgentPeerStore(dataRoot: dataRoot), dataRoot: dataRoot, workspace: workspace, workingDirectory: folder)) }
        catch { return .failure(error) }
    }
    /// ONE approval card covers the disclosed setup and nothing else, in the
    /// words `AgentHostConnection.cardText` writes.
    public func approvalCardReason(
        tool requestedTool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        let tool = CanonicalToolNameDispatcher.canonical(requestedTool)
        // ACP's live connect card binds the exact resolved executable; its
        // version is read only after approval. It is also required when ordinary tool trust allows.
        if tool == "agent_connect", case .string(let name)? = input["name"],
           AgentHostDirectory.row(named: name)?.acp != nil { return nil }
        if let sentence = standingBotApprovalReason(tool: tool, input: input) {
            return sentence
        }
        // Reconnect can add or reconcile messaging allowances too; an existing
        // contact still needs the same setup disclosure on its approval card.
        guard let proposed = agentHostProposal(tool: tool, input: input) else { return nil }
        let proposalValue: AgentHostConnection.Proposal
        switch proposed {
        case .success(let value): proposalValue = value
        case .failure(let error): return "This connection's setup is unavailable: \(error.localizedDescription). Repair that cause before approving this connection."
        }
        var proposal = proposalValue
        // The approved replay carries this exact observation, not a later PATH lookup.
        if case .string(let path)? = input["executable_path"] { proposal.executablePath = path }
        else { proposal.executablePath = nil }
        return AgentHostConnection.cardText(proposal, appName: Self.appDisplayName, agentName: PersonaCompiler.agentDisplayName())
    }
    /// The product's own name for the card's title. Not a persona name.
    public static var appDisplayName: String {
        let bundle = Bundle.main
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "this app" : trimmed
    }
}
