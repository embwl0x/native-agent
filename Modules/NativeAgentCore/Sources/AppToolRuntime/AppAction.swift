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
// Blueprint: | `AppAction.swift` | AppAction value, folded calls, argument policy and receipt effects; run receipts use broker-recorded read classes and validation has effect none |

/// One button of NativeAgent's, as the `app` door offers it.
///
/// Its last word means one thing on every page: archive puts away, show brings forward on User's screen, clear erases, approve is his below
/// Full Mac. App admission classifies the action; folded calls re-enter their underlying tool's gates (`runFolded`).
public struct AppAction: Sendable {
    public enum Owner: Sendable {
        case hers
        /// Why it is User's and where he does it, and the action of hers that does the safe part instead, when there is one.
        case his(String, instead: String? = nil)
    }

    public let id: String
    /// Where User's own button is; "*" is every page.
    public let page: String
    /// The button's words.
    public let label: String
    /// Complete search and catalog-version input, including schema words.
    public let scope: String
    /// Model-facing scope; the schema is returned separately.
    let returnedScope: String
    public let schema: LLMToolSchema?
    public let partAction: Bool
    /// The part of hers it runs, by name: a skill, a sense ("" for a door that runs whichever part it is given). What it does is the
    /// part's, not her hand's.
    let part: String?
    /// This row declares a direct call to its tool, including fixed input.
    public let folded: Bool
    /// `name`, `a|b` for either, `?` optional, `:type` when not a string; `:secret` is a key or token, which receipts and logs redact.
    public let args: [String]
    public let owner: Owner
    public let lifecycle: CapabilityLifecycle.Action?
    /// Cannot be taken back once done, even when it is hers.
    public let irreversible: Bool
    /// What it is when it does not read: a write, a send, or destructive (no way back).
    public let toolClass: ToolClass
    /// Moves User's screen or makes a sound.
    public let screen: Bool
    /// What she must know before doing it, shown on its line.
    public let warn: String
    /// The code it runs (`runFolded`), and the input that picks the verb.
    public let tool: String
    public let input: [String: JSONValue]
    /// Door arg name → the host call's own input key, where the two differ.
    public let rename: [String: String]
    /// Reads its subject and raises no note, so the door reads no inbox around it.
    public let read: Bool
    public let readWhen: [String: JSONValue]
    /// Advisory reads replay their saved answer rather than a new ranking or sampling.
    public let advisory: Bool
    /// A skill call needing no app-page version: an append, an idempotent named change, or a pinned tool contract whose target is not that
    /// page. Decided per action, with the reason on its entry.
    public let versionExempt: Bool
    /// Bump for behavior changes, including result semantics, without a schema change.
    public let revision: Int
    public let reach: ToolReach
    public let capabilities: Set<String>
    public let resultSchema: JSONValue

