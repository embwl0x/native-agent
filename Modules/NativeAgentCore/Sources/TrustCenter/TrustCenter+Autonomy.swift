import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
// Blueprint: | `TrustCenter+Autonomy.swift` | `PermissionLaw`: one posture, class, reach and effective level for authorization and scheduling |

// MARK: - The permission law

public enum PermissionPosture: Sendable {
    case fullMac
    /// Work asks before sends or changes to the person's world.
    case work
    /// Safe: nothing beyond the agent's own domain changes.
    case readOnly
}

/// Every executor shares judgment from declared class, saved posture, integration switch and steering authority. The agent's data and workspace roots are its
/// own; external paths, accounts, apps and shared remotes reach the person. Irreversible changes on the person's side always ask; Safe cannot change that side.
public enum PermissionLaw {
    /// Request ceilings precede coordination, consent and effects. A wider saved posture or nested chain cannot lift them.
    public static func requestFileAccessRefusal(tool: String, input: [String: JSONValue], turn: Turn?) throws -> ToolFailureError? {
        guard let turn else { return nil }
        let ceiling = turn.fileAccessCeiling
        let control = "the originating request's fileAccess setting (phone: Chat > File access)"
        if let invalid = ceiling.invalidMode {
            return ToolFailureError("request.fileAccess=\(invalid) is unrecognized; no file access was inferred.",
                argumentPath: "request.fileAccess", accepted: ICloudChatFileAccessPolicy.acceptedIDs.sorted().joined(separator: ", "), effects: .none,
                instruction: "Correct \(control) to a recognized mode, then submit a new request. Accepted modes: "
                    + ICloudChatFileAccessPolicy.acceptedIDs.sorted().joined(separator: ", ") + ".")
        }
        if ceiling.noPathfulReads, ToolNameAliases.canonical(tool) == "read",
           case .string(let path)? = input["path"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolFailureError("request.fileAccess=none blocks read with an explicit path. The request issuer must resubmit with file access.",
                effects: .none, owner: "request.fileAccess", tap: control, personDecides: true,
                code: "request_file_access_none", status: .refused,
                instruction: "Ask the request issuer to grant Read only (fileAccess=read_only) or the intended broader access at \(control), "
                    + "then submit a new request. Every originating ceiling carried by the request must permit explicit-path reads.")
        }
        if ceiling.readOnly, try toolClass(tool, input: input, turn: turn) != .read {
            return ToolFailureError("request.fileAccess=read_only blocks \(tool); nothing ran. The request issuer must resubmit with write access.",
                effects: .none, owner: "request.fileAccess", tap: control, personDecides: true,
                code: "request_read_only", status: .refused,
                instruction: "Ask the request issuer to grant changes at \(control): Auto (fileAccess=auto), Workspace (workspace) or Full Mac (full), "
                    + "as intended, then submit a new request. Every originating ceiling carried by the request must permit changes; "
                    + "an approval cannot widen read_only.")
        }
        return nil
    }

    public static let fullMacContract = """
        Under Full Mac I make changes without asking. Permanent deletion still asks, and an untrusted agent's initiating turn asks once at its first \
        effect, quoting its ask; your answer covers that turn and lifts its Work-mode cap. macOS privacy resets still ask.
        """

    public static func posture(_ policy: [String: JSONValue]) -> PermissionPosture {
        posture(permissionLevel: policy["permissionLevel"]?.scalarText ?? "",
                outsideWorkspaceDefault: (
                    SwiftNativeSecurityCenter.object(policy["filePolicy"])["outsideWorkspaceDefault"])?.scalarText ?? "")
    }

    /// All gates read the same saved pair so it cannot express different postures.
    public static func posture(permissionLevel: String, outsideWorkspaceDefault: String) -> PermissionPosture {
        if outsideWorkspaceDefault == "allow" || permissionLevel == "full_mac_os" { return .fullMac }
        return permissionLevel == "strict" ? .readOnly : .work
    }

