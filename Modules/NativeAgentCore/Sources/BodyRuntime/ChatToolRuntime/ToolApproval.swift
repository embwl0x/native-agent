import SenseCore
import MindCore
import MacNerves
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import ProviderRouting
// Blueprint: | `ToolApproval.swift` | PreApprovalToolValidating contract and SwiftToolDispatcher refusal/proposal wording before approval admission |
/// Reject unavailable tools and malformed arguments before filing an approval card.
public extension ToolDispatchClient {
    /// A call with no binding gets the door's refusal before consent; an unreadable catalog proves no absence.
    func unrecognizedAppActionRefusal(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
                                      invocation: ChatToolInvocation) async -> JSONValue? {
        guard tool == "app", case .string(let action)? = input["action"],
              !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            guard try AppActionBinding.action(input: input, turn: turn) == nil else { return nil }
        } catch {
            // Consent's existing checked read reports this failure; no missing action was established here.
            return nil
        }
        var call = input
        // Argument preflight supplies its own preview, including when the original call was already a preview. An unknown action has no target, so
        // its arguments cannot draw a Mac app or switch refusal in place of the door's own answer.
        call.removeValue(forKey: "preview")
        call.removeValue(forKey: "args")
        guard let refusal = await preApprovalRefusal(turn: turn, invocation: invocation,
            tool: tool, input: call, surface: surface) else { return nil }
        guard input["preview"] != .bool(true), case .object(var fields) = refusal else { return refusal }
        // These fields describe the argument preflight, not the call that was refused.
        for key in ["execution", "would_card", "approver"] { fields.removeValue(forKey: key) }
        return ChatToolOutcome.refusedBeforeRunning(.object(fields))
    }
}
extension SwiftToolDispatcher {
    /// Refuse arguments the implementation cannot accept before spending the person’s attention on approval.
    public func preApprovalRefusal(
        turn: Turn, invocation: ChatToolInvocation,
        tool requestedTool: String, input rawInput: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        let tool = CanonicalToolNameDispatcher.canonical(requestedTool)
        let input = ChatToolSessionInjection.apply(turn: turn, toolName: tool, input: rawInput)
        do {
            if let refusal = try await MacAppActGate.requestRefusal(tool: tool, input: input, dataRoot: dataRoot, turn: turn,
                context: invocation.macContext(dataRoot: dataRoot)) {
                return .object(refusal.fields)
            }
        } catch { return ChatToolOutcome.failure(error: error, effects: .none) }
        // Check the user’s disabled switch at admission so preview refuses the same call as execution.
        do {
            if let gate = try Self.integrationGate(tool: tool, input: input, turn: turn),
               let refusal = try await Self.switchRefusal(integration: gate.integration, mode: gate.mode, store: macIntegrationPermissionStore) {
                return refusal
            }
        } catch { return ChatToolOutcome.failure(error: error, effects: .none) }
        if let refusal = await argumentRefusal(tool: tool, input: input, turn: turn, execution: invocation.callExecution) { return refusal }
        do {
            if let action = ActionCatalog.current.tools[tool],
               let check = action.bound(input, invocation: invocation).preflight,
               let refusal = try await check(ActionContext(client: self, turn: turn, invocation: invocation, tool: tool,
                   surface: surface, deskState: nil, transportMetadata: input.filter { $0.key.hasPrefix("__") })) { return refusal }
        } catch { return ChatToolOutcome.failure(error: error, effects: .none) }
        // Unavailable Mac-control categories answer before approval admission, using the tool's same Full Mac and surface-trigger access verdict.
        if Self.screenControlToolNames.contains(tool) || Self.fileAccessGatedToolNames.contains(tool) {
            do {
                let access = try await fullMacToolAccess(turn: turn, surface: surface)
                if Self.screenControlToolNames.contains(tool), !access.accessibilityAllowed,
                   let need = macControlCategoryNeedEnvelope(invocation: invocation,
                       categories: ["accessibility"], mode: Self.screenControlReadToolNames.contains(tool) ? .read : .write,
                       why: "Screen control lets me read and control apps on your Mac.") {
                    return need
                }
                if Self.fileAccessGatedToolNames.contains(tool), !access.fileOpsAllowed {
                    return builderFullMacRequired(invocation: invocation, tool: tool, input: input)
                }
            } catch { return ChatToolOutcome.failure(error: error) }
        }
        return nil
    }
    /// Every chat tool whose own gate is `builderFullMacRequired` whatever its input (dispatch: shell, bash, git, apply_patch, the build and remote-node tools,
    /// install and restart).
    static let fileAccessGatedToolNames: Set<String> = ["shell", "bash", "git", "apply_patch", "swift_build", "swift_test",
        "remote_node_list", "remote_node_execute", "install_app", "restart_app"]

