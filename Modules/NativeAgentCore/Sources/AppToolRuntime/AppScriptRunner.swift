import AuthoredCapabilities
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import ChatToolParsing
import Foundation
import MacControl
import MacIntegration
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Privacy
import PersonaEngine
import Senses
import TrustCenter
import ToolRegistry
import ToolExecution
// Blueprint: | `AppScriptRunner.swift` | Shared-runner app host adapter, the signing key's file revision for invocation bindings, dependency shapes and ordinary turn-chain re-entry; save refusals use the door's action ranking; self-dependencies bind the enclosing part identity; NativeAgentSecretRedactor owns recursive credential recognition for ordinary typing and flow steps, alongside declared credential args; live schemas, canonical name/scalar normalization and the door's scalar-list expansion feed the shared call-fit reader; Contacts call-fit preserves known raw values even beside unknown expressions; self-calls use their candidate schema; dependency snapshots are historical evidence, never execution gates; action IDs and argument names must match their current declared contracts; declarations grant no action authority |

/// The app door supplies its registry and gate chain to the shared executor.
/// Receipt classification, journal/replay, quotas and the VM have one owner.
enum AppScriptRunner {
    static let sourceLimit = OwnedProgramRunner.sourceLimit
    static let actionLimit = OwnedProgramRunner.actionLimit
    typealias Perform = @Sendable ([String: JSONValue]) async -> JSONValue
    typealias ScriptError = OwnedProgramRunner.ScriptError

    static func run(source: String, preview: Bool, dataRoot: URL, perform: @escaping Perform) async -> JSONValue {
        guard source.utf8.count <= sourceLimit else {
            return AppToolExecutor.doorRefusal("script_too_long",
                "The script is \(source.utf8.count) bytes; the limit is \(sourceLimit). Nothing ran.",
                remedy: "shorten", "Split it, or read first and act in a shorter script.")
        }
        let program = OwnedProgram(kind: .script, id: "app-script", version: "1", source: source, entry: .functionBody)
        return await OwnedProgramRunner(dataRoot: dataRoot).run(program, input: nil, preview: preview, replay: nil, host: Host(call: perform, dataRoot: dataRoot))
    }

