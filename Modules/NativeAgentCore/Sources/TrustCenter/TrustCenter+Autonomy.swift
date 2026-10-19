import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry

// MARK: - The permission law (User, 2026-10-17)

/// User's posture, as he set it in Trust.
public enum PermissionPosture: Sendable {
    /// Full Mac: she acts.
    case fullMac
    /// Work mode: she asks before a send or a change to User's world.
    case work
    /// Safe: nothing beyond her own domain changes.
    case readOnly
}

/// Every call is judged by four facts and nothing else: what it is (the class
/// its declaration gives it), User's posture, the integration switch it touches
/// (held before any card, and again at dispatch) and who steered the turn (an
/// untrusted peer meets the floor and the cards). Everything she is — chat,
/// bots, Workshop, swarm workers, every part she writes — gets the same answer:
/// a sub-agent is her hands, not a lesser user.
///
/// One line divides her world from User's. Hers: her data root and Trust's
/// workspace roots (her scratch, her worktrees, her abilities, bots, chats and
/// memory). His: a path beyond those roots, his accounts and integrations, his
/// Mac's apps, browser, settings and permissions, another app's settings, a
/// shared remote. Destructive is what cannot be undone on his side of it, and
/// always asks a person; Safe changes nothing on his side.
public enum PermissionLaw {
    public static let fullMacContract = "Under Full Mac I make changes without asking. Permanent deletion still asks you every time, and a request an untrusted agent steered is held to Work mode. macOS permissions and account setup still ask."

    public static func posture(_ policy: [String: JSONValue]) -> PermissionPosture {
        posture(permissionLevel: SwiftNativeSecurityCenter.string(policy["permissionLevel"]) ?? "",
                outsideWorkspaceDefault: SwiftNativeSecurityCenter.string(
                    SwiftNativeSecurityCenter.object(policy["filePolicy"])["outsideWorkspaceDefault"]) ?? "")
    }

    /// The one reading of the saved posture: every gate, page and self-admin
    /// check asks this, so one saved pair never means two postures.
    public static func posture(permissionLevel: String, outsideWorkspaceDefault: String) -> PermissionPosture {
        if MacControlGate.fullMacActive(MacControlTrustPolicy(outsideWorkspaceDefault: outsideWorkspaceDefault,
                                                              permissionLevel: permissionLevel)) { return .fullMac }
        return ["strict", "locked_down"].contains(permissionLevel) ? .readOnly : .work
    }

