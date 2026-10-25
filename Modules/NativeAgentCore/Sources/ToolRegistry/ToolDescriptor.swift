import Foundation
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ToolDescriptor.swift` | `ToolDescriptor`, `ToolExecutor`, `AppActionBinding`: composed action calls, effect declarations (class, reach, capabilities; each form supplies the common case) and executable ownership registration |

// MARK: - Tool descriptors (S9, 2026-09-26)

/// Stable, runtime-owned categories for the Tools catalog. The catalog is the
/// authority for the mounted tool set; this registry is the authority for the
/// names implemented by the Swift dispatcher. Keeping both facts together
/// means a new dispatcher case cannot quietly fall into a presentation
/// catch-all without its category being reviewed.
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

/// One tool as the router and the catalog know it: the schema the model is
/// offered (name, description, parameters — byte for byte) and the Tools-page
/// bucket it is filed under. Trust stays keyed on the canonical name in the
/// Trust Center's profiles; a descriptor adds no authority.
public struct ToolDescriptor: Sendable {
    public let schema: LLMToolSchema
    public let bucket: ChatToolCatalogBucket

    public init(schema: LLMToolSchema, bucket: ChatToolCatalogBucket) {
        self.schema = schema
        self.bucket = bucket
    }

    public var name: String { schema.name }
}

/// Tools an owner outside Core contributes to the one catalog (the app's
/// browser, its own pages, health reads). Core registers the
/// descriptors, lists them in the Tools page's manifest, and hands each
/// call here.
public protocol ToolExecutor: Sendable {
    var descriptors: [ToolDescriptor] { get }
    /// Core tools this owner runs in place of Core's own case on the bodies
    /// that carry it, with Core's schema: one owner per body. (The app's
    /// notify reaches its live senders and gates them this way.)
    var replacesCoreTools: Set<String> { get }
    func execute(
        tool: String, input: [String: JSONValue], surface: String
    ) async throws -> JSONValue
}

/// The app action's declared call and policy, shared without importing its executor.
public struct AppActionBinding: Sendable {
    public let tool: String
    public let fixedInput: [String: JSONValue]
    public let rename: [String: String]
    public let folded: Bool
    public let descriptor: ToolDescriptor?
    public let isHis: Bool
    public let irreversible: Bool
    public var read: Bool
    public let readWhen: [String: JSONValue]
    public let secretArgs: [String]
    public let lifecycle: CapabilityLifecycle.Action?
    /// What the action is when it does not read (`read`/`readWhen` say when it does).
    public let toolClass: ToolClass
    public let reach: ToolReach
    public let capabilities: Set<String>

    public init(isHis: Bool, irreversible: Bool, read: Bool, secretArgs: [String], readWhen: [String: JSONValue] = [:],
                lifecycle: CapabilityLifecycle.Action? = nil,
                tool: String = "", fixedInput: [String: JSONValue] = [:], rename: [String: String] = [:],
                folded: Bool = false, descriptor: ToolDescriptor? = nil, toolClass: ToolClass = .write,
                reach: ToolReach = .hers, capabilities: Set<String>? = nil) {
        self.tool = tool; self.fixedInput = fixedInput; self.rename = rename; self.folded = folded; self.descriptor = descriptor
        self.isHis = isHis; self.irreversible = irreversible; self.read = read
        self.secretArgs = secretArgs; self.readWhen = readWhen
        self.lifecycle = lifecycle
        self.toolClass = toolClass
        self.reach = reach
        // A door action writes the app's own data unless it says otherwise.
        self.capabilities = capabilities ?? (toolClass == .read ? toolClass.baseCapabilities : toolClass.baseCapabilities.union(["app_data_write"]))
    }

    public func readOnly(args: [String: JSONValue]) -> Bool {
        read || (!readWhen.isEmpty && readWhen.allSatisfy { (args[$0.key] ?? .null) == $0.value })
    }

    /// The two resolvers an executor installs, held by reference. A closure
    /// stored inside the lock's generic state is wrapped in a reabstraction
    /// thunk pair on every mutation of that state: after hours of chain
    /// builds the part resolver sat under hundreds of nested thunks, and the
    /// first unregistered action name overran a cooperative thread's 512 KB
    /// stack (Agent's 18:58Z crash, 10-17; the same on the test copy after
    /// ninety seconds). A class's stored closure keeps one shape.
    private final class Resolvers: Sendable {
        let authorableToolName: @Sendable (String) -> Bool
        let part: @Sendable (String) -> AppActionBinding?
        init(authorableToolName: @escaping @Sendable (String) -> Bool, part: @escaping @Sendable (String) -> AppActionBinding?) {
            self.authorableToolName = authorableToolName
            self.part = part
        }
    }

    // Installed from AppActions at executor assembly, before any app call or
    // receipt. No static initializer here reaches back into the app schemas.
    private static let registry = OSAllocatedUnfairLock(initialState: (
        actions: [String: AppActionBinding](), tools: [String: ToolDescriptor](),
        resolvers: Resolvers(authorableToolName: { _ in false }, part: { _ in nil })))

    public static func register(_ actions: [String: AppActionBinding], tools: [ToolDescriptor], authorableToolName: @escaping @Sendable (String) -> Bool, partPolicy: @escaping @Sendable (String) -> AppActionBinding?) {
        registerTools(tools)
        let resolvers = Resolvers(authorableToolName: authorableToolName, part: partPolicy)
        registry.withLock { $0 = (actions, $0.tools, resolvers) }
    }

    /// The core dispatcher's own tool names, registered where the dispatcher is
    /// assembled, so a chain with no app executor (core-only, no body) still
    /// knows shell and git as built-ins; an executor's descriptors join them.
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
        registry.withLock { $0.tools[tool] != nil }
    }

    /// How many tool names are reserved; the table only grows, so a reader
    /// that derived something from the namespace can key on it.
    public static var registeredToolCount: Int { registry.withLock { $0.tools.count } }

    /// The class a registered tool's declaration gives it.
    public static func declaredClass(_ tool: String) -> ToolClass? {
        registry.withLock { $0.tools[tool]?.schema.toolClass }
    }

    public static func declaredSchema(_ tool: String) -> LLMToolSchema? {
        registry.withLock { $0.tools[tool]?.schema }
    }

    /// The catalog bucket a registered tool is filed under.
    public static func declaredBucket(_ tool: String) -> ChatToolCatalogBucket? {
        registry.withLock { $0.tools[tool]?.bucket }
    }

    public static func authorableToolName(_ tool: String) -> Bool {
        registry.withLock { $0.resolvers }.authorableToolName(tool)
    }

    public static func action(tool: String = "app", input: [String: JSONValue]) -> AppActionBinding? {
        let id: String
        if tool == "app", case .string(let action)? = input["action"] { id = action }
        else if let action = ToolNameAliases.appAction(tool, input: input) { id = action }
        else { return nil }
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard var policy = binding(key) else { return nil }
        let args: [String: JSONValue] = if tool == "app", case .object(let args)? = input["args"] { args } else { input }
        policy.read = policy.readOnly(args: args)
        return policy
    }

    public func arguments(_ args: [String: JSONValue]) -> [String: JSONValue] {
        var call = folded ? ToolNameAliases.hostArgs(tool, args) : [:]
        if !folded { for (key, value) in args { call[rename[key] ?? key] = value } }
        return call.merging(fixedInput) { _, fixed in fixed }
    }

    public static func binding(_ id: String) -> AppActionBinding? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let (saved, resolvers) = registry.withLock { ($0.actions[key], $0.resolvers) }
        return saved ?? resolvers.part(key)
    }

    static func actionID(tool: String, input: [String: JSONValue]) -> String? {
        let matches = registry.withLock { $0.actions }.filter { _, binding in
            binding.tool == tool && binding.fixedInput.allSatisfy { input[$0.key] == $0.value }
        }
        guard let count = matches.values.map({ $0.fixedInput.count }).max() else { return nil }
        let selected = matches.filter { $0.value.fixedInput.count == count }
        return selected.count == 1 ? selected.first?.key : nil
    }

    /// Whether the table is installed yet: before assembly nothing is known.
    public static var isRegistered: Bool { registry.withLock { !$0.actions.isEmpty } }

    public static var secretActionIDs: [String] {
        registry.withLock { $0.actions.compactMap { $0.value.secretArgs.isEmpty ? nil : $0.key } }
    }
}
