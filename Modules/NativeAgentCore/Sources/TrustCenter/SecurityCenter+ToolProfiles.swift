import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
// Blueprint: | `SecurityCenter+ToolProfiles.swift` | AuthoredToolEffects.shellReadOnlyWords certifies literal shell reads for gates, receipts and fixed-argv read confinement; canonicalToolRisk and declared effect projection; app-call read treatment delegates to PermissionLaw.toolClass, with argument policy and display severity |

/// Primitive effects retain the authored envelope and the turn's ordinary gates.
public enum AuthoredToolEffects {
    @TaskLocal public static var admissionOnly = false
    @TaskLocal public static var call: (tool: String, perform: @Sendable () async throws -> JSONValue)?

    /// Certify only a single, literal read command. Shell syntax, expansion,
    /// unknown programs and unknown flags retain write authority. The launch
    /// owner binds these words to system executables under read confinement.
    public static func shellReadOnlyWords(_ input: [String: JSONValue]) -> [String]? {
        let literal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /._-:=@%,+")
        guard case .string(let command)? = input["cmd"], !command.isEmpty,
              command.unicodeScalars.allSatisfy(literal.contains) else { return nil }
        var words = command.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let paths = ["pwd": "/bin/pwd", "df": "/bin/df", "uname": "/usr/bin/uname",
                     "whoami": "/usr/bin/whoami", "uptime": "/usr/bin/uptime", "git": "/usr/bin/git"]
        let name = URL(fileURLWithPath: first).lastPathComponent
        guard let path = paths[name], first == name || first == path else { return nil }
        words[0] = path
        let args = Array(words.dropFirst())
        switch name {
        case "pwd": return args.allSatisfy { ["-L", "-P"].contains($0) } ? words : nil
        case "whoami", "uptime": return args.isEmpty ? words : nil
        case "df", "uname": return words // These programs have no mutating operation.
        case "git":
            guard let operation = args.first, ["log", "status", "diff", "show"].contains(operation) else { return nil }
            let flags: Set<String> = ["--oneline", "--stat", "--name-only", "--name-status", "--short", "--branch",
                "--porcelain", "--porcelain=v1", "--porcelain=v2", "--no-pager", "--no-ext-diff", "--no-textconv",
                "--staged", "--cached", "--patch", "--no-patch", "--all", "--decorate", "--no-decorate",
                "--reverse", "--no-merges", "--first-parent", "--", "-n", "-p", "-s", "-b"]
            guard args.dropFirst().allSatisfy({ arg in
                !arg.hasPrefix("-") || flags.contains(arg)
                    || arg.dropFirst().allSatisfy(\.isNumber) && arg.count > 1
                    || arg.hasPrefix("-n") && arg.count > 2 && arg.dropFirst(2).allSatisfy(\.isNumber)
                    || ["--max-count=", "--since=", "--until=", "--format=", "--pretty="].contains(where: arg.hasPrefix)
            }) else { return nil }
            return words
        default: return nil
        }
    }

    public static func shellReadOnly(_ tool: String, input: [String: JSONValue]) -> Bool {
        ["shell", "bash"].contains(ToolNameAliases.canonical(tool)) && shellReadOnlyWords(input) != nil
    }

    /// A watching part's hands on the window it watches (MacScreenWatch): act's effects.
    public static let handOperations: Set<String> = ["hand.click", "hand.double_click", "hand.right_click", "hand.move",
                                                     "hand.drag", "hand.key", "hand.hold", "hand.down", "hand.up"]
    public static let primitiveCapabilities: [String: Set<String>] = [
        "network.receive": ["safe_read", "network_read"],
        "network.connect": ["network_write"], "network.listen": ["network_write"],
        "network.accept": ["network_write"], "network.close": ["network_write"],
        "network.send": ["network_write", "external_send"],
        "apps.call": ["applescript", "system_control"],
        "screen.watch": ["safe_read"], "screen.next": ["safe_read"], "frame.read": ["safe_read"],
        // A program she starts is a command line: the shell's own class. Its
        // talk runs inside that start's admission.
        "program.start": ["process_spawn", "shell"], "program.send": ["process_spawn"],
        "program.receive": ["safe_read"], "program.close": ["process_spawn"],
    ].merging(handOperations.map { ($0, ["mac_control", "ax_injection"]) }) { $1 }

