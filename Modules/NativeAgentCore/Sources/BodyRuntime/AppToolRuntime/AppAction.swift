import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import SenseCore
import MacNerves
import ProviderRouting
import MindCore
import NativeAgentShared
// Blueprint: | `AppAction.swift` | Action declarations, folded gates, argument policy and effect receipts |

/// Action verbs retain their meaning on every page; admission classifies the action and folded calls re-enter their own gates.
public struct AppAction: Sendable {
    /// An exact reference carries its namespace; contextual qualifiers cannot narrow its identity.
    public struct ArgumentReference: Sendable {
        public let parameter: String
        public let prefix: String
        public let qualifiers: [String]
    }
    public enum Owner: Sendable {
        case agent
        /// A lever: the person's authority over the agent. It names why it is theirs and an agent-safe alternative when one exists; `asks`
        /// says whether a card can carry the agent's ask for it (false: it needs the person themself, so the agent's call is refused).
        /// `freely` names arguments under which the call only narrows what the agent has, so that call is the agent's own. `name` is the act
        /// in the person's words: Trust's card lists it, and a refusal of the agent's call names it.
        case person(String, instead: String? = nil, asks: Bool = true, freely: [String: JSONValue] = [:], name: String)
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
    public let bundled: Bool
    /// `name`, `a|b` for either, `?` optional, `:type` when not a string; `:object*` explicitly accepts arbitrary fields. `:object` needs declared fields or a
    /// typed map in its owner schema; `:secret` is redacted in receipts and logs.
    let arguments: DoorActionArguments
    public var args: [String] { arguments.spellings }
    public var subject: [String] { arguments.subject }
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
    /// Declared meanings for unique argument binding and refused-call advice; the receipt names every interpretation.
    public var argumentNames: [String: [String]] { arguments.names }
    public let argumentValues: [String: [String: JSONValue]]
    public var argumentReferences: [String: ArgumentReference] { arguments.references }
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
    public let capabilities: CapabilitySet
    public let resultSchema: JSONValue
    /// The agent's own words to its own person (`AppActionBinding.voice`).
    public let voice: Bool

