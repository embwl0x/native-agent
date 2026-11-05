import AgentWorkspace
import ChatToolRuntime
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter
import AgentConversations
import AuthoredCapabilities
import MacIntegration
import PersonaEngine
import Senses
import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import AttentionRouting
import NativeAgentShared
import ProviderRouting
import DeviceSync
import ChatTurnContracts
import ChromeControl
import MemoryV2
import StandingBots
import TurnTrace
import Studio
// Blueprint: | `AppAction.swift` | Action declarations, folded gates, argument policy and effect receipts |

/// Action verbs retain their meaning on every page; admission classifies the action and folded calls re-enter their own gates.
public struct AppAction: Sendable {
    public enum Owner: Sendable {
        case agent
        /// Owner-only actions name the user's control and an agent-safe alternative when one exists.
        case person(String, instead: String? = nil)
    }

    public let id: String
    /// "*" shares an action across all pages.
    public let page: String
    public let label: String
    /// Complete search and catalog-version input, including schema words.
    public let scope: String
    /// Model-facing scope; the schema is returned separately.
    let returnedScope: String
    public let schema: LLMToolSchema?
    public let partAction: Bool
    /// An empty part name runs the supplied part; behavior belongs to that part rather than its door.
    let part: String?
    public let folded: Bool
    /// `name`, `a|b` for either, `?` optional, `:type` when not a string; `:object*` explicitly accepts arbitrary fields. `:object` needs declared fields or a
    /// typed map in its owner schema; `:secret` is redacted in receipts and logs.
    public let args: [String]
    public let subject: [String]
    public let owner: Owner
    public let lifecycle: CapabilityLifecycle.Action?
    /// Irreversible effects remain irreversible under Full Mac.
    public let irreversible: Bool
    public let toolClass: ToolClass
    /// Screen and sound effects require the user's attention fences.
    public let screen: Bool
    public let warn: String
    public let tool: String
    public let input: [String: JSONValue]
    /// Door arg name → the host call's own input key, where the two differ.
    public let rename: [String: String]
    /// Reads its subject and raises no note, so the door reads no inbox around it.
    public let read: Bool
    public let readWhen: [String: JSONValue]
    /// Advisory reads replay their saved answer rather than a new ranking or sampling.
    public let advisory: Bool
    /// A skill call needing no app-page version: an append, an idempotent named change, or a pinned tool contract whose target is not that page. Decided per
    /// action, with the reason on its entry.
    public let versionExempt: Bool
    /// Bump for behavior changes, including result semantics, without a schema change.
    public let revision: Int
    public let reach: ToolReach
    public let capabilities: Set<String>
    public let resultSchema: JSONValue