    /// Door args from a script call: one object is the args by name (a second
    /// object carries expected_version or preview); anything else is
    /// positional, in the order the action's line declares.
    static func doorInput(id: String, given: [JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) -> Result<[String: JSONValue], ScriptError> {
        let checked: AppAction?
        do { checked = try AppActions.action(id, dataRoot: dataRoot) ?? AppActions.pagePrefixedAction(id, dataRoot: dataRoot) }
        catch { return .failure(ScriptError(reason: "action_catalog_unavailable", detail: "The action catalog could not be read: \(error.localizedDescription). Repair its owner before running this call.")) }
        guard let action = checked else {
            // Let the door return its exact nearest-action recovery; it executes no unknown action.
            return .success(["action": .string(id), "args": given.first ?? .object([:]),
                             AppToolExecutor.doorScriptKey: .bool(true)])
        }
        var input: [String: JSONValue] = ["action": .string(action.id)]
        if case .object(let named)? = given.first {
            input["args"] = .object(named)
            if let refusal = secretRefusal(action, named) { return .failure(refusal) }
            if given.count > 1, case .object(let options) = given[1] {
                if let stray = options.keys.first(where: { !["expected_version", "preview"].contains($0) }) {
                    return .failure(ScriptError(reason: "unknown_option",
                        detail: "The second object takes expected_version or preview, not \(stray)."))
                }
                input.merge(options) { _, new in new }
            }
            return .success(input)
        }
        var positional = given
        while positional.last == .null { positional.removeLast() }
        let specs = action.argSpecs
        guard positional.count <= specs.count else {
            return .failure(ScriptError(reason: "invalid_args", detail: "\(action.id) takes \(specs.count) args: \(action.line)"))
        }
        var args: [String: JSONValue] = [:]
        for (value, spec) in zip(positional, specs) where value != .null {
            let isList = if case .array = value { true } else { false }
            args[spec.names.count > 1 ? (isList ? spec.names[0] : spec.names[spec.names.count - 1]) : spec.names[0]] = value
        }
        input["args"] = .object(args)
        if let refusal = secretRefusal(action, args) { return .failure(refusal) }
        return .success(input)
    }

    /// Saved source refuses credential shapes and declared credential args;
    /// ordinary typing uses the same recursive detector as every script input.
    private static func secretRefusal(_ action: AppAction, _ args: [String: JSONValue]) -> ScriptError? {
        guard NativeAgentSecretRedactor.secretPath(.object(args)) != nil
            || action.secretArgs.contains(where: { args[$0].map { $0 != .null && $0 != .string("") } ?? false })
        else { return nil }
        return ScriptError(reason: "secret_in_script",
            detail: "Pass a key as a single app action, not in a script: \(action.id) was not run.")
    }


    struct Host: OwnedProgramToolHost {
        /// Reach the app has not wired for this host: the one refusal every default shares.
        static let unwiredReach: @Sendable (String, JSONValue) async throws -> JSONValue = { operation, _ in
            throw SenseFailure(code: "unavailable", message: "The app has not wired reach \(operation).")
        }
        let call: Perform
        var reach = Host.unwiredReach
        var validation: (@Sendable ([String: JSONValue], OwnedProgramFixtures) async -> JSONValue)?
        var dataRoot: URL
        var admit: @Sendable (String, [String: JSONValue]) async -> JSONValue? = { _, _ in
            AppToolExecutor.failure("door_unavailable", "Authored execution requires the originating Trust gate.")
        }
        func dependencyRevision(_ dependencies: [String]) throws -> [String] {
            try [String(AppActionBinding.registeredToolCount),
                AppActions.senses(dataRoot: dataRoot).map { $0.id + ":" + $0.page }.sorted().joined(separator: ","),
                AbilityStore.fileRevision(SwiftNativeManifestSigner(dataRoot: dataRoot).keyPath)]
        }
        var actionIDs: [String] { get throws { try AppActions.checkedInventory(dataRoot: dataRoot).actions.map(\.id) } }
        var floorReasons: Set<String> { AppToolExecutor.doorFloorReasons }
        var scriptKey: String { AppToolExecutor.doorScriptKey }
        func nearestActions(_ id: String) async throws -> [String] {
            let pages = Dictionary(QuietToolPage.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return try await AppActions.ranked(id, pages: pages, dataRoot: dataRoot,
                memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)).actions.filter { !$0.isItemRead }.prefix(3).map(\.id)
        }
        func action(_ id: String) throws -> OwnedProgramAction? {
            if let action = try resolved(id) {
                return OwnedProgramAction(id: action.id, page: action.page, read: action.read, advisory: action.advisory, partID: action.partAction ? action.tool : nil,
                                          program: action.authored, versioned: !action.versionExempt, readOnly: { action.readOnly(args: $0) })
            }
            return nil
        }
        func canonicalAction(_ id: String) throws -> String { try resolved(id)?.id ?? AppActions.pagePrefixedAction(id, dataRoot: dataRoot)?.id ?? id }
        /// A part's call takes its args by name, or positionally as the action's line declares them.
        func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], ScriptError> {
            AppScriptRunner.doorInput(id: id, given: given, dataRoot: dataRoot)
        }
        func opensHomeItem(_ input: [String: JSONValue]) -> Bool { AppToolExecutor.opensHomeItem(input) }
        func secretLine(_ text: String) -> Bool { MacInjectionArgRedaction.namesAppDoorSecretAction(text) }
        func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence {
            let fields: [String: JSONValue] = if case .object(let fields) = receipt { fields } else { [:] }
            let mac = MacControlReceiptOutcome.projecting(envelope: receipt)
            let verdict = ChatToolOutcome.exactResultClass(receipt)
            return OwnedProgramReceiptEvidence(
                successful: ChatToolOutcome.outputLooksSuccessful(receipt, verdict: verdict),
                waiting: ChatToolOutcome.isWaitingOnPerson(receipt, verdict: verdict),
                resultClass: verdict.rawValue,
                pending: ChatToolOutcome.pendingStatuses.contains(AppToolExecutor.doorText(fields["status"]).lowercased()),
                effectUnconfirmed: mac == .running || mac == .effectUnconfirmed)
        }
        func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? {
            ChatTranscriptEvidenceRendering.receiptField(key, in: receipt)
        }
        /// One shape: a door receipt's object result comes up to the top, and
        /// what the door writes for the model (guide, remedy, next_call,
        /// provenance) is not the program's.
        func answer(_ receipt: JSONValue) -> JSONValue {
            guard case .object(var fields) = receipt else { return receipt }
            if fields["action"] != nil, case .object(let result)? = fields["result"] {
                fields.removeValue(forKey: "result")
                fields.merge(result) { _, own in own }
            }
            for key in ["guide", "remedy", "next_call", "sense_provenance"] { fields.removeValue(forKey: key) }
            return .object(fields)
        }
        func perform(_ input: [String: JSONValue]) async -> JSONValue {
            guard !SkillRunContext.handsBack else { return await call(input) }
            let requester = SkillRunContext.partID.map { "\(PersonaCompiler.agentDisplayName(dataRoot: dataRoot))'s \($0)" }
            return await SkillRunContext.$requester.withValue(requester) {
                await call(input)
            }
        }
        func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue {
            if let validation { return await validation(input, fixture) }
            return await fixture.reply(input)
        }
        func resolved(_ id: String) throws -> AppAction? {
            try AppActions.action(id, dataRoot: dataRoot)
        }
        /// Only a current action has a dependency contract.
        func dependencyShape(_ id: String) throws -> JSONValue? {
            if let action = try resolved(id) { return try AppActions.dependencyContract(action, dataRoot: dataRoot) }
            return nil
        }
        func callProblem(_ id: String, given: [OwnedProgram.Calls.Argument], schema ownSchema: JSONValue?) throws -> String? {
            let action = try resolved(id)
            guard let schema = try ownSchema ?? action.flatMap({ try AppActions.discovery($0, dataRoot: dataRoot).objectValue?["args_schema"] }) else { return nil }
            typealias Argument = OwnedProgram.Calls.Argument
            func normalize(_ argument: Argument, schema: JSONValue, root: Bool = false) -> Argument {
                switch argument {
                case .object(let fields):
                    let known = fields.compactMapValues(\.value)
                    let values: [String: JSONValue]
                    if root, ownSchema == nil, let action {
                        values = AppToolExecutor.doorValidationArgs(action,
                            AppToolExecutor.normalizedCallArguments(action, known, schema: schema, recordShims: false))
                    } else { values = ToolArguments.normalized(known, schema: schema, recordShims: false) }
                    var result = values.mapValues(Argument.value)
                    let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
                    for (key, value) in fields where value.value == nil {
                        result[key] = properties[key].map { normalize(value, schema: $0) } ?? value
                    }
                    return .object(result)
                case .array(let items):
                    guard let itemSchema = schema.objectValue?["items"], itemSchema.arrayValue == nil else { return argument }
                    return .array(items.map { normalize($0, schema: itemSchema) })
                case .value(let value):
                    let wrapper: JSONValue = .object(["type": .string("object"), "properties": .object(["value": schema]), "required": .array([.string("value")])])
                    return .value(ToolArguments.normalized(["value": value], schema: wrapper, recordShims: false)["value"] ?? value)
                case .unknown: return argument
                }
            }
            let arguments: Argument
            if let first = given.first, case .object = first { arguments = first }
            else if given.isEmpty { arguments = .object([:]) }
            else {
                // A self-call being saved has no live positional declaration
                // for its new schema yet; its actual call checks that mapping.
                if ownSchema != nil { return nil }
                let values = given.compactMap(\.value)
                guard values.count == given.count else { return nil }
                switch doorInput(id: id, given: values) {
                case .failure(let error): return error.detail
                case .success(let input): arguments = .object((input["args"]?.objectValue ?? [:]).mapValues(Argument.value))
                }
            }
            guard case .object(let fields) = arguments else { return nil }
            let corrected = fields
            if ownSchema == nil, let action,
               let (key, values) = AppToolExecutor.doorPlural(action, corrected, discovery: ["args_schema": schema]) {
                let known = corrected.compactMapValues(\.value)
                // A conditional read cannot be judged using missing values.
                // Folded actions re-enter their own gates for each element.
                if !action.isFold, !action.read, known.count != corrected.count { return nil }
                if action.isFold || action.readOnly(args: known) {
                    for (index, value) in values.enumerated() {
                        let expanded = corrected.merging([key: value]) { _, new in new }
                        if let problem = try callProblem(id, given: [.object(expanded)], schema: nil) {
                            return "plural args.\(key)[\(index)]: \(problem)"
                        }
                    }
                    return nil
                }
            }
            // Runtime Contacts admission is raw. Static inspection must not
            // coerce a known numeric/null entry merely because a sibling is
            // an unknown expression; unknowns still defer to the live owner.
            let checked: Argument
            if ownSchema == nil, let action, MacContactsExecutor.parameters(for: action.tool) != nil {
                checked = .object(corrected)
            } else { checked = normalize(.object(corrected), schema: schema, root: true) }
            return checked.problem(schema: schema)
        }
        func admitTool(_ id: String, input: [String: JSONValue]) async -> JSONValue? { await admit(id, input) }
        func performReach(_ operation: String, arguments: JSONValue) async throws -> JSONValue {
            try await reach(operation, arguments)
        }
        func think(messages: [LLMMessage], tools: [String], surface: String?, host: any OwnedProgramHostProfile) async -> OwnedProgramThought {
            let scoped = PartThoughtTools(host: host, names: tools, userText: ChatToolSessionContext.userText)
            let client = makeChatOrchestrationClient(tools: scoped, dataRoot: dataRoot)
            do {
                let output = try await client.runPartToolTurn(messages: messages, surface: surface)
                return .init(output: .success(output), effects: await scoped.effects)
            } catch {
                return .init(output: .failure(error), effects: await scoped.effects)
            }
        }
    }
}

extension AppToolExecutor {
    /// The door from inside an owned program: the originating turn's gate
    /// chain answers each call.
    static func doorCall() -> AppScriptRunner.Perform {
        let reentry = AppDoorReentry.perform
        return { input in
            guard let reentry else { return Self.failure("door_unavailable", "An authored app call needs the originating turn's gate chain.") }
            do { return try await reentry("app", input) }
            catch { return ChatToolOutcome.failure(error: error, tool: "app") }
        }
    }

    public static func authoredProgramHost(dataRoot: URL,
        reach: (@Sendable (String, JSONValue) async throws -> JSONValue)? = nil,
        admit: @escaping @Sendable (String, [String: JSONValue]) async -> JSONValue?) -> any OwnedProgramToolHost {
        AppScriptRunner.Host(call: doorCall(), reach: reach ?? AppScriptRunner.Host.unwiredReach, dataRoot: dataRoot, admit: admit)
    }
}