    /// Every chat tool whose own gate needs the accessibility category, and those of them that only read. A part's hands on its watch are act's.
    static let screenControlReadToolNames = Set(fullMacAccessibilityReadToolNames + macMenuReadToolNames
        + macClipboardReadToolNames + macReadToolNames)
    static let screenControlToolNames = screenControlReadToolNames.union(["act", "go"] + fullMacAccessibilityInjectionToolNames
        + macClipboardWriteToolNames + macMenuPressToolNames).union(AuthoredToolEffects.handOperations)

    /// Refuse unsupported or uninstalled agents before asking the person to approve a setup that cannot work.
    func agentHostSetupRefusal(tool: String, input: [String: JSONValue]) -> JSONValue? {
        guard let proposal = Self.agentHostProposal(tool: tool, input: input, dataRoot: dataRoot, usesCanonicalBody: usesCanonicalBody) else { return nil }
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
    /// Nil unless this really is an `agent_connect` with a name and nothing else — the by-name setup path and no other shape of the call.
    private static func agentHostProposal(tool: String, input: [String: JSONValue], dataRoot: URL, usesCanonicalBody: Bool)
        -> Result<AgentHostConnection.Proposal, any Error>? {
        guard usesCanonicalBody, AgentHostConnection.isNamedConnect(tool: tool, input: input),
              case .string(let name)? = input["name"] else { return nil }
        let folder: String?
        if case .string(let path)? = input["working_directory"] { folder = path } else { folder = nil }
        let workspace: String?
        if case .string(let value)? = input["workspace"] { workspace = value } else { workspace = nil }
        do { return .success(try AgentHostConnection.propose(name: name, store: AgentPeerStore(dataRoot: dataRoot), dataRoot: dataRoot,
            workspace: workspace, workingDirectory: folder)) }
        catch { return .failure(error) }
    }
    public func approvalCardReason(tool requestedTool: String, input: [String: JSONValue], surface: String) async -> String? {
        let tool = CanonicalToolNameDispatcher.canonical(requestedTool)
        guard let action = ActionCatalog.current.tools[tool] else { return nil }
        do { return try await action.bind(input).approvalReason?(dataRoot, usesCanonicalBody) }
        catch { return ChatToolOutcome.errorMessage(error) }
    }

    static func hostApprovalReason(input: AgentConnectArgs, dataRoot: URL, usesCanonicalBody: Bool) -> String? {
        let input = input.wire
        // ACP's live connect card binds the exact resolved executable; its version is read only after approval. It is also required when ordinary tool trust
        // allows.
        if case .string(let name)? = input["name"],
           AgentHostDirectory.row(named: name)?.acp != nil { return nil }
        // Reconnect can add or reconcile messaging allowances too; an existing contact still needs the same setup disclosure on its approval card.
        guard let proposed = agentHostProposal(tool: "agent_connect", input: input, dataRoot: dataRoot, usesCanonicalBody: usesCanonicalBody) else { return nil }
        let proposalValue: AgentHostConnection.Proposal
        switch proposed {
        case .success(let value): proposalValue = value
        case .failure(
            let error): return "This connection's setup is unavailable: \(error.localizedDescription). Repair that cause before approving this connection."
        }
        var proposal = proposalValue
        // The approved replay carries this exact observation, not a later PATH lookup.
        if case .string(let path)? = input["executable_path"] { proposal.executablePath = path }
        else { proposal.executablePath = nil }
        let text = AgentHostConnection.cardText(proposal, appName: Self.appDisplayName, agentName: PersonaCompiler.agentDisplayName())
        guard input["reopen"] == .bool(true), proposal.row.restartRequired else { return text }
        return text + "\nThen \(proposal.row.displayName) is quit and opened again, so it loads the entry now."
    }
    /// Use the product’s name for approval titles, independent of persona identity.
    public static var appDisplayName: String {
        let bundle = Bundle.main
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "this app" : trimmed
    }
}
