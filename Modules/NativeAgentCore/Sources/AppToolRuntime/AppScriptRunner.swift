import AuthoredCapabilities
import ChatOrchestration
import Foundation
import MacControl
import PersistenceCore
import Privacy
import PersonaEngine
import Senses
import TrustCenter

/// The app door supplies its registry and gate chain to the shared executor.
/// Receipt classification, journal/replay, quotas and the VM have one owner.
enum AppScriptRunner {
    static let sourceLimit = OwnedProgramRunner.sourceLimit
    static let actionLimit = OwnedProgramRunner.actionLimit
    typealias Perform = @Sendable ([String: JSONValue]) async -> JSONValue
    typealias ScriptError = OwnedProgramRunner.ScriptError
    typealias Replay = OwnedProgramRunner.Replay

    static func run(source: String, preview: Bool, strict: Bool = false, input: JSONValue? = nil,
                    replay: Replay? = nil, program: OwnedProgram? = nil,
                    dataRoot: URL = PersistenceCore.defaultDataRoot(), perform: @escaping Perform) async -> JSONValue {
        guard source.utf8.count <= sourceLimit else {
            return AppToolExecutor.doorRefusal("script_too_long",
                "The script is \(source.utf8.count) bytes; the limit is \(sourceLimit). Nothing ran.",
                remedy: "shorten", "Split it, or read first and act in a shorter script.")
        }
        if let input {
            guard case .object = input, let text = try? input.serialize(pretty: false), text.utf8.count <= OwnedProgramRunner.inputLimit else {
                return AppToolExecutor.doorRefusal("invalid_input",
                    "A script's input is one JSON object of at most \(OwnedProgramRunner.inputLimit) bytes. Nothing ran.",
                    remedy: "correct_arguments", "Pass the input as one smaller object.")
            }
            if let path = secretPath(input) {
                return AppToolExecutor.doorRefusal("secret_in_input",
                    "\(path) carries a key or token, and a script's input never does. Nothing ran.",
                    remedy: "use_actions", "Pass a key as a single app action, not in a script.")
            }
        }

        let program = program ?? OwnedProgram(kind: strict ? .skill : .script, id: "app-script", version: "1",
                                   source: source, entry: .functionBody)
        return await runner(dataRoot: dataRoot).run(program, input: input, preview: preview, replay: replay, host: Host(call: perform, dataRoot: dataRoot))
    }

