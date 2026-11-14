import Foundation
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ToolDescriptor.swift` | `ToolDescriptor`, `ToolExecutor`, `AppActionBinding`: one call/effect declaration |

// MARK: - Tool descriptors

/// Register categories beside dispatcher names so a new built-in cannot silently become an unreviewed presentation catch-all.
public enum ChatToolCatalogBucket: String, CaseIterable, Sendable {
    case shell
    case system
    case macControl = "mac-control"
    case macIntegration = "mac-integration"
    case fileOps = "file-ops"
    case alwaysOn = "always-on"
    case browser
    case core
    case unclassified

    public var title: String {
        switch self {
        case .shell: return "Shell / Build"
        case .system: return "System"
        case .macControl: return "Mac Control"
        case .macIntegration: return "Mac Integration"
        case .fileOps: return "File Ops"
        case .alwaysOn: return "Always-on"
        case .browser: return "Browser"
        case .core: return "Core & Connectors"
        case .unclassified: return "Unclassified Runtime Tools"
        }
    }

    public var systemImage: String {
        switch self {
        case .shell: return "terminal"
        case .system: return "cpu"
        case .macControl: return "macwindow"
        case .macIntegration: return "app.badge"
        case .fileOps: return "doc.text"
        case .alwaysOn: return "bolt.circle"
        case .browser: return "safari"
        case .core: return "bolt.circle"
        case .unclassified: return "exclamationmark.triangle"
        }
    }
}

/// Schema bytes and presentation category share one descriptor; Trust remains keyed on the canonical name and gains no authority here.
public struct ToolDescriptor: Sendable {
    public let schema: LLMToolSchema
    public let bucket: ChatToolCatalogBucket

    public init(schema: LLMToolSchema, bucket: ChatToolCatalogBucket) {
        self.schema = schema
        self.bucket = bucket
    }

    public var name: String { schema.name }
}

/// External owners contribute to the same catalog so listing and execution cannot diverge.
public protocol ToolExecutor: Sendable {
    var descriptors: [ToolDescriptor] { get }
    /// A body has one executor per overridden Core tool, using Core's schema and the body's own gates.
    var replacesCoreTools: Set<String> { get }
    func execute(
        tool: String, input: [String: JSONValue], surface: String, turn: Turn
    ) async throws -> JSONValue
}

/// Core reads declared app policy without importing its executor.
public struct AppActionBinding: Sendable {
    public let tool: String
    public let fixedInput: [String: JSONValue]
    public let rename: [String: String]
    public let folded: Bool
    public let descriptor: ToolDescriptor?
    /// The person's authority over the agent this action is (Trust, consent, models, keys, approvals, forgetting, reset): `why` it is
    /// theirs, and whether a card can carry the agent's ask for it (`asks`). Only the person's own act decides a lever.
    public struct Lever: Sendable, Equatable {
        public let why: String
        public let asks: Bool
        /// Arguments under which the call is the agent's own: it only narrows what the agent has.
        public let freely: [String: JSONValue]
        /// The act in the person's words, as its declaration names it (Trust's card and refusals read it).
        public let name: String
        public init(why: String, asks: Bool, freely: [String: JSONValue] = [:], name: String = "") {
            self.why = why; self.asks = asks; self.freely = freely; self.name = name
        }
        /// Whether this call, with these arguments, is the person's. Arguments that are missing or differ leave it theirs.
        public func holds(_ args: [String: JSONValue]) -> Bool {
            freely.isEmpty || !freely.allSatisfy { args[$0.key] == $0.value }
        }
    }
    public var lever: Lever?
    public var isPersonOwned: Bool { lever != nil }
    public let irreversible: Bool
    public var read: Bool
    public let readWhen: [String: JSONValue]
    public let secretArgs: [String]
    /// Evidence binds through the execution owner's argument contract before applying content redaction.
    public let boundArguments: @Sendable ([String: JSONValue]) throws -> [String: JSONValue]
    public let lifecycle: CapabilityLifecycle.Action?
    /// Read predicates refine when the declared effect class applies.
    public let toolClass: ToolClass
    public let reach: ToolReach
    public let capabilities: Set<String>
    /// Subject arguments distinguish debts so success settles only its own target.
    public let subject: [String]
    /// The argument names the action declares, as the door spells them; the door's one reading of a call takes a declared name for the action.
    public let declaredArguments: Set<String>

    public init(lever: Lever?, irreversible: Bool, read: Bool, secretArgs: [String],
                boundArguments: @escaping @Sendable ([String: JSONValue]) throws -> [String: JSONValue], readWhen: [String: JSONValue] = [:],
                lifecycle: CapabilityLifecycle.Action? = nil, subject: [String] = [],
                tool: String = "", fixedInput: [String: JSONValue] = [:], rename: [String: String] = [:],
                folded: Bool = false, descriptor: ToolDescriptor? = nil, toolClass: ToolClass = .write,
                reach: ToolReach = .agent, capabilities: Set<String>? = nil, declaredArguments: Set<String> = []) {
        self.tool = tool; self.fixedInput = fixedInput; self.rename = rename; self.folded = folded; self.descriptor = descriptor
        self.lever = lever; self.irreversible = irreversible; self.read = read
        self.secretArgs = secretArgs; self.readWhen = readWhen
        self.boundArguments = boundArguments
        self.lifecycle = lifecycle
        self.subject = subject
        self.declaredArguments = declaredArguments
        self.toolClass = toolClass
        self.reach = reach
        // A door action writes the app's own data unless it says otherwise.
        self.capabilities = capabilities ?? (toolClass == .read ? toolClass.baseCapabilities : toolClass.baseCapabilities.union(["app_data_write"]))
    }

    /// Repair identity must preserve the declared subject across door argument renaming.
    public static func repairOperation(_ action: String, _ args: [String: JSONValue]) -> String {
        let binding = declaredBinding(action)
        let subject = (binding?.subject ?? []).compactMap { (args[$0] ?? binding?.rename[$0].flatMap { args[$0] })?.stringValue }
        return ([action] + subject).joined(separator: ":")
    }

    public func readOnly(args: [String: JSONValue]) -> Bool {
        read || (!readWhen.isEmpty && readWhen.allSatisfy { (args[$0.key] ?? .null) == $0.value })
    }

    /// Hold executor closures by reference so generic lock-state mutations cannot accumulate reabstraction thunks around them.
    private final class Resolvers: Sendable {
        let authorableToolName: @Sendable (String) -> Bool
        let part: @Sendable (String, Turn?) throws -> AppActionBinding?
        let catalog: @Sendable (Turn?) throws -> [String: AppActionBinding]
        let appReadOnly: @Sendable ([String: JSONValue], Turn?) throws -> Bool
        init(authorableToolName: @escaping @Sendable (String) -> Bool, part: @escaping @Sendable (String, Turn?) throws -> AppActionBinding?,
             catalog: @escaping @Sendable (Turn?) throws -> [String: AppActionBinding],
             appReadOnly: @escaping @Sendable ([String: JSONValue], Turn?) throws -> Bool) {
            self.authorableToolName = authorableToolName
            self.part = part
            self.catalog = catalog
            self.appReadOnly = appReadOnly
        }
    }

    // Installed from AppActions at executor assembly, before any app call or receipt. No static initializer here reaches back into the app schemas.
    private static let registry = OSAllocatedUnfairLock(initialState: (
        actions: [String: AppActionBinding](), tools: [String: ToolDescriptor](),
        resolvers: Resolvers(authorableToolName: { _ in false }, part: { _, _ in nil }, catalog: { _ in [:] },
            appReadOnly: { _, _ in throw ToolFailureError("The app read-only classifier is not registered.", effects: .none) })))

    public static func register(_ actions: [String: AppActionBinding], tools: [ToolDescriptor], authorableToolName: @escaping @Sendable (String) -> Bool,
        partPolicy: @escaping @Sendable (String, Turn?) throws -> AppActionBinding?,
                                policyCatalog: @escaping @Sendable (Turn?) throws -> [String: AppActionBinding] = { _ in [:] },
                                appReadOnly: @escaping @Sendable ([String: JSONValue], Turn?) throws -> Bool) {
        registerTools(tools)
        let resolvers = Resolvers(authorableToolName: authorableToolName, part: partPolicy, catalog: policyCatalog, appReadOnly: appReadOnly)
        registry.withLock { $0 = (actions, $0.tools, resolvers) }
    }

    /// The app executor classifies the complete door call against its current action registry.
    public static func isAppReadOnly(_ input: [String: JSONValue], turn: Turn?) throws -> Bool {
        try registry.withLock { $0.resolvers }.appReadOnly(input, turn)
    }

    /// A projection holds one catalog and passes it to each lookup, including misses.
    package static func policyCatalog(turn: Turn?) throws -> [String: AppActionBinding] {
        try registry.withLock { $0.resolvers }.catalog(turn)
    }

    /// Core-only dispatch still needs built-in names; app assembly adds executor descriptors without replacing them.
    public static func registerTools(_ tools: [ToolDescriptor]) {
        let tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        registry.withLock { state in
            state.tools.merge(tools) { existing, registered in
                precondition(existing.bucket == registered.bucket && existing.schema.description == registered.schema.description
                    && existing.schema.parametersJSON == registered.schema.parametersJSON, "Conflicting registered tool descriptors.")
                return existing
            }
        }
    }

    public static func builtInToolName(_ tool: String) -> Bool {
        registry.withLock { $0.tools[ToolNameAliases.canonical(tool)] != nil }
    }

    /// Monotonic namespace size lets derived readers invalidate when registration grows.
    public static var registeredToolCount: Int { registry.withLock { $0.tools.count } }

    public static func declaredClass(_ tool: String) -> ToolClass? {
        registry.withLock { $0.tools[ToolNameAliases.canonical(tool)]?.schema.toolClass }
    }

    public static func declaredSchema(_ tool: String) -> LLMToolSchema? {
        registry.withLock { $0.tools[ToolNameAliases.canonical(tool)]?.schema }
    }

    public static func declaredBucket(_ tool: String) -> ChatToolCatalogBucket? {
        registry.withLock { $0.tools[ToolNameAliases.canonical(tool)]?.bucket }
    }

    /// A door binding may execute this tool only under the action's current argument contract.
    public static func bindsTool(_ tool: String) -> Bool {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return registry.withLock { $0.actions.values.contains { $0.tool.lowercased() == name } }
    }

    public static func authorableToolName(_ tool: String) -> Bool {
        registry.withLock { $0.resolvers }.authorableToolName(tool)
    }

    public static func action(tool: String = "app", input: [String: JSONValue], turn: Turn?,
        catalog: [String: AppActionBinding]? = nil) throws -> AppActionBinding? {
        let id: String
        if tool == "app", case .string(let action)? = input["action"] { id = action }
        else if let action = ToolNameAliases.appAction(tool, input: input) { id = action }
        else if let verb = try answeredVerb(tool: tool, input: input, turn: turn, catalog: catalog) { id = verb }
        else { return nil }
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard var policy = try binding(key, turn: turn, catalog: catalog) else { return nil }
        let args: [String: JSONValue] = if tool == "app", case .object(let args)? = input["args"] { args } else { input }
        policy.read = policy.readOnly(args: args)
        if let lever = policy.lever, !lever.holds(args) { policy.lever = nil }
        return policy
    }

    /// A part runs a verb its header answers under the part's own tool with the verb in its input; that verb's binding judges the call.
    public static func answeredVerb(tool: String, input: [String: JSONValue], turn: Turn?, catalog: [String: AppActionBinding]? = nil) throws -> String? {
        guard case .string(let verb)? = input["verb"], let answered = try binding(verb, turn: turn, catalog: catalog),
              answered.tool == tool, answered.fixedInput["verb"] == .string(verb) else { return nil }
        return verb
    }

    /// Every action maps door names to its host's through `rename` alone; a folded action's rename already carries its tool's door names.
    public func arguments(_ args: [String: JSONValue]) -> [String: JSONValue] {
        var call: [String: JSONValue] = [:]
        for key in args.keys.sorted() {
            let name = rename[key] ?? key
            // Conflicting spellings stay visible to validation, never one picked arbitrarily.
            if name != key, rename[name] == nil, let other = args[name], other != args[key] { call[key] = args[key] } else { call[name] = args[key] }
        }
        return call.merging(fixedInput) { _, fixed in fixed }
    }

    /// Pure declaration lookup for name/receipt projection. Runtime admission uses `binding`, which also checks the authored owner and can fail.
    public static func declaredBinding(_ id: String) -> AppActionBinding? {
        registry.withLock { $0.actions[id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
    }

    public static func binding(_ id: String, turn: Turn?, catalog: [String: AppActionBinding]? = nil) throws -> AppActionBinding? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let (saved, resolvers) = registry.withLock { ($0.actions[key], $0.resolvers) }
        if let saved { return saved }
        if let catalog { return catalog[key] }
        return try resolvers.part(key, turn)
    }

    static func actionID(tool: String, input: [String: JSONValue]) -> String? {
        let matches = registry.withLock { $0.actions }.filter { _, binding in
            binding.tool == tool && binding.fixedInput.allSatisfy { input[$0.key] == $0.value }
        }
        guard let count = matches.values.map({ $0.fixedInput.count }).max() else { return nil }
        let selected = matches.filter { $0.value.fixedInput.count == count }
        return selected.count == 1 ? selected.first?.key : nil
    }

    /// Before table installation, absence proves no declaration.
    public static var isRegistered: Bool { registry.withLock { !$0.actions.isEmpty } }

    public static var secretActionIDs: [String] {
        registry.withLock { $0.actions.compactMap { $0.value.secretArgs.isEmpty ? nil : $0.key } }
    }
}