    /// Authorization and by-name Trust reads share the same effective answer and remedy.
    public static func answer(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue],
                              dataRoot: URL, turn: Turn?) throws -> (toolClass: ToolClass, level: String, reason: String, remedy: JSONValue?) {
        let roots = SwiftNativeSecurityCenter.trustedWorkspaceRoots(
            filePolicy: SwiftNativeSecurityCenter.object(policy["filePolicy"]), dataRoot: dataRoot)
        let capabilities = try input.map { try SwiftNativeSecurityCenter.profile(tool: SwiftNativeSecurityCenter.policyToolName(tool),
                                                                         input: $0, dataRoot: dataRoot, turn: turn, trustedWorkspaceRoots: roots).capabilities }
        return try answer(tool: tool, input: input, policy: policy, capabilities: capabilities, turn: turn)
    }

    static func answer(tool: String, input: [String: JSONValue]?, policy: [String: JSONValue],
                       capabilities: Set<String>?, turn: Turn?) throws -> (toolClass: ToolClass, level: String, reason: String, remedy: JSONValue?) {
        // Steering caps the posture: a turn an untrusted peer steered is judged as Work at most.
        let peer = CapabilityLifecycle.turnWriteCheck(turn)()
        let capped = peer != nil && posture(policy) == .fullMac
        let posture = capped ? .work : posture(policy)
        let (toolClass, level) = try judge(tool: tool, input: input, posture: posture, capabilities: capabilities, turn: turn)
        let mode = posture == .fullMac ? "Full Mac" : posture == .readOnly ? "Safe" : "Work mode"
        // A part's verb is named by the verb it carries, not the part that runs it.
        let named = try AppActionBinding.answeredVerb(tool: tool, input: input ?? [:], turn: turn)
            ?? (tool == "app" ? input?["action"]?.stringValue : nil) ?? tool
        if let refusal = try requestFileAccessRefusal(tool: tool, input: input ?? [:], turn: turn) {
            return (toolClass, "blocked", refusal.localizedDescription, refusal.remedy())
        }
        if let input, personDecided(tool: tool, input: input, turn: turn) {
            return (toolClass, level, "The person decided \(named) themself; it runs as theirs.", nil)
        }
        if let input, let lever = try lever(tool: tool, input: input, turn: turn) {
            let why = "\(named) is the person's lever: \(lever.why)."
            let reason = level == "confirm" ? why + " The agent's call asks them on a card and runs only on their yes."
                : lever.asks ? why + " Safe allows no ask for it; nothing ran."
                : why + " It needs the person themself, so the agent's call is refused; nothing ran."
            return (toolClass, level, reason, Repair.why(owner: "the person's lever \(named)",
                tap: level == "confirm" ? "the card it raised (Approve or Decline)" : "its own row, on the person's Mac or phone"))
        }
        var reason = "trust/policy.json: \(mode) judges \(named) as \(toolClass), autonomy=\(level)."
        if capped, let peer {
            let who = peer.message.components(separatedBy: ", so ").first.map { $0.replacingOccurrences(of: "This turn was steered by ", with: "") }
                ?? "another agent"
            reason += " Full Mac is capped to Work mode while \(who) steers this turn; your answer to its card lifts it."
        }
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

    /// The call's class, reach and posture decide act, ask or refuse. With no input, only its declaration counts.
    static func judge(tool: String, input: [String: JSONValue]?, posture: PermissionPosture,
                      capabilities: Set<String>?, turn: Turn?) throws -> (toolClass: ToolClass, level: String) {
        let toolClass = try toolClass(tool, input: input ?? [:], turn: turn)
        // The person's own act decides its exact call at every posture: a posture is what the agent may do, never what the person may.
        if let input, personDecided(tool: tool, input: input, turn: turn) { return (toolClass, "auto") }
        // A lever is never the agent's call, at any posture: it raises the person's card, or is refused where no card can carry it or Safe
        // allows no ask.
        if let input, let lever = try lever(tool: tool, input: input, turn: turn) {
            return (toolClass, lever.asks && posture != .readOnly ? "confirm" : "blocked")
        }
        let users = try toolClass >= .send || reachesUser(tool, input: input, capabilities: capabilities ?? [], turn: turn)
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

    /// Authorization and scheduling share input-aware class resolution; only owner-certified shell commands narrow to reads.
    public static func toolClass(_ tool: String, input: [String: JSONValue], turn: Turn?) throws -> ToolClass {
        let name = ToolNameAliases.canonical(tool)
        if AuthoredToolEffects.shellIrreversible(name, input: input) { return .destructive }
        if AuthoredToolEffects.shellReadOnly(name, input: input) { return .read }
        if name == "app" {
            let named = if case .string(let text)? = input["action"] {
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else { false }
            // Composition has no effect of its own: scripts and batches re-enter admission for each step's class.
            // Folded actions likewise re-enter under their tool name; discovery and preview have no effects.
            guard named, input["preview"] != .bool(true) else { return .read }
            guard let action = try AppActionBinding.action(input: input, turn: turn) else { return .write }
            return declaredRead(action) || action.folded ? .read : action.toolClass
        }
        if AuthoredToolEffects.isPrimitiveEffect(name) {
            return effectClass(AuthoredToolEffects.primitiveEffect(name, arguments: .object(input)).capabilities)
        }
        let action = try AppActionBinding.action(tool: name, input: input, turn: turn) ?? AppActionBinding.binding(ToolNameAliases.authoredAction(name),
            turn: turn)
        if let action, declaredRead(action) { return .read }
        let native = AppActionBinding.declaredClass(name)
        let declared = native ?? action?.toolClass ?? .write
        // Only a native send declares a dry run; a part's verb is judged by its class whatever its arguments say.
        return native == .send && input["dry_run"] == .bool(true) ? .write : declared
    }

    private static func declaredRead(_ action: AppActionBinding) -> Bool {
        action.read && (action.toolClass == .read ||
            (!action.readWhen.isEmpty && AppActionBinding.builtInToolName(action.tool)))
    }

    /// Whether the person decided this exact call (`Turn.personAct`): the call itself, or the tool it folds into as the door runs it.
    public static func personDecided(tool: String, input: [String: JSONValue], turn: Turn?) -> Bool {
        personForm(tool: tool, input: input, turn: turn) != nil
    }

    /// The gate's admission of a dispatch: the turn keeps the person's act only for the call it covers, once per form in one run; any other
    /// call, and the same call made again inside the run, is judged without it (as the agent's).
    public static func admitting(tool: String, input: [String: JSONValue], turn: Turn) -> Turn {
        guard let act = turn.personAct else { return turn }
        guard let form = personForm(tool: tool, input: input, turn: turn), act.spend(form) else { return turn.with(\.personAct, nil) }
        return turn
    }

    private static func personForm(tool: String, input: [String: JSONValue], turn: Turn?) -> PersonAct.Form? {
        guard let act = turn?.personAct else { return nil }
        if act.covers(tool: tool, input: input) { return .call }
        guard act.tool == "app", case .string(let action)? = act.input["action"],
              let binding = AppActionBinding.declaredBinding(action), binding.folded else { return nil }
        let ran = ToolNameAliases.ranCall("app", input: act.input)
        // The folded tool's own call: the person's arguments under its names, plus only what the action itself fixes (and the door's own
        // `__` keys, which carry no argument).
        guard ran.tool == ToolNameAliases.canonical(tool), ran.input.allSatisfy({ input[$0.key] == $0.value }),
              input.filter({ !$0.key.hasPrefix("__") }).allSatisfy({ ran.input[$0.key] != nil || binding.fixedInput[$0.key] == $0.value })
        else { return nil }
        return .folded
    }

    /// The lever this call is, if it is one (`AppActionBinding.lever`): an `app` action, or a tool an `app` lever folds into.
    public static func lever(tool: String, input: [String: JSONValue], turn: Turn?) throws -> AppActionBinding.Lever? {
        // A preview changes nothing, so it asks no one.
        guard !(tool == "app" && input["preview"] == .bool(true)) else { return nil }
        return try AppActionBinding.action(tool: tool, input: input, turn: turn)?.lever
    }

    /// Judge folded actions by the tool they actually dispatch; a missing action has no class.
    public static func doorClass(action: String, args: [String: JSONValue], turn: Turn?) throws -> ToolClass? {
        let call: [String: JSONValue] = ["action": .string(action), "args": .object(args)]
        guard try AppActionBinding.action(input: call, turn: turn) != nil else { return nil }
        let ran = ToolNameAliases.ranCall("app", input: call)
        return try toolClass(ran.tool, input: ran.input, turn: turn)
    }

    /// Unknown reach counts on the person's side, including arbitrary command lines. Owned data, workspace and extension tabs remain the agent's; folded calls
    /// are judged under their tool.
    static func reachesUser(_ tool: String, input: [String: JSONValue]?, capabilities: Set<String>, turn: Turn?) throws -> Bool {
        let name = ToolNameAliases.canonical(tool)
        if input != nil, !capabilities.isDisjoint(with: [
            "outside_app_data_write", "other_app_settings_write", "system_control", "system_permission_reset",
            "ax_injection", "mac_control", "clipboard_write", "remote_effect",
        ]) { return true }
        if name == "app" { return false }
        if let schema = AppActionBinding.declaredSchema(name) { return schema.reach == .person }
        return try AppActionBinding.binding(ToolNameAliases.authoredAction(name), turn: turn)?.reach != .agent
    }

    /// Irreversible effects on the person's side need their tap even under Full Mac, including cards carrying nested tool arguments.
    public static func humanDecides(action: String, payload: JSONValue, turn: Turn?) throws -> Bool {
        guard case .object(let payload) = payload else { return false }
        var input: [String: JSONValue] = [:]
        if case .object(let fields)? = payload["input"] { input = fields }
        return try toolClass(action, input: input, turn: turn) == .destructive
    }

    /// Own data, model and localhost reach the agent's side; all other declared permissions reach the person.
    public static let agentReach: Set<String> = ["app_data_read", "app_data_write", "model", "network_localhost"]
    public static func reach(ofPermissions permissions: [String]) -> ToolReach {
        permissions.contains { !agentReach.contains($0) && !$0.hasPrefix("app_read:") } ? .person : .agent
    }

    public static func permissionClass(_ permission: String) -> ToolClass {
        // These grants can only read: app_read is enforced per Apple Event, and app_data_read admits only file readers in the owning root.
        if permission == "app_data_read" || permission.hasPrefix("app_read:") { return .read }
        guard AuthoredToolEffects.isPrimitiveEffect(permission) else { return .write }
        return effectClass(AuthoredToolEffects.primitiveEffect(permission, arguments: nil).capabilities)
    }

    static func effectClass(_ capabilities: Set<String>) -> ToolClass {
        if !capabilities.isDisjoint(with: ["destructive", "filesystem_delete", "system_permission_reset"]) { return .destructive }
        if capabilities.contains("external_send") { return .send }
        return capabilities.contains("safe_read") ? .read : .write
    }
}

extension SwiftNativeTrustCenter {
    /// Input-aware judgment through the same `PermissionLaw.answer` SecurityCenter uses.
    public func autonomyLevel(forTool toolName: String, input: [String: JSONValue]?, turn: Turn?) async throws -> String {
        try PermissionLaw.answer(tool: toolName, input: input, policy: try await loadTrustPolicyChecked(), dataRoot: dataRoot, turn: turn).level
    }

    nonisolated static func isoTimestamp(_ date: Date) -> String {
        SwiftNativeManifestSigner.isoTimestamp(date)
    }
}
