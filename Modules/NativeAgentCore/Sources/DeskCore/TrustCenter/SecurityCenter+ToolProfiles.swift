import SenseCore
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SecurityCenter+ToolProfiles.swift` | Canonical effect classification; advisory metadata grants no authority. |

/// One authored operation's admission mode, passed by its owner.
public struct AuthoredEffectOptions: Sendable {
    public var admissionOnly: Bool
    public init(admissionOnly: Bool = false) { self.admissionOnly = admissionOnly }
}

/// The primitive implementation injected into the gated executor for this operation.
public struct AuthoredEffectExecutor: Sendable {
    public let call: (tool: String, perform: @Sendable () async throws -> JSONValue)
    public init(tool: String, perform: @escaping @Sendable () async throws -> JSONValue) {
        call = (tool, perform)
    }
}

/// Primitive effects retain the authored envelope and the turn's ordinary gates.
public enum AuthoredToolEffects {

    /// Certify only a single, literal read command. Shell syntax, expansion, unknown programs and unknown flags retain write authority. The launch owner binds
    /// these words to system executables under read confinement.
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
            // An operand names a revision or a path inside the working tree; git diff compares out-of-tree paths as plain files.
            guard args.dropFirst().allSatisfy({ arg in
                arg.hasPrefix("-") || !(arg.hasPrefix("/") || arg.hasPrefix("~") || arg == ".." || arg.hasPrefix("../") || arg.contains("/../"))
            }) else { return nil }
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

    /// Programs whose effect cannot be undone. A shell call whose command starts with one asks the person even under Full Mac (permanent deletion
    /// and macOS privacy resets are the person's). Only the first word counts: command text is never certified beyond it, so a deletion hidden inside a
    /// script or another program's arguments is not seen here.
    public static let irreversiblePrograms: Set<String> = ["rm", "rmdir", "srm", "unlink", "shred", "dd", "truncate", "tccutil", "diskutil"]

    public static func shellIrreversible(_ tool: String, input: [String: JSONValue]) -> Bool {
        guard ["shell", "bash"].contains(ToolNameAliases.canonical(tool)), case .string(let command)? = input["cmd"],
              let first = command.split(whereSeparator: \.isWhitespace).first else { return false }
        return irreversiblePrograms.contains(URL(fileURLWithPath: String(first)).lastPathComponent)
    }

    public static func shellReadOnly(_ tool: String, input: [String: JSONValue]) -> Bool {
        ["shell", "bash"].contains(ToolNameAliases.canonical(tool)) && shellReadOnlyWords(input) != nil
    }

    /// A watching part acts on its watched window under the same effect class as act.
    public static let handOperations: Set<String> = ["hand.click", "hand.double_click", "hand.right_click", "hand.move",
                                                     "hand.drag", "hand.key", "hand.hold", "hand.down", "hand.up"]
    public static let primitiveCapabilities: [String: CapabilitySet] = [
        "network.receive": [.safeRead, .networkRead],
        "network.connect": [.networkWrite], "network.listen": [.networkWrite],
        "network.accept": [.networkWrite], "network.close": [.networkWrite],
        "network.send": [.networkWrite, .externalSend],
        "apps.call": [.applescript, .systemControl],
        // The stem's file readers open a snapshot copy read-only; reach to the path is the part's declared readPaths.
        "files.query": [.safeRead], "files.mime": [.safeRead], "files.names": [.safeRead],
        "screen.watch": [.safeRead], "screen.next": [.safeRead], "frame.read": [.safeRead],
        // Program start owns shell admission; later talk stays within it.
        "program.start": [.processSpawn, .shell], "program.send": [.processSpawn],
        "program.receive": [.safeRead], "program.close": [.processSpawn],
    ].merging(handOperations.map { ($0, [.macControl, .axInjection]) }) { $1 }

    /// Fetch is one broker operation with keyless/secret effect identities at admission. These and primitiveCapabilities are the current contracts.
    private static let fetchOperations: Set<String> = ["fetch", "fetch.keyless", "fetch.secret"]
    public static func isPrimitiveEffect(_ operation: String) -> Bool {
        primitiveCapabilities[operation] != nil || fetchOperations.contains(operation)
    }

    public static func appReadOnly(_ args: [String: JSONValue]) -> Bool {
        // Read-only script declarations are enforced per event by MacControl's send callback before the event reaches the app.
        if case .string? = args["script"] { return args["read_only"] == .bool(true) }
        return args["script"] == nil && (args["dictionary"] == .bool(true) || args["event_class"] == .string("core")
            && [.string("getd"), .string("cnte"), .string("doex")].contains(args["event_id"] ?? .null))
    }

    public static func primitiveEffect(_ operation: String, arguments: JSONValue?) -> (tool: String, capabilities: CapabilitySet) {
        let args: [String: JSONValue] = if case .object(let fields)? = arguments { fields } else { [:] }
        if operation == "apps.call", case .object(let args)? = arguments, appReadOnly(args) {
            return (operation, [.safeRead, .applescript])
        }
        if fetchOperations.contains(operation) {
            let read = args["method"] == nil || arguments?.stringFields["method"]?.uppercased() == "GET"
            // A secret-bearing request acts as the person at that service; only GET/HEAD without a body remains a read.
            if operation == "fetch.secret" || operation == "fetch" && !Keyring.names(in: arguments ?? .null).isEmpty {
                return ("fetch.secret", (read || arguments?.stringFields["method"]?.uppercased() == "HEAD") && args["body"] == nil
                    ? [.safeRead, .networkRead, .secrets] : [.networkWrite, .externalSend, .secrets])
            }
            return ("fetch.keyless", read
                ? [.networkPublic, .safeRead, .networkRead] : [.networkPublic, .networkWrite, .externalSend])
        }
        return (operation, primitiveCapabilities[operation] ?? [.destructive])
    }
}

/// Risk metadata is advisory and never substitutes for effect-time authorization.
public enum CanonicalToolRisk: String, Sendable, Codable, Comparable {
    case low
    case medium
    case high
    case critical
    case unavailable

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        case .unavailable: 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

extension SwiftNativeSecurityCenter {
    struct ToolProfile: Sendable {
        var capabilities: CapabilitySet
        var risk: CanonicalToolRisk
    }

    /// Pure classification through the authorization profile owner grants no permission and records no effects.
    public static func canonicalToolRisk(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        turn: Turn?,
        trustedWorkspaceRoots: [URL] = []
    ) -> CanonicalToolRisk {
        do {
            return try profile(tool: policyToolName(tool), input: input, dataRoot: dataRoot, turn: turn,
                               trustedWorkspaceRoots: trustedWorkspaceRoots).risk
        } catch {
            // Advisory projections retain unknown classification. Admission below uses the throwing profile and reports the concrete cause.
            return .unavailable
        }
    }

    /// Project the declaration; argument policy only narrows the declared effects.
    static func profile(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        turn: Turn?,
        trustedWorkspaceRoots: [URL] = []
    ) throws -> ToolProfile {
        if AuthoredToolEffects.isPrimitiveEffect(tool) {
            let effects = AuthoredToolEffects.primitiveEffect(tool, arguments: .object(input)).capabilities.union([.toolCall])
            return ToolProfile(capabilities: effects, risk: displayRisk(toolClass: PermissionLaw.effectClass(effects), capabilities: effects))
        }
        let name = ToolNameAliases.canonical(tool)
        let schema = AppActionBinding.declaredSchema(name)
            ?? connectorActionIDs.first(where: { $0.value == tool }).flatMap { AppActionBinding.declaredSchema($0.key) }
        let binding: AppActionBinding? = if tool == "app" { try AppActionBinding.action(input: input, turn: turn) }
            else if schema == nil { try AppActionBinding.action(tool: name, input: input, turn: turn)
                ?? AppActionBinding.binding(ToolNameAliases.authoredAction(name), turn: turn) }
            else { nil }
        var capabilities = schema?.capabilities ?? binding?.descriptor?.schema.capabilities ?? binding?.capabilities ?? [.toolCall]
        if AuthoredToolEffects.shellReadOnly(name, input: input) {
            capabilities = [.toolCall, .safeRead]
        }
        if tool == "app" {
            if try PermissionLaw.toolClass(name, input: input, turn: turn) == .read {
                capabilities = [.toolCall, .safeRead]
            } else {
                capabilities = binding?.capabilities ?? capabilities
                capabilities.remove(.safeRead)
            }
        }
        switch schema?.effectInputPolicy ?? .fixed {
        case .fixed: break
        case .agentConnection:
            if ["endpoint", "app_bundle_id"].contains(where: { input[$0] != nil && input[$0] != .string("") }) {
                capabilities.remove(.otherAppSettingsWrite)
            }
        case .agentMessage:
            capabilities.subtract(input["dry_run"] == .bool(true) ? [.externalSend, .networkWrite] : [.networkRead, .appDataWrite])
            if try !messagesAnAgentHostByCommand(input["agent"], dataRoot: dataRoot, turn: turn) {
                capabilities.subtract([.shell, .processSpawn])
            }
        }
        if try !capabilityWritesOutsideAppData(tool: name, input: input, dataRoot: dataRoot, turn: turn, trustedWorkspaceRoots: trustedWorkspaceRoots) {
            capabilities.remove(.outsideAppDataWrite)
        }
        return ToolProfile(capabilities: capabilities, risk: displayRisk(
            toolClass: schema?.toolClass ?? binding?.toolClass ?? .write, capabilities: capabilities))
    }

    /// Display metadata only. PermissionLaw.answer owns authority.
    private static func displayRisk(toolClass: ToolClass, capabilities: CapabilitySet) -> CanonicalToolRisk {
        let severity: [CapabilitySet: CanonicalToolRisk] = [
            .shell: .critical, .filesystemDelete: .critical, .destructive: .critical,
            .systemControl: .critical, .money: .critical, .remoteEffect: .critical,
            .processSpawn: .high, .credentialWrite: .high, .otherAppSettingsWrite: .high,
            .outsideAppDataWrite: .high, .axInjection: .high, .macControl: .high,
            .browserInteraction: .high, .externalSend: .high, .approvalStage: .high, .secrets: .high,
            .filesystemWrite: .medium, .appDataWrite: .medium, .networkWrite: .medium,
            .clipboardWrite: .medium, .notification: .medium, .imageGeneration: .medium,
            .ledgerWrite: .medium, .agentDelegate: .high,
        ]
        return severity.compactMap { bit, risk -> CanonicalToolRisk? in
            guard capabilities.contains(bit) else { return nil }
            return bit == .externalSend && capabilities.contains(.notification) ? .medium : risk
        }.max() ?? (capabilities.isEmpty && toolClass != .read ? .medium : .low)
    }


    /// The checked contact owner resolves IDs, names and handles, then reads the exact host recipe. Missing assembly/contact/recipe is unavailable.
    static func messagesAnAgentHostByCommand(_ handle: JSONValue?, dataRoot: URL, turn: Turn?) throws -> Bool {
        guard case .string(let agent)? = handle, !agent.isEmpty else {
            throw ToolFailureError("Name the contact before classifying the message's effects.", effects: .none,
                owner: "Agent contacts", code: "agent_profile_unavailable",
                instruction: "Choose the contact from People and send again with its exact identity.")
        }
        do { return try AgentHostLaunches.messagesByCommand(agent: agent, dataRoot: dataRoot, turn: turn) }
        catch {
            throw ToolFailureError("The contact's effect profile is unavailable: \(error.localizedDescription)", effects: .none,
                owner: "Agent contacts and host recipes", code: "agent_profile_unavailable",
                instruction: "Repair the named contact or recipe before sending; no message was dispatched.")
        }
    }

    /// Canonical names share the alias owner; chat wrappers are judged by their connector action identity.
    package static func policyToolName(_ raw: String) -> String {
        let tool = ToolNameAliases.canonical(raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connectorActionIDs[tool] ?? tool
    }

    static let connectorActionIDs: [String: String] = [
        "mobile_notify": "mobile.notify",
        "mac_notify": "mac.notify",
    ]
}
