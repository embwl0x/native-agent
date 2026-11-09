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
import NativeAgentShared
import PersistenceCore
import Privacy
import PersonaEngine
import Senses
import TrustCenter
import ToolRegistry
import ToolExecution
// Blueprint: | `AppScriptRunner.swift` | Gated program host, live contracts and shared normalization |

/// The door supplies registry and gate re-entry; receipt classification, replay, quotas and VM execution stay shared.
enum AppScriptRunner {
    static let sourceLimit = OwnedProgramRunner.sourceLimit
    static let actionLimit = OwnedProgramRunner.actionLimit
    typealias Perform = @Sendable ([String: JSONValue], Turn, AppActionExecution) async -> JSONValue
    typealias ScriptError = OwnedProgramRunner.ScriptError

    /// The named call envelope is shared by source admission and live execution. Unknown expressions are checked when they arrive.
    private static func namedCallProblem(_ given: [OwnedProgram.Calls.Argument]) -> (reason: String, detail: String)? {
        guard let first = given.first else { return nil }
        let named: Bool
        switch first {
        case .object, .value(.object): named = true
        default: named = false
        }
        guard named else { return nil }
        guard given.count <= 2 else {
            return ("invalid_args", "A named call takes its args object and at most one options object; extra arguments are not accepted.")
        }
        guard let second = given.dropFirst().first else { return nil }
        let keys: [String]
        switch second {
        case .object(let fields): keys = Array(fields.keys)
        case .value(.object(let fields)): keys = Array(fields.keys)
        case .unknown: return nil
        default: return ("invalid_args", "The second argument of a named call must be an options object with expected_version or preview.")
        }
        if let stray = keys.sorted().first(where: { !["expected_version", "preview"].contains($0) }) {
            return ("unknown_option", "The second object takes expected_version or preview, not \(stray).")
        }
        return nil
    }

    static func run(source: String, preview: Bool, dataRoot: URL, surface: String, turn: Turn, execution: AppActionExecution,
        perform: @escaping Perform) async -> JSONValue {
        guard source.utf8.count <= sourceLimit else {
            return AppToolExecutor.doorRefusal("script_too_long",
                "The script is \(source.utf8.count) bytes; the limit is \(sourceLimit). Nothing ran.",
                remedy: "shorten", "Split it, or read first and act in a shorter script.")
        }
        let program = OwnedProgram(kind: .script, id: "app-script", version: "1", source: source, entry: .functionBody)
        return await OwnedProgramRunner(dataRoot: dataRoot).run(program, input: nil, preview: preview, replay: nil,
            host: Host(call: perform, dataRoot: dataRoot, execution: execution, catalogTurn: turn),
            execution: execution.programExecution(turn: turn, surface: surface, preview: preview))
    }