    init(_ id: String, _ page: String, _ label: String, _ fields: [DoorActionArguments.Field] = [], subject: [String] = [], owner: Owner = .agent,
         irreversible: Bool = false, toolClass: ToolClass? = nil, reach: ToolReach = .agent, capabilities: CapabilitySet? = nil,
         screen: Bool = false, warn: String = "", tool: String = "",
         input: [String: JSONValue] = [:], rename: [String: String] = [:], read: Bool = false,
         argumentNames: [String: [String]] = [:], argumentValues: [String: [String: JSONValue]] = [:],
         argumentReferences: [String: ArgumentReference] = [:],
         versionExempt: Bool = false, revision: Int = 1, readWhen: [String: JSONValue] = [:], scope: String = "",
         advisory: Bool = false, resultSchema: JSONValue = AppActions.resultEnvelope,
         lifecycle: CapabilityLifecycle.Action? = nil, schema: LLMToolSchema? = nil, partAction: Bool = false,
         part: String? = nil, folded: Bool = false, bundled: Bool = false, voice: Bool = false, declaredSecrets: [String] = []) {
        // Without an explicit class, read declares a read; other actions write app-owned data by default.
        let toolClass = toolClass ?? (read ? .read : .write)
        // A folded action runs its host tool, so it answers to that tool's schema and door names unless it declares its own.
        let schema = schema ?? (folded ? AppActions.foldSchemas[tool] : nil)
        let hostNames = folded ? Dictionary(uniqueKeysWithValues: (ToolNameAliases.doorArgNames[tool] ?? [:]).map { ($0.value, $0.key) }) : [:]
        self.id = id; self.page = AppDoorNames.resolve(page); self.label = label; self.owner = owner
        self.irreversible = irreversible; self.toolClass = toolClass; self.screen = screen; self.warn = warn; self.tool = tool
        self.input = input; self.rename = hostNames.merging(rename) { _, declared in declared }; self.read = read
        self.arguments = DoorActionArguments(fields, subject: subject, names: argumentNames, references: argumentReferences, declaredSecrets: declaredSecrets)
        self.argumentValues = argumentValues
        self.versionExempt = versionExempt
        self.revision = revision
        self.readWhen = readWhen
        self.returnedScope = [scope, schema.map { ToolNameAliases.foldedProse(AppActions.argumentProse($0.description, tool: tool)) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        self.scope = [scope, fields.map(\.spelling).joined(separator: " "), schema?.description ?? "", schema.map { String(decoding: $0.parametersJSON, as: UTF8.self) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        self.schema = schema
        self.partAction = partAction
        self.part = part
        self.folded = folded
        self.bundled = bundled
        self.advisory = advisory
        self.resultSchema = resultSchema
        self.lifecycle = lifecycle
        self.reach = reach
        self.voice = voice
        self.capabilities = capabilities ?? (toolClass == .read ? toolClass.baseCapabilities : toolClass.baseCapabilities.union(.appDataWrite))
    }

    /// A folded tool runs under its own gates and Trust key. Omitted label and args come from its schema.
    static func fold(_ tool: String, _ page: String, id: String? = nil, _ label: String? = nil, _ args: [DoorActionArguments.Field]? = nil,
                     subject: [String] = [], input: [String: JSONValue] = [:], read: Bool = false,
                     argumentNames: [String: [String]] = [:], argumentValues: [String: [String: JSONValue]] = [:],
                     argumentReferences: [String: ArgumentReference] = [:],
                     irreversible: Bool = false, reach: ToolReach = .agent, capabilities: CapabilitySet = [.safeRead, .toolCall],
                         screen: Bool = false,
                     warn: String = "", versionExempt: Bool = false,
                     readWhen: [String: JSONValue] = [:], advisory: Bool = false,
                     resultSchema: JSONValue = AppActions.resultEnvelope, lifecycle: CapabilityLifecycle.Action? = nil) throws -> AppAction {
        let schema = AppActions.foldSchemas[tool]
        // Declared args take the door's names; init's rename maps them back to the host call's.
        let names = ToolNameAliases.doorArgNames[tool] ?? [:]
        func door(_ arg: String) -> String {
            let end = arg.firstIndex { $0 == "?" || $0 == ":" } ?? arg.endIndex
            return (names[String(arg[..<end])] ?? String(arg[..<end])) + arg[end...]
        }
        let declaredArgs = try args?.map { $0.renaming(door) }
            ?? (schema.map { try ToolSignature.doorArgs($0.parametersJSON) } ?? []).map { .init(admitted: door($0)) }
        let contract = ActionCatalog.catalog.tools[tool]?.args
        let exposed = Set(declaredArgs.flatMap(\.names))
        let hostSubjects = (contract?.subject ?? []).map(door).filter(exposed.contains)
        let hostNames = Dictionary(uniqueKeysWithValues: (contract?.names ?? [:]).map { (door($0.key), $0.value) })
        let hostReferences = Dictionary(uniqueKeysWithValues: (contract?.references ?? [:]).map { (door($0.key), $0.value) })
        return AppAction(id ?? ToolNameAliases.appAction(tool) ?? tool, page,
                         label ?? schema.map { AppActions.firstSentence(ToolNameAliases.foldedProse($0.description)) } ?? tool,
                         declaredArgs, subject: subject.isEmpty ? hostSubjects : subject.map(door),
                         irreversible: irreversible, reach: reach, capabilities: capabilities,
                         screen: screen, warn: warn, tool: tool, input: input,
                         read: read, argumentNames: hostNames.merging(argumentNames) { _, declared in declared }, argumentValues: argumentValues,
                         argumentReferences: hostReferences.merging(argumentReferences) { _, declared in declared },
                         versionExempt: versionExempt, readWhen: readWhen,
                         advisory: advisory, resultSchema: resultSchema, lifecycle: lifecycle, schema: schema, folded: true, declaredSecrets: (contract?.secretArgs ?? []).map(door))
    }

    public var isPersonOwned: Bool { lever != nil }
    public var lever: AppActionBinding.Lever? {
        if case .person(let why, _, let asks, let freely, let name) = owner {
            AppActionBinding.Lever(why: why, asks: asks, freely: freely, name: name)
        } else { nil }
    }
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
        arguments.secretArgs
    }

    public var binding: AppActionBinding {
        AppActionBinding(lever: lever, irreversible: irreversible, read: read, secretArgs: secretArgs,
                         boundArguments: { [self] given in
                             let schema = try arguments.projection(self).schema
                             return AppActions.boundArguments(self, given, schema: schema).args
                         },
                         readWhen: readWhen, lifecycle: lifecycle, subject: subject, page: page,
                         tool: tool, fixedInput: input, rename: rename, folded: isFold, bundled: bundled,
                         descriptor: schema.map { ToolDescriptor(schema: $0, bucket:
                             SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: tool) ?? AppToolExecutor.buckets[tool] ?? .unclassified) },
                         toolClass: toolClass, reach: reach, capabilities: capabilities, declaredArguments: Set(argSpecs.flatMap(\.names)),
                         voice: voice)
    }

    func readOnly(args: [String: JSONValue]) -> Bool {
        binding.readOnly(args: args) || AuthoredToolEffects.shellReadOnly(tool, input: args)
    }

    /// Admission uses declared reach; a run's receipt uses its actual calls. The broker's per-call read class wins over broad ability permissions.
    /// A verb a part answers: it reports like the native verb it is, by its declared class, not as an ability's run.
    var answersVerb: Bool { partAction && input["verb"] != nil }

    func effectFields(args: [String: JSONValue] = [:], result: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var read = readOnly(args: args)
        var irreversible = irreversible
        let ability = (part != nil || authored) && !answersVerb
        if ability {
            var run = result
            // The door wraps a run in result; later receipt stamps must read that same ledger instead of restoring the admission prior.
            while run["calls"] == nil, let nested = run["result"]?.objectValue { run = nested }
            if case .array(let calls)? = run["calls"] {
                irreversible = calls.contains { $0.objectValue?["irreversible"] == .bool(true) }
                read = calls.allSatisfy { $0.objectValue?["read_only"] == .bool(true) }
            }
        }
        return ["read_only": .bool(read), "irreversible": .bool(irreversible),
                "effect": .string(id == "ability.validate" ? "none" : read ? "read" : ability ? "part" : irreversible ? "irreversible" : "write")]
    }

    /// Compact rows show the id and argument names with the user's required context.
    public var signature: String { args.isEmpty ? id : "\(id)(\(args.joined(separator: ", ")))" }

    public var line: String {
        var text = "\(id)(\(args.joined(separator: ", "))) \(label)"
        if screen { text += " · screen" }
        if irreversible { text += " · irreversible" }
        if !warn.isEmpty { text += " · \(warn)" }
        if case .person(let why, let instead, let asks, let freely, _) = owner {
            text += (asks ? " · yours under Full Mac unless an untrusted voice steers; below it, the person's ask or card (Safe refuses): "
                : " · the person's: ") + why
                + (instead.map { ". Instead: \($0)" } ?? "")
            if !freely.isEmpty {
                text += ". Yours with " + freely.sorted { $0.key < $1.key }.map { $0.key + " " + ($0.value.scalarText ?? "") }
                    .joined(separator: ", ")
            }
        }
        return text
    }

    var argSpecs: [DoorActionArguments.Field] { arguments.fields }
}