    public static func appReadOnly(_ args: [String: JSONValue]) -> Bool {
        // Read-only script declarations are enforced per event by MacControl's
        // send callback before the event reaches the app.
        if case .string? = args["script"] { return args["read_only"] == .bool(true) }
        return args["script"] == nil && (args["dictionary"] == .bool(true) || args["event_class"] == .string("core")
            && [.string("getd"), .string("cnte"), .string("doex")].contains(args["event_id"] ?? .null))
    }

    public static func primitiveEffect(_ operation: String, arguments: JSONValue?) -> (tool: String, capabilities: Set<String>) {
        let args: [String: JSONValue] = if case .object(let fields)? = arguments { fields } else { [:] }
        if operation == "apps.call", case .object(let args)? = arguments, appReadOnly(args) {
            return (operation, ["safe_read", "applescript"])
        }
        if operation == "fetch" || operation.hasPrefix("fetch.") {
            let read = args["method"] == nil || arguments?.stringFields["method"]?.uppercased() == "GET"
            // A call carrying the person's secret acts as the person at that
            // service: one that only reads (GET or HEAD, no body) is a read; any
            // other is an effect and passes Trust as one.
            if operation == "fetch.secret" || operation == "fetch" && !Keyring.names(in: arguments ?? .null).isEmpty {
                return ("fetch.secret", (read || arguments?.stringFields["method"]?.uppercased() == "HEAD") && args["body"] == nil
                    ? ["safe_read", "network_read", "secrets"] : ["network_write", "external_send", "secrets"])
            }
            return ("fetch.keyless", read
                ? ["network_public", "safe_read", "network_read"] : ["network_public", "network_write", "external_send"])
        }
        return (operation, primitiveCapabilities[operation] ?? ["destructive"])
    }
}

/// Read-only projection of SecurityCenter's canonical tool profile risk.
/// Consumers may use this metadata for advisory behavior, but it grants no
/// authority and does not replace effect-time SecurityCenter evaluation.
public enum CanonicalToolRisk: String, Sendable, Codable, Comparable {
    case low
    case medium
    case high
    case critical

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

extension SwiftNativeSecurityCenter {
    struct ToolProfile: Sendable {
        var capabilities: Set<String>
        var risk: CanonicalToolRisk
    }