    static func runner(dataRoot root: URL) -> OwnedProgramRunner {
        let helper = SenseHostLocator.helperURL
        return OwnedProgramRunner(helperURL: helper, dataRoot: root) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helper, scratch: scratch,
                dataRoot: root, personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: root))
        }
    }

    static func ownVersions(_ journal: [JSONValue]) -> [String] { OwnedProgramRunner.ownVersions(journal) }
    static func versionScope(_ version: String) -> String { OwnedProgramRunner.versionScope(version) }

    /// The first place a script's input carries a key or token: a field
    /// named as one, or a value shaped like one.
    static func secretPath(_ value: JSONValue, at path: String = "input") -> String? {
        switch value {
        case .string(let text): return NativeAgentSecretRedactor.redactText(text) == text ? nil : path
        case .array(let list): return list.indices.lazy.compactMap { secretPath(list[$0], at: "\(path)[\($0)]") }.first
        case .object(let fields):
            return fields.keys.sorted().lazy.compactMap { key -> String? in
                if ["api_key", "apikey", "token", "access_token", "refresh_token", "password", "passphrase", "secret",
                    "client_secret", "private_key", "authorization", "cookie", "credential", "credentials", "bearer"]
                    .contains(key.lowercased()), fields[key] != .null { return "\(path).\(key)" }
                return secretPath(fields[key] ?? .null, at: "\(path).\(key)")
            }.first
        default: return nil
        }
    }

    /// Door args from a script call: one object is the args by name (a second
    /// object carries expected_version or preview); anything else is
    /// positional, in the order the action's line declares.
    static func doorInput(id: String, given: [JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) -> Result<[String: JSONValue], ScriptError> {
        guard let action = AppActions.action(id, dataRoot: dataRoot) ?? AppActions.pagePrefixedAction(id) else {
            // Let the door return its exact nearest-action recovery; it executes no unknown action.
            return .success(["action": .string(id), "args": given.first ?? .object([:]),
                             AppToolExecutor.doorScriptKey: .bool(true)])
        }
        guard action.scriptable else {
            return .failure(ScriptError(reason: "not_scriptable",
                detail: "\(action.id) runs only as a single app action, not in a script; it was not run."))
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

    /// A key or token never rides a script: its source is kept, so the key
    /// goes in a single app action, whose args are redacted.
    private static func secretRefusal(_ action: AppAction, _ args: [String: JSONValue]) -> ScriptError? {
        guard action.secretArgs.contains(where: { args[$0].map { $0 != .null && $0 != .string("") } ?? false })
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
        var toolHost = false
        var dataRoot = PersistenceCore.defaultDataRoot()
        var admit: @Sendable (String, [String: JSONValue]) async -> JSONValue? = { _, _ in
            AppToolExecutor.failure("door_unavailable", "Authored execution requires the originating Trust gate.")
        }
        var actionIDs: [String] { (AppActions.all + AppActions.mcp(dataRoot: dataRoot) + AppActions.authored(dataRoot: dataRoot) + AppActions.senses()).map(\.id) }
        var floorReasons: Set<String> { AppToolExecutor.doorFloorReasons }
        var scriptKey: String { AppToolExecutor.doorScriptKey }
        func action(_ id: String) -> OwnedProgramAction? {
            resolved(id).map { action in
                OwnedProgramAction(id: action.id, page: action.page, read: action.read, advisory: action.advisory, partID: action.partAction ? action.tool : nil,
                                   program: action.authored, readOnly: { action.readOnly(args: $0) })
            }
        }
        func canonicalAction(_ id: String) -> String { resolved(id)?.id ?? AppActions.pagePrefixedAction(id)?.id ?? id }
        func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], ScriptError> {
            if toolHost {
                let named: [String: JSONValue]
                if given.isEmpty { named = [:] }
                else if given.count == 1, case .object(let object) = given[0] { named = object }
                else {
                    return .failure(ScriptError(reason: "invalid_args", detail: "An authored dependency takes no arguments or one named argument object; two or more arguments or a non-object are not accepted."))
                }
                guard let action = resolved(id) else { return AppScriptRunner.doorInput(id: id, given: given, dataRoot: dataRoot) }
                guard action.scriptable else {
                    return .failure(ScriptError(reason: "not_scriptable", detail: "\(action.id) is a card button; answer it outside the script."))
                }
                if let refusal = AppScriptRunner.secretRefusal(action, named) { return .failure(refusal) }
                return .success(["action": .string(action.id), "args": .object(named)])
            }
            return AppScriptRunner.doorInput(id: id, given: given, dataRoot: dataRoot)
        }
        func opensHomeItem(_ input: [String: JSONValue]) -> Bool { AppToolExecutor.opensHomeItem(input) }
        func secretLine(_ text: String) -> Bool { MacInjectionArgRedaction.namesAppDoorSecretAction(text) }
        func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence {
            let fields: [String: JSONValue] = if case .object(let fields) = receipt { fields } else { [:] }
            let mac = MacControlReceiptOutcome.projecting(envelope: receipt)
            return OwnedProgramReceiptEvidence(
                successful: ChatToolOutcome.outputLooksSuccessful(receipt),
                waiting: ChatToolOutcome.isWaitingOnPerson(receipt),
                resultClass: ChatToolOutcome.exactResultClass(receipt).rawValue,
                pending: ChatToolOutcome.pendingStatuses.contains(AppToolExecutor.doorText(fields["status"]).lowercased()),
                effectUnconfirmed: mac == .running || mac == .effectUnconfirmed)
        }
        func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? {
            SessionHistoryPromptRenderer.receiptField(key, in: receipt)
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
        func resolved(_ id: String) -> AppAction? {
            AppActions.action(id, dataRoot: dataRoot)
        }
        func dependencyShape(_ id: String) -> JSONValue? {
            guard let action = resolved(id) else { return nil }
            return AppActions.dependencyContract(action, dataRoot: dataRoot)
        }
        func dependencyPin(_ id: String) -> String? {
            dependencyShape(id).flatMap(pin)
        }
        private func pin(_ shape: JSONValue) -> String? {
            guard let digest = try? OwnedProgramStore.hash(shape) else { return nil }
            return AppActions.legacyContractPins[digest] ?? digest
        }
        func dependencyMatches(_ id: String, _ saved: JSONValue?) -> Bool {
            guard let saved, let current = dependencyShape(id) else { return false }
            if saved == current || saved == pin(current).map(JSONValue.string) { return true }
            // Older authored tools stored the full shape, so their contract is recoverable.
            return AppActions.legacyDependencyContract(saved) == current
        }
        func admitTool(_ id: String, input: [String: JSONValue]) async -> JSONValue? { await admit(id, input) }
        func performReach(_ operation: String, arguments: JSONValue) async throws -> JSONValue {
            try await reach(operation, arguments)
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
        AppScriptRunner.Host(call: doorCall(), reach: reach ?? AppScriptRunner.Host.unwiredReach, toolHost: true, dataRoot: dataRoot, admit: admit)
    }
}