    init(_ id: String, _ page: String, _ label: String, _ args: [String] = [], subject: [String] = [], owner: Owner = .agent,
         irreversible: Bool = false, toolClass: ToolClass? = nil, reach: ToolReach = .agent, capabilities: Set<String>? = nil,
         screen: Bool = false, warn: String = "", tool: String = "",
         input: [String: JSONValue] = [:], rename: [String: String] = [:], read: Bool = false,
         versionExempt: Bool = false, revision: Int = 1, readWhen: [String: JSONValue] = [:], scope: String = "",
         advisory: Bool = false, resultSchema: JSONValue = AppActions.resultEnvelope,
         lifecycle: CapabilityLifecycle.Action? = nil, schema: LLMToolSchema? = nil, partAction: Bool = false,
         part: String? = nil, folded: Bool = false) {
        // Without an explicit class, read declares a read; other actions write app-owned data by default.
        let toolClass = toolClass ?? (read ? .read : .write)
        // A folded action runs its host tool, so it answers to that tool's schema and door names unless it declares its own.
        let schema = schema ?? (folded ? AppActions.foldSchemas[tool] : nil)
        let hostNames = folded ? Dictionary(uniqueKeysWithValues: (ToolNameAliases.doorArgNames[tool] ?? [:]).map { ($0.value, $0.key) }) : [:]
        self.id = id; self.page = AppDoorNames.resolve(page); self.label = label; self.args = args; self.subject = subject; self.owner = owner
        self.irreversible = irreversible; self.toolClass = toolClass; self.screen = screen; self.warn = warn; self.tool = tool
        self.input = input; self.rename = hostNames.merging(rename) { _, declared in declared }; self.read = read
        self.versionExempt = versionExempt
        self.revision = revision
        self.readWhen = readWhen
        self.returnedScope = [scope, schema.map { ToolNameAliases.foldedProse(AppActions.argumentProse($0.description, tool: tool)) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        self.scope = [scope, args.joined(separator: " "), schema?.description ?? "", schema.map { String(decoding: $0.parametersJSON, as: UTF8.self) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        self.schema = schema
        self.partAction = partAction
        self.part = part
        self.folded = folded
        self.advisory = advisory
        self.resultSchema = resultSchema
        self.lifecycle = lifecycle
        self.reach = reach
        self.capabilities = capabilities ?? (toolClass == .read ? toolClass.baseCapabilities : toolClass.baseCapabilities.union(["app_data_write"]))
    }

    /// A folded tool runs under its own gates and Trust key. Omitted label and args come from its schema.
    static func fold(_ tool: String, _ page: String, id: String? = nil, _ label: String? = nil, _ args: [String]? = nil,
                     input: [String: JSONValue] = [:], read: Bool = false,
                     irreversible: Bool = false, toolClass: ToolClass? = nil, reach: ToolReach = .agent, capabilities: Set<String> = ["safe_read", "tool_call"],
                         screen: Bool = false,
                     warn: String = "", schema: LLMToolSchema? = nil, versionExempt: Bool = false,
                     readWhen: [String: JSONValue] = [:], advisory: Bool = false,
                     resultSchema: JSONValue = AppActions.resultEnvelope, lifecycle: CapabilityLifecycle.Action? = nil) throws -> AppAction {
        // Without an explicit class, read declares a read; other folds write with the door's default capabilities.
        let toolClass = toolClass ?? (read ? .read : .write)
        let schema = schema ?? AppActions.foldSchemas[tool]
        // Declared args take the door's names; init's rename maps them back to the host call's.
        let names = ToolNameAliases.doorArgNames[tool] ?? [:]
        func door(_ arg: String) -> String {
            let end = arg.firstIndex { $0 == "?" || $0 == ":" } ?? arg.endIndex
            return (names[String(arg[..<end])] ?? String(arg[..<end])) + arg[end...]
        }
        let declaredArgs = try (args ?? schema.map { try ToolSignature.doorArgs($0.parametersJSON) } ?? []).map(door)
        return AppAction(id ?? ToolNameAliases.appAction(tool) ?? tool, page,
                         label ?? schema.map { AppActions.firstSentence(ToolNameAliases.foldedProse($0.description)) } ?? tool,
                         declaredArgs,
                         irreversible: irreversible, toolClass: toolClass, reach: reach, capabilities: capabilities,
                         screen: screen, warn: warn, tool: tool, input: input,
                         read: read, versionExempt: versionExempt, readWhen: readWhen,
                         advisory: advisory, resultSchema: resultSchema, lifecycle: lifecycle, schema: schema, folded: true)
    }

    public var isPersonOwned: Bool { if case .person = owner { true } else { false } }
    var reaches: ToolClass { read ? .read : folded ? schema?.toolClass ?? toolClass : toolClass }
    /// Parts retain their own identity when a row declares a tool call.
    public var isFold: Bool { folded || authored }
    /// Authored tools run as programs, not native calls.
    public var authored: Bool { partAction || ToolNameAliases.authoredTool(id) == tool }
    /// Inline card buttons use runCardAction, independently of the composer.
    public var isCard: Bool { tool == "interaction_act" && input["target"] == nil }
    var isItemRead: Bool { tool == "app_page_read" && input["item"] != nil }

    /// Declared credential args (`:secret`). SecurityCenter's records and the transcript redact them; typed text is redacted at the injection boundary.
    public var secretArgs: [String] {
        zip(args, argSpecs).filter { $0.0.hasSuffix(":secret") }.flatMap { $0.1.names }
    }

    public var binding: AppActionBinding {
        AppActionBinding(isPersonOwned: isPersonOwned, irreversible: irreversible, read: read, secretArgs: secretArgs,
                         readWhen: readWhen, lifecycle: lifecycle, subject: subject,
                         tool: tool, fixedInput: input, rename: rename, folded: isFold,
                         descriptor: schema.map { ToolDescriptor(schema: $0, bucket:
                             SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: tool) ?? AppToolExecutor.buckets[tool] ?? .unclassified) },
                         toolClass: toolClass, reach: reach, capabilities: capabilities)
    }

    func readOnly(args: [String: JSONValue]) -> Bool {
        binding.readOnly(args: args) || AuthoredToolEffects.shellReadOnly(tool, input: args)
    }

    /// Admission uses declared reach; a run's receipt uses its actual calls. The broker's per-call read class wins over broad ability permissions.
    func effectFields(args: [String: JSONValue] = [:], result: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var read = readOnly(args: args)
        var irreversible = irreversible
        if part != nil || authored {
            var run = result
            // The door wraps a run in result; later receipt stamps must read that same ledger instead of restoring the admission prior.
            while run["calls"] == nil, let nested = run["result"]?.objectValue { run = nested }
            if case .array(let calls)? = run["calls"] {
                irreversible = calls.contains { $0.objectValue?["irreversible"] == .bool(true) }
                read = calls.allSatisfy { $0.objectValue?["read_only"] == .bool(true) }
            }
        }
        return ["read_only": .bool(read), "irreversible": .bool(irreversible),
                "effect": .string(id == "ability.validate" ? "none" : read ? "read" : part != nil || authored ? "part" : irreversible ? "irreversible"
                    : "write")]
    }

    /// Compact rows show the id and argument names with the user's required context.
    public var signature: String { args.isEmpty ? id : "\(id)(\(args.joined(separator: ", ")))" }

    public var line: String {
        var text = "\(id)(\(args.joined(separator: ", "))) \(label)"
        if screen { text += " · screen" }
        if irreversible { text += " · irreversible" }
        if !warn.isEmpty { text += " · \(warn)" }
        // Only while Simple view is on screen does showing a page change the view itself.
        if id == "page.show", SimpleViewMode.isShowing { text += " · " + SimpleViewMode.noPagesNote }
        if case .person(let why, let instead) = owner {
            // Full Mac admits owner actions unless the action requires the person directly.
            text += (tool.isEmpty ? " · the owner's: " : " · the owner's below Full Mac: ") + why
                + (instead.map { ". Instead: \($0)" } ?? "")
        }
        return text
    }

    /// `line` for `app`'s own description: a long argument list is cut to its required args and "…"; a page read lists them all.
    public var hotLine: String {
        guard args.count > 4 else { return line }
        let required = zip(args, argSpecs).filter { !$0.1.optional }.map(\.0)
        return line.replacingOccurrences(of: "(\(args.joined(separator: ", ")))",
                                          with: "(\((required + ["…"]).joined(separator: ", ")))")
    }

    var argSpecs: [(names: [String], optional: Bool)] {
        args.map { raw in
            let head = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
            return (head.trimmingCharacters(in: CharacterSet(charactersIn: "?")).split(separator: "|").map(String.init),
                    head.hasSuffix("?"))
        }
    }
}