    init(_ id: String, _ page: String, _ label: String, _ args: [String] = [], owner: Owner = .hers,
         irreversible: Bool = false, toolClass: ToolClass? = nil, reach: ToolReach = .hers, capabilities: Set<String>? = nil,
         screen: Bool = false, warn: String = "", tool: String = "",
         input: [String: JSONValue] = [:], rename: [String: String] = [:], read: Bool = false,
         versionExempt: Bool = false, revision: Int = 1, readWhen: [String: JSONValue] = [:], scope: String = "",
         advisory: Bool = false, resultSchema: JSONValue = AppActions.resultEnvelope,
         lifecycle: CapabilityLifecycle.Action? = nil, schema: LLMToolSchema? = nil, partAction: Bool = false,
         part: String? = nil, folded: Bool = false) {
        // A door action is a read when it says read:, else a write; it writes the app's own data unless it says otherwise.
        let toolClass = toolClass ?? (read ? .read : .write)
        self.id = id; self.page = AppDoorNames.resolve(page); self.label = label; self.args = args; self.owner = owner
        self.irreversible = irreversible; self.toolClass = toolClass; self.screen = screen; self.warn = warn; self.tool = tool
        self.input = input; self.rename = rename; self.read = read
        self.versionExempt = versionExempt
        self.revision = revision
        self.readWhen = readWhen
        self.returnedScope = [scope, schema.map { ToolNameAliases.foldedProse(AppActions.argumentProse($0.description, tool: tool)) } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        self.scope = [scope, args.joined(separator: " "), schema?.description ?? "", schema.map { String(decoding: $0.parametersJSON, as: UTF8.self) } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
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
                     irreversible: Bool = false, toolClass: ToolClass? = nil, reach: ToolReach = .hers, capabilities: Set<String> = ["safe_read", "tool_call"], screen: Bool = false,
                     warn: String = "", schema: LLMToolSchema? = nil, versionExempt: Bool = false,
                     readWhen: [String: JSONValue] = [:], advisory: Bool = false,
                     resultSchema: JSONValue = AppActions.resultEnvelope, lifecycle: CapabilityLifecycle.Action? = nil) -> AppAction {
        // A fold is a read when it says read:, else a write; it carries the door's own capabilities unless it says otherwise.
        let toolClass = toolClass ?? (read ? .read : .write)
        let schema = schema ?? AppActions.foldSchemas[tool]
        // Its args by the door's names (`ToolNameAliases.doorArgNames`), each renamed back as it runs.
        let names = ToolNameAliases.doorArgNames[tool] ?? [:]
        func door(_ arg: String) -> String {
            let end = arg.firstIndex { $0 == "?" || $0 == ":" } ?? arg.endIndex
            return (names[String(arg[..<end])] ?? String(arg[..<end])) + arg[end...]
        }
        let declaredArgs = (args ?? schema.map { ToolSignature.doorArgs($0.parametersJSON) } ?? []).map(door)
        let senseArgs = ["screen", "read", "read_file", "read_page", "browser.read_text", "browser.read_links", "browser.chrome_snapshot"].contains(tool)
            ? ["raw?:bool", "wrong?:bool", "why?"].filter { !declaredArgs.contains($0) } : []
        return AppAction(id ?? ToolNameAliases.appAction(tool) ?? tool, page,
                         label ?? schema.map { AppActions.firstSentence(ToolNameAliases.foldedProse($0.description)) } ?? tool,
                         declaredArgs + senseArgs,
                         irreversible: irreversible, toolClass: toolClass, reach: reach, capabilities: capabilities,
                         screen: screen, warn: warn, tool: tool, input: input,
                         rename: Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) }),
                         read: read, versionExempt: versionExempt, readWhen: readWhen,
                         advisory: advisory, resultSchema: resultSchema, lifecycle: lifecycle, schema: schema, folded: true)
    }

    public var isHis: Bool { if case .his = owner { true } else { false } }
    /// What running it is: a read, a folded tool's declared class, or its own.
    var reaches: ToolClass { read ? .read : folded ? schema?.toolClass ?? toolClass : toolClass }
    /// A row declares whether it runs as its tool; parts retain their own identity.
    public var isFold: Bool { folded || authored }
    /// A tool she wrote, by its own name or as a part's action: a program, not a native call.
    public var authored: Bool { partAction || ToolNameAliases.authoredTool(id) == tool }
    /// One of an inline card's buttons, not the composer (`AppToolExecutor.runCardAction`).
    public var isCard: Bool { tool == "interaction_act" && input["target"] == nil }
    var isItemRead: Bool { tool == "app_page_read" && input["item"] != nil }

    /// Declared credential args (`:secret`). SecurityCenter's records and the transcript redact them; typed text is redacted at the
    /// injection boundary.
    public var secretArgs: [String] {
        zip(args, argSpecs).filter { $0.0.hasSuffix(":secret") }.flatMap { $0.1.names }
    }

    public var binding: AppActionBinding {
        AppActionBinding(isHis: isHis, irreversible: irreversible, read: read, secretArgs: secretArgs,
                         readWhen: readWhen, lifecycle: lifecycle,
                         tool: tool, fixedInput: input, rename: rename, folded: isFold,
                         descriptor: schema.map { ToolDescriptor(schema: $0, bucket:
                             SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: tool) ?? AppToolExecutor.buckets[tool] ?? .unclassified) },
                         toolClass: toolClass, reach: reach, capabilities: capabilities)
    }

    func readOnly(args: [String: JSONValue]) -> Bool {
        binding.readOnly(args: args) || AuthoredToolEffects.shellReadOnly(tool, input: args)
    }

    /// Admission uses declared reach; a run's receipt uses its actual calls. The broker's per-call read class wins over broad ability
    /// permissions.
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
                "effect": .string(id == "ability.validate" ? "none" : read ? "read" : part != nil || authored ? "part" : irreversible ? "irreversible" : "write")]
    }

    /// `id(args) label`, then what User needs to know about it. The id with its argument names, nothing else: what a compact page row shows.
    public var signature: String { args.isEmpty ? id : "\(id)(\(args.joined(separator: ", ")))" }

    public var line: String {
        var text = "\(id)(\(args.joined(separator: ", "))) \(label)"
        if screen { text += " · screen" }
        if irreversible { text += " · irreversible" }
        if !warn.isEmpty { text += " · \(warn)" }
        // Only while Simple view is on screen does showing a page change the view itself.
        if id == "page.show", SimpleViewMode.isShowing { text += " · " + SimpleViewMode.noPagesNote }
        if case .his(let why, let instead) = owner {
            // Under Full Mac it is hers, unless it needs User himself (no tool runs it).
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

    /// Each arg's accepted names, and whether it may be left out.
    var argSpecs: [(names: [String], optional: Bool)] {
        args.map { raw in
            let head = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
            return (head.trimmingCharacters(in: CharacterSet(charactersIn: "?")).split(separator: "|").map(String.init),
                    head.hasSuffix("?"))
        }
    }
}