    /// Object arguments are named, with preview/version in a second object; other values follow declaration order.
    static func doorInput(id: String, given: [JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot(),
                          turn: Turn?) -> Result<[String: JSONValue], ScriptError> {
        let checked: AppAction?
        do { checked = try AppActions.action(id, dataRoot: dataRoot, turn: turn) ?? AppActions.pagePrefixedAction(id, dataRoot: dataRoot, turn: turn) }
        catch { return .failure(ScriptError(reason: "action_catalog_unavailable", detail: """
            The action catalog could not be read: \(error.localizedDescription). Repair its owner before running this call.
            """)) }
        guard let action = checked else {
            // Unknown actions return the door's ranked recovery without execution.
            return .success(["action": .string(id), "args": given.first ?? .object([:]),
                             AppToolExecutor.doorScriptKey: .bool(true)])
        }
        func argumentFailure(_ reason: String, _ detail: String) -> ScriptError {
            do {
                let contract = try AppActions.discovery(action, dataRoot: dataRoot).objectValue ?? [:]
                return ScriptError(reason: reason, detail: detail,
                    tryInstead: AppActions.callAdvice(action, input: ["args": .null], discovery: contract))
            } catch {
                return ScriptError(reason: "action_schema_unavailable", detail: "\(detail) \(error.localizedDescription)")
            }
        }
        var input: [String: JSONValue] = ["action": .string(action.id)]
        if let problem = namedCallProblem(given.map(OwnedProgram.Calls.Argument.value)) {
            return .failure(argumentFailure(problem.reason, problem.detail))
        }
        if case .object(let named)? = given.first {
            input["args"] = .object(named)
            if let refusal = secretRefusal(action, named) { return .failure(refusal) }
            if given.count > 1, case .object(let options) = given[1] {
                if let stray = options.keys.first(where: { !["expected_version", "preview"].contains($0) }) {
                    return .failure(argumentFailure("unknown_option",
                        "The second object takes expected_version or preview, not \(stray)."))
                }
                input.merge(options) { _, new in new }
            }
            return .success(input)
        }
        var positional = given
        while positional.last == .null { positional.removeLast() }
        let specs = action.argSpecs
        guard positional.count <= specs.count else {
            return .failure(argumentFailure("invalid_args", "\(action.id) takes \(specs.count) args: \(action.line)"))
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

    /// Saved source refuses credential shapes and declared credential args; ordinary typing uses the same recursive detector as every script input.
    static func secretRefusal(_ action: AppAction, _ args: [String: JSONValue]) -> ScriptError? {
        guard NativeAgentSecretRedactor.secretPath(.object(args)) != nil
            || action.secretArgs.contains(where: { args[$0].map { $0 != .null && $0 != .string("") } ?? false })
        else { return nil }
        return ScriptError(reason: "secret_in_script",
            detail: action.id == "chat.working_memory"
                ? "Hold a private choice with a single app action; recorded script source cannot contain it. chat.working_memory was not run."
                : "Pass a key as a single app action, not in a script: \(action.id) was not run.")
    }


    struct Host: OwnedProgramToolHost {
        /// All unwired host reach shares an explicit refusal.
        static let unwiredReach: @Sendable (String, JSONValue, Turn) async throws -> JSONValue = { operation, _, _ in
            throw SenseFailure(code: "unavailable", message: "The app has not wired reach \(operation).")
        }
        let call: Perform
        var reach = Host.unwiredReach
        var validation: (@Sendable ([String: JSONValue], OwnedProgramFixtures) async -> JSONValue)?
        var dataRoot: URL
        var execution: AppActionExecution
        /// Synchronous registry lookups use the held conversation's served view;
        /// each live call still receives its own explicit turn below.
        var catalogTurn: Turn?
        var didWrite: (@Sendable (URL) -> Void)? { execution.invocation.wrote }
        func admitModel(turn: Turn?) async throws -> Turn {
            if let admit = execution.admitModel { return try await admit(turn) }
            guard let turn, turn.client != nil, turn.admission != nil else {
                throw SenseFailure(code: "unavailable", message: "A model call needs its originating door's model admission.")
            }
            return turn
        }
        var admit: @Sendable (String, [String: JSONValue], OwnedProgramExecution, (@Sendable () async throws -> JSONValue)?) async -> JSONValue? = { _, _, _,
            _ in
            AppToolExecutor.failure("door_unavailable", "Authored execution requires the originating Trust gate.")
        }
        func dependencyRevision(_ dependencies: [String]) throws -> [String] {
            try [String(AppActionBinding.registeredToolCount),
                AppActions.senses(dataRoot: dataRoot, turn: catalogTurn).map { $0.id + ":" + $0.page }.sorted().joined(separator: ","),
                AbilityStore.fileRevision(SwiftNativeManifestSigner(dataRoot: dataRoot).keyPath)]
        }
        var actionIDs: [String] { get throws { try AppActions.checkedInventory(dataRoot: dataRoot, turn: catalogTurn).actions.map(\.id) } }
        var floorReasons: Set<String> { AppToolExecutor.doorFloorReasons }
        var scriptKey: String { AppToolExecutor.doorScriptKey }
        func callAdvice(_ id: String, given: [OwnedProgram.Calls.Argument]?) async throws -> JSONValue {
            var input: [String: JSONValue] = ["args": .null]
            if let given, given.count == 1 { input["args"] = given[0].value ?? .null }
            if let action = try resolved(id) {
                return try AppActions.callAdvice(action, input: input,
                    discovery: AppActions.discovery(action, dataRoot: dataRoot).objectValue ?? [:])
            }
            let pages = Dictionary(([QuietToolPage.inbox] + QuietToolPage.all).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return try await AppActions.callAdvice(id, input: input, pages: pages, dataRoot: dataRoot,
                memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot), turn: catalogTurn)
        }
        func action(_ id: String) throws -> OwnedProgramAction? {
            if let action = try resolved(id) {
                return OwnedProgramAction(id: action.id, page: action.page, read: action.read, advisory: action.advisory, partID: action.partAction ? action
                    .tool : nil,
                                          program: action.authored, versioned: !action.versionExempt, readOnly: { action.readOnly(args: $0) })
            }
            return nil
        }
        func canonicalAction(_ id: String) throws -> String { try resolved(id)?.id ?? AppActions.pagePrefixedAction(id, dataRoot: dataRoot,
            turn: catalogTurn)?.id ?? id }
        /// Part calls accept named arguments or the positional order declared by their action.
        func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], ScriptError> {
            AppScriptRunner.doorInput(id: id, given: given, dataRoot: dataRoot, turn: catalogTurn)
        }
        func callArgumentsForEvidence(_ id: String, given: [JSONValue]) throws -> [JSONValue] {
            let input = try doorInput(id: id, given: given).get()
            let evidence = MacInjectionArgRedaction.redacted(tool: "app", input: input, turn: catalogTurn)
            guard let args = evidence["args"] else {
                throw ScriptError(reason: "argument_evidence_unavailable", detail: "\(id)'s call has no arguments to record. Nothing ran.")
            }
            var kept = [args]
            let options = evidence.filter { ["preview", "expected_version"].contains($0.key) }
            if !options.isEmpty { kept.append(.object(options)) }
            return kept
        }
        func opensHomeItem(_ input: [String: JSONValue]) -> Bool { AppToolExecutor.opensHomeItem(input) }
        func secretLine(_ text: String) -> Bool { MacInjectionArgRedaction.namesAppDoorSecretAction(text) }
        func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence {
            let reply = ToolResult(receipt)
            let fields: [String: JSONValue] = if case .object(let fields) = reply.payload { fields } else { [:] }
            let mac = MacControlReceiptOutcome.projecting(envelope: reply.payload)
            // Pending here names status only; reply.status also accepts state, and isOpen includes other evidence.
            return OwnedProgramReceiptEvidence(
                successful: ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome),
                waiting: ChatToolOutcome.isWaitingApproval(reply.payload) || reply.isWaitingInteraction,
                resultClass: reply.outcome.rawValue,
                pending: ChatToolOutcome.pendingStatuses.contains(AppToolExecutor.doorText(fields["status"]).lowercased()),
                effectUnconfirmed: mac == .running || mac == .effectUnconfirmed)
        }
        func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? {
            ChatTranscriptEvidenceRendering.receiptField(key, in: receipt)
        }
        /// Unwrap object results while keeping model guidance, remedies and provenance outside the program's data.
        func answer(_ receipt: JSONValue) -> JSONValue {
            guard case .object(var fields) = receipt else { return receipt }
            let formEnvelope: Set<String> = ["action", "result", "status", "execution", "argument_form", "understood", "effect", "read_only", "irreversible"]
            if fields["action"] != nil, fields["argument_form"] != nil, fields.keys.allSatisfy(formEnvelope.contains),
               let result = fields["result"], result.objectValue == nil {
                return result
            }
            fields.removeValue(forKey: "argument_form")
            fields.removeValue(forKey: "understood")
            if fields["action"] != nil, case .object(let result)? = fields["result"] {
                fields.removeValue(forKey: "result")
                fields.merge(result) { _, own in own }
            }
            for key in ["guide", "remedy", "next_call", "sense_provenance"] { fields.removeValue(forKey: key) }
            return .object(fields)
        }
        func perform(_ input: [String: JSONValue], execution program: OwnedProgramExecution) async -> JSONValue {
            guard let turn = program.turn else {
                return AppToolExecutor.failure("door_unavailable", "An app action needs its originating turn.")
            }
            var execution = execution.serving(program)
            if let invocation = program.toolInvocation {
                execution = execution.receiving(invocation)
                execution.deadlines = invocation.deadlines
            }
            execution.valueCall = program.valueIdentity
            execution.valueReach = program.valueReach
            guard !execution.handsBack else { return await call(input, turn, execution) }
            let requester = turn.partID.map { "\(PersonaCompiler.agentDisplayName(dataRoot: dataRoot))'s \($0)" }
            return await call(input, turn.with(\.requester, requester), execution)
        }
        func recordRefusal(_ result: JSONValue, input: [String: JSONValue], turn: Turn, surface: String) async -> JSONValue {
            await settle {
                await ChatToolDispatchTracer.traceUndispatched(turn: turn, tool: "app", input: input, surface: surface,
                    result: result, dataRoot: dataRoot)
            }
        }
        func validationPerform(_ input: [String: JSONValue], fixture: OwnedProgramFixtures, execution: OwnedProgramExecution) async -> JSONValue {
            if let validation { return await validation(input, fixture) }
            return await fixture.reply(input, execution: execution)
        }
        func resolved(_ id: String) throws -> AppAction? {
            try AppActions.action(id, dataRoot: dataRoot, turn: catalogTurn)
        }
        /// Only a current action has a dependency contract.
        func dependencyShape(_ id: String) throws -> JSONValue? {
            if let action = try resolved(id) { return try AppActions.dependencyContract(action, dataRoot: dataRoot) }
            return nil
        }
        func callProblem(_ id: String, given: [OwnedProgram.Calls.Argument], schema ownSchema: JSONValue?) throws -> String? {
            if let problem = AppScriptRunner.namedCallProblem(given) { return problem.detail }
            let action = try resolved(id)
            guard let schema = try ownSchema ?? action.flatMap({ try AppActions.discovery($0, dataRoot: dataRoot)
                .objectValue?["args_schema"] }) else { return nil }
            typealias Argument = OwnedProgram.Calls.Argument
            func normalize(_ argument: Argument, schema: JSONValue, root: Bool = false) -> Argument {
                switch argument {
                case .object(let fields):
                    let fields = if root, ownSchema == nil, let action {
                        AppActions.boundArguments(action, fields, schema: schema, known: { $0.value }, make: Argument.value,
                            accepts: { $0.problem(schema: $1) == nil }).args
                    } else if root { ToolArguments.itemAddress(fields, schema: schema).args }
                    else { fields }
                    let known = fields.compactMapValues(\.value)
                    let values: [String: JSONValue]
                    if root, ownSchema == nil, let action {
                        values = AppToolExecutor.doorValidationArgs(action,
                            AppToolExecutor.normalizedBoundArguments(action, known, schema: schema, recordShims: false))
                    } else { values = ToolArguments.normalized(known, schema: schema, recordShims: false) }
                    var result = values.mapValues(Argument.value)
                    let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
                    for (key, value) in fields where value.value == nil {
                        if root, ownSchema == nil, let action, AppToolExecutor.retainsRawArgumentValues(action) { result[key] = value }
                        else { result[key] = properties[key].map { normalize(value, schema: $0) } ?? value }
                    }
                    return .object(result)
                case .array(let items):
                    guard let itemSchema = schema.objectValue?["items"], itemSchema.arrayValue == nil else { return argument }
                    return .array(items.map { normalize($0, schema: itemSchema) })
                case .value(let value):
                    let wrapper: JSONValue = .object(["type": .string("object"), "properties": .object(["value": schema]), "required": .array([.string(
                        "value")])])
                    return .value(ToolArguments.normalized(["value": value], schema: wrapper, recordShims: false)["value"] ?? value)
                case .unknown: return argument
                }
            }
            let arguments: Argument
            if let first = given.first, case .object = first { arguments = first }
            else if given.isEmpty { arguments = .object([:]) }
            else {
                // A candidate self-call has no live positional declaration yet; its actual call must check the new mapping.
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
                // A conditional read cannot be judged using missing values. Folded actions re-enter their own gates for each element.
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
            let checked = normalize(.object(corrected), schema: schema, root: true)
            return checked.problem(schema: schema)
        }
        /// Only primitive admissions supply a body; the gate decides when it runs.
        func admitTool(_ id: String, input: [String: JSONValue], execution: OwnedProgramExecution,
                       effect: (@Sendable () async throws -> JSONValue)?) async -> JSONValue? {
            guard execution.turn != nil else {
                return AppToolExecutor.failure("door_unavailable", "An authored action needs its originating turn.")
            }
            return await admit(id, input, execution, effect)
        }
        func performReach(_ operation: String, arguments: JSONValue, execution: OwnedProgramExecution) async throws -> JSONValue {
            guard let turn = execution.turn else {
                throw SenseFailure(code: "unavailable", message: "Program reach needs its originating turn.")
            }
            return try await reach(operation, arguments, turn)
        }
        func think(messages: [LLMMessage], tools: [String], surface: String?, host: any OwnedProgramHostProfile,
                   execution program: OwnedProgramExecution, purpose: String) async -> OwnedProgramThought {
            let scoped = PartThoughtTools(host: host, names: tools, execution: program)
            let client = makeChatOrchestrationClient(tools: scoped, dataRoot: dataRoot)
            do {
                guard let turn = program.turn else {
                    throw SenseFailure(code: "unavailable", message: "A part thought needs its originating turn.")
                }
                var call = LLMCall(turn: turn, surface: program.surface, purpose: purpose)
                call.preview = program.preview
                let output = try await client.runPartToolTurn(messages: messages, surface: surface, turn: turn, work: execution.turnWork, call: call)
                return .init(output: .success(output), effects: await scoped.effects)
            } catch {
                return .init(output: .failure(error), effects: await scoped.effects)
            }
        }
    }
}

extension AppToolExecutor {
    /// The door from inside an owned program: the originating turn's gate chain answers each call.
    static func doorCall() -> AppScriptRunner.Perform {
        return { input, turn, execution in
            guard let reentry = execution.perform else { return Self.failure("door_unavailable",
                "An authored app call needs the originating turn's gate chain.") }
            do { return try await reentry("app", input, turn, execution) }
            catch { return ChatToolOutcome.failure(error: error, tool: "app") }
        }
    }

    public static func authoredProgramHost(dataRoot: URL, turn: Turn?, execution: AppActionExecution,
        reach: (@Sendable (String, JSONValue, Turn) async throws -> JSONValue)? = nil,
        admit: @escaping @Sendable (String, [String: JSONValue], OwnedProgramExecution, (
            @Sendable () async throws -> JSONValue)?) async -> JSONValue?) -> any OwnedProgramToolHost {
        AppScriptRunner.Host(call: doorCall(), reach: reach ?? AppScriptRunner.Host.unwiredReach, dataRoot: dataRoot, execution: execution,
                             catalogTurn: turn, admit: admit)
    }
}