    /// The one effective answer for a call, with the reason and the lever
    /// that would change it. SecurityCenter (with the facts it already
    /// resolved) and Trust's by-name and Workshop answers both use it.
    public static func answer(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue],
                              dataRoot: URL) -> (toolClass: ToolClass, level: String, reason: String, remedy: JSONValue?) {
        let roots = SwiftNativeSecurityCenter.trustedWorkspaceRoots(
            policy: policy, filePolicy: SwiftNativeSecurityCenter.object(policy["filePolicy"]), dataRoot: dataRoot)
        let capabilities = input.map { SwiftNativeSecurityCenter.profile(tool: SwiftNativeSecurityCenter.policyToolName(tool),
                                                                         input: $0, dataRoot: dataRoot, trustedWorkspaceRoots: roots).capabilities }
        return answer(tool: tool, input: input, policy: policy, dataRoot: dataRoot, roots: roots, capabilities: capabilities)
    }

    static func answer(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue],
                       dataRoot: URL, roots: [URL], capabilities: Set<String>?) -> (toolClass: ToolClass, level: String, reason: String, remedy: JSONValue?) {
        // Steering caps the posture: a turn an untrusted peer steered is judged as Work at most.
        let peer = CapabilityLifecycle.turnWriteCheck()()
        let capped = peer != nil && posture(policy) == .fullMac
        let posture = capped ? .work : posture(policy)
        let (toolClass, level) = judge(tool: tool, input: input, posture: posture, dataRoot: dataRoot, roots: roots, capabilities: capabilities)
        let mode = posture == .fullMac ? "Full Mac" : posture == .readOnly ? "Safe" : "Work mode"
        var reason = "trust/policy.json: \(mode) judges \(tool) as \(toolClass), autonomy=\(level)."
        if capped, let peer { reason += " Full Mac is capped to Work mode by \(peer.message)" }
        let remedy: JSONValue?
        if level == "auto" {
            remedy = nil
        } else if capped, toolClass != .destructive, let peer, let tap = peer.tap {
            remedy = Repair.why(owner: peer.owner ?? "trust/policy.json", tap: tap)
        } else {
            remedy = Repair.why(owner: "Trust posture: \(mode)", tap: toolClass == .destructive
                ? "Today > approval card > Approve or Decline" : capped ? "Trust > Connected agents" : "Trust > Access and policy > Access")
        }
        return (toolClass, level, reason, remedy)
    }

    /// The one judgment: the call's class, and the level its class, its reach
    /// and User's posture give (act is `auto`, ask `confirm`, refuse `blocked`).
    /// With no input (a judgment by name) only what its declaration says counts.
    public static func judge(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue],
                             dataRoot: URL) -> (toolClass: ToolClass, level: String) {
        let roots = SwiftNativeSecurityCenter.trustedWorkspaceRoots(
            policy: policy, filePolicy: SwiftNativeSecurityCenter.object(policy["filePolicy"]), dataRoot: dataRoot)
        let capabilities = input.map { SwiftNativeSecurityCenter.profile(tool: SwiftNativeSecurityCenter.policyToolName(tool),
                                                                         input: $0, dataRoot: dataRoot, trustedWorkspaceRoots: roots).capabilities }
        return judge(tool: tool, input: input, posture: posture(policy), dataRoot: dataRoot, roots: roots, capabilities: capabilities)
    }

    /// The same judgment from the facts the caller already resolved for this
    /// call (SecurityCenter's roots and effect profile), each read once.
    static func judge(tool: String, input: [String: JSONValue]?, posture: PermissionPosture, dataRoot: URL,
                      roots: [URL], capabilities: Set<String>?) -> (toolClass: ToolClass, level: String) {
        let toolClass = toolClass(tool, input: input ?? [:])
        let users = toolClass >= .send || reachesUser(tool, input: input, capabilities: capabilities ?? [])
        let level: String = switch (toolClass, posture) {
        case (.read, _): "auto"
        case _ where !users: "auto"
        case (_, .readOnly): "blocked"
        case (.destructive, _): "confirm"
        case (_, .fullMac): "auto"
        case (_, .work): "confirm"
        }
        return (toolClass, level)
    }

    /// What this call is: a read where its binding reads for this input, else
    /// its declaration's class (a registered tool's schema, a door action's
    /// row, a part's reach, a host primitive's effect). A command line's text
    /// is never read: a shell or git call is the write its tool declares.
    static func toolClass(_ tool: String, input: [String: JSONValue]) -> ToolClass {
        let name = ToolNameAliases.canonical(tool)
        if name == "app" {
            let named = ["action", "script"].contains { key in
                if case .string(let text)? = input[key] { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                else if key == "script", case .array(let calls)? = input[key] { !calls.isEmpty }
                else { false }
            }
            // Home, a page read, find and a preview change nothing; a folded
            // action re-enters under its tool's name and is judged there.
            guard named, input["preview"] != .bool(true) else { return .read }
            guard let action = AppActionBinding.action(input: input) else { return .write }
            return action.read || action.folded ? .read : action.toolClass
        }
        if AuthoredToolEffects.primitiveCapabilities[name] != nil || name.hasPrefix("fetch.") {
            return effectClass(AuthoredToolEffects.primitiveEffect(name, arguments: .object(input)).capabilities)
        }
        // A part's or an MCP tool's declaration is the app action that folds it.
        let action = AppActionBinding.action(tool: name, input: input) ?? AppActionBinding.binding(ToolNameAliases.authoredAction(name))
            ?? (name.hasPrefix("mcp__") ? AppActionBinding.binding(name) : nil)
        if action?.read == true { return .read }
        let declared = AppActionBinding.declaredClass(name) ?? action?.toolClass ?? .write
        // A send's dry run reaches no one.
        return declared == .send && input["dry_run"] == .bool(true) ? .write : declared
    }

    /// Whether a write lands on User's side of the line: a command line (nobody
    /// knows what one reaches), a path beyond her roots (the path policy's own
    /// reading), another app's settings, his Mac's settings, apps or
    /// clipboard, a remote, his accounts (the Mac integration tools; a
    /// notification to him changes nothing of his), or anything whose
    /// declaration does not say where it reaches. Her app's own door actions
    /// are hers, and so are her Chrome extension's tabs; a folded door action
    /// re-enters under its tool's name.
    static func reachesUser(_ tool: String, input: [String: JSONValue]?, capabilities: Set<String>) -> Bool {
        let name = ToolNameAliases.canonical(tool)
        if SwiftNativeSecurityCenter.commandLineTools.contains(name.lowercased()) { return true }
        if input != nil, !capabilities.isDisjoint(with: [
            "outside_app_data_write", "other_app_settings_write", "system_control", "system_permission_reset",
            "ax_injection", "mac_control", "clipboard_write", "remote_effect",
        ]) { return true }
        if name == "app" || SwiftNativeSecurityCenter.notificationToolNames.contains(SwiftNativeSecurityCenter.policyToolName(name)) {
            return false
        }
        // One of her parts reaches what its own manifest declares.
        if let him = AppActionBinding.binding(ToolNameAliases.authoredAction(name))?.reachesHim { return him }
        guard let bucket = AppActionBinding.declaredBucket(name) else { return true }
        return [.macIntegration, .macControl, .system].contains(bucket)
    }

    /// Whether a card is a person's even under Full Mac: the call it carries
    /// cannot be undone on his side (User, 10-17: one card, a human's tap; her
    /// own approve never stands in for his). A chat tool's card carries the
    /// tool as its action and the call's `input`; a Workshop step's carries
    /// the step's `tool` and `args`.
    public static func humanDecides(action: String, payload: JSONValue) -> Bool {
        guard case .object(let payload) = payload else { return false }
        let step = ExecutionEventVocabulary.matches(action, WorkshopStepApprovalAction.canonical)
        var tool = action
        if step, case .string(let name)? = payload["tool"] { tool = name }
        var input: [String: JSONValue] = [:]
        if case .object(let fields)? = payload[step ? "args" : "input"] { input = fields }
        return toolClass(tool, input: input) == .destructive
    }

    /// A part's declared permission, as the primitive it names reaches.
    public static func permissionClass(_ permission: String) -> ToolClass {
        guard AuthoredToolEffects.primitiveCapabilities[permission] != nil || permission.hasPrefix("fetch") else { return .write }
        return effectClass(AuthoredToolEffects.primitiveEffect(permission, arguments: nil).capabilities)
    }

    static func effectClass(_ capabilities: Set<String>) -> ToolClass {
        if !capabilities.isDisjoint(with: ["destructive", "filesystem_delete", "system_permission_reset"]) { return .destructive }
        if capabilities.contains("external_send") { return .send }
        return capabilities.contains("safe_read") ? .read : .write
    }
}

extension SwiftNativeTrustCenter {
    /// The effective answer for a tool by name (catalog, planner).
    public func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
        try await autonomyLevel(forTool: toolName, input: nil)
    }

    /// The same, for a call whose input is known: `PermissionLaw.answer`, the
    /// one resolver SecurityCenter uses too.
    public func autonomyLevel(forTool toolName: String, input: [String: JSONValue]?) async throws -> String {
        PermissionLaw.answer(tool: toolName, input: input, policy: try await loadTrustPolicyChecked(), dataRoot: dataRoot).level
    }

    /// Format a Date with the shared TrustCenter timestamp helper.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        SwiftNativeManifestSigner.isoTimestamp(date)
    }
}