    /// Classify a tool through the same profile owner used by authorization.
    /// This is deliberately pure: it does not read policy, assess origins,
    /// record receipts, or imply that the tool is allowed to run.
    public static func canonicalToolRisk(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> CanonicalToolRisk {
        profile(
            tool: policyToolName(tool),
            input: input,
            dataRoot: dataRoot,
            trustedWorkspaceRoots: trustedWorkspaceRoots
        ).risk
    }

    /// Project the declaration; argument policy only narrows the declared effects.
    static func profile(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> ToolProfile {
        if AuthoredToolEffects.primitiveCapabilities[tool] != nil || tool.hasPrefix("fetch.") {
            let effects = AuthoredToolEffects.primitiveEffect(tool, arguments: .object(input)).capabilities.union(["tool_call"])
            return ToolProfile(capabilities: effects, risk: displayRisk(toolClass: PermissionLaw.effectClass(effects), capabilities: effects))
        }
        let name = ToolNameAliases.canonical(tool)
        let schema = AppActionBinding.declaredSchema(name)
            ?? connectorActionIDs.first(where: { $0.value == tool }).flatMap { AppActionBinding.declaredSchema($0.key) }
        let binding: AppActionBinding? = if tool == "app" { AppActionBinding.action(input: input) }
            else if schema == nil { AppActionBinding.action(tool: name, input: input)
                ?? AppActionBinding.binding(ToolNameAliases.authoredAction(name)) }
            else { nil }
        var capabilities = schema?.capabilities ?? binding?.descriptor?.schema.capabilities ?? binding?.capabilities ?? ["tool_call"]
        if AuthoredToolEffects.shellReadOnly(name, input: input) {
            capabilities = ["tool_call", "safe_read"]
        }
        if tool == "app" {
            if PermissionLaw.toolClass(name, input: input) == .read {
                capabilities = ["tool_call", "safe_read"]
            } else {
                capabilities = binding?.capabilities ?? capabilities.subtracting(["safe_read"])
                capabilities.remove("safe_read")
            }
        }
        switch schema?.effectInputPolicy ?? .fixed {
        case .fixed: break
        case .agentConnection:
            if ["endpoint", "app_bundle_id"].contains(where: { input[$0] != nil && input[$0] != .string("") }) {
                capabilities.remove("other_app_settings_write")
            }
        case .agentMessage:
            capabilities.subtract(input["dry_run"] == .bool(true) ? ["external_send", "network_write"] : ["network_read", "app_data_write"])
            if !messagesAnAgentHostByCommand(input["agent"], dataRoot: dataRoot) {
                capabilities.subtract(["shell", "process_spawn"])
            }
        }
        if !capabilityWritesOutsideAppData(tool: name, input: input, dataRoot: dataRoot, trustedWorkspaceRoots: trustedWorkspaceRoots) {
            capabilities.remove("outside_app_data_write")
        }
        return ToolProfile(capabilities: capabilities, risk: displayRisk(
            toolClass: schema?.toolClass ?? binding?.toolClass ?? .write, capabilities: capabilities))
    }

    /// Display metadata only. PermissionLaw.answer owns authority.
    private static func displayRisk(toolClass: ToolClass, capabilities: Set<String>) -> CanonicalToolRisk {
        let severity: [String: CanonicalToolRisk] = [
            "shell": .critical, "filesystem_delete": .critical, "destructive": .critical,
            "system_control": .critical, "money": .critical, "remote_effect": .critical,
            "process_spawn": .high, "credential_write": .high, "other_app_settings_write": .high,
            "outside_app_data_write": .high, "ax_injection": .high, "mac_control": .high,
            "browser_interaction": .high, "external_send": .high, "approval_stage": .high, "secrets": .high,
            "filesystem_write": .medium, "app_data_write": .medium, "network_write": .medium,
            "clipboard_write": .medium, "notification": .medium, "image_generation": .medium,
            "workshop_write": .medium, "ledger_write": .medium, "agent_delegate": .high,
        ]
        return capabilities.map { capability in
            capability == "external_send" && capabilities.contains("notification") ? .medium : severity[capability] ?? .low
        }.max() ?? (toolClass == .read ? .low : .medium)
    }


    /// Whether an `agent_message` handle names an agent-host contact whose host
    /// actually HAS a command line — the only kind that runs anything. The
    /// contact's endpoint is `mcp://<host row id>`, and its recipe, as the
    /// store validated it (`AgentHostLaunches`), is the one the adapter reads.
    /// Contacts with no command line run no command and keep the ordinary
    /// send risk. The contact is read straight off its file rather than
    /// through the chat module, which depends on this one.
    /// Anything unreadable is not shell-class: the run itself is gated again at
    /// dispatch, and a guess here would only misprice the card.
    static func messagesAnAgentHostByCommand(_ handle: JSONValue?, dataRoot: URL) -> Bool {
        guard let raw = handle?.scalarText, raw.hasPrefix("peer:") else { return false }
        let id = String(raw.dropFirst("peer:".count)).lowercased()
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              let data = try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let contact = rows.first(where: { ($0["id"] as? String)?.lowercased() == id }),
              let transport = contact["transport"] as? String,
              ["mcpHost", "acp"].contains(transport),
              let endpoint = contact["endpoint"] as? String,
              endpoint.hasPrefix(transport == "acp" ? "acp://" : "mcp://") else { return false }
        let launch = AgentHostLaunches.launch(host: String(endpoint.dropFirst("mcp://".count)))
        return transport == "acp" ? launch.acp != nil : launch.commandLine != nil
    }

    /// The name a policy entry, profile and receipt are keyed on. Spellings
    /// resolve through the one alias table (`ToolNameAliases`); what is left
    /// here is not aliasing: a chat tool that fronts a connector action is
    /// judged as that action (`mac_notify` performs `mac.notify`), and no
    /// such action id is ever dispatched as a tool.
    package static func policyToolName(_ raw: String) -> String {
        let tool = ToolNameAliases.canonical(raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connectorActionIDs[tool] ?? tool
    }

    static let connectorActionIDs: [String: String] = [
        "mobile_notify": "mobile.notify",
        "mac_notify": "mac.notify",
    ]
}
