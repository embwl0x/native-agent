import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import ToolRegistry
import MacControl
// Blueprint: | `PartHost.swift` | `Parts.rehearse`, `ToolHost`: gated host; previews suppress effects; a read verb's run only reads |

extension OwnedProgramExecution {
    func macOperation(dataRoot: URL) -> MacOperationContext {
        var context = MacOperationContext(dataRoot: dataRoot, deadline: deadline)
        context.handsBack = options.handsBack
        context.readContent = readContent
        return context
    }
}

extension Parts {
    /// Intercept every host call during rehearsal so sealing cannot claim unobserved effects.
    func rehearse(_ candidate: OwnedProgramStore.Candidate, capture: Bool, input: JSONValue?, invocation: Invocation) async throws -> JSONValue {
        guard let base = invocation.host else {
            throw PartError.invalid("Rehearsal needs the gated app door of a conversation or wake run.")
        }
        try await checkDependencies(candidate, invocation: invocation)
        let key = try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()
        let broker = ToolPrimitiveBroker(permissions: Set(candidate.program.permissions), abilityID: candidate.id, dataRoot: root)
        let host = ToolHost(base: base, candidate: candidate, broker: broker, dataRoot: root, openScreenWatch: invocation.openScreenWatch, admission: {})
        let face = Self.fields(Self.fields(candidate.manifest)["face"] ?? .null)["projection"] == .bool(true)
        let schema = face ? Self.faceNeeds(candidate.program.schema) : candidate.program.schema
        do {
            let proof = try await store.validate(candidate, key: key, capture: capture, input: input, runner: OwnedProgramRunner(dataRoot: root).rehearsal(
                ), host: { host }, execution: invocation.execution) {
                if let problem = $0.schemaProblem(schema: schema) {
                    throw SenseFailure(code: "bad_input", message: "Its input: \(problem.words).", remedy: .object([
                        "kind": .string("correct_arguments"), "instruction": .string(
                            "Correct the input to match \(problem.expected) in ability.validate for \(candidate.id)."), "next_call": .null]))
                }
            }
            await broker.close()
            return proof
        } catch {
            await broker.close()
            throw error
        }
    }

    /// A face reads the facts it needs from its owner's packet, and packets grow: a face part's input is checked only for what the part
    /// declares it needs. A field beyond its declaration is never refused, and a declared field it does not require may be null.
    static func faceNeeds(_ schema: JSONValue) -> JSONValue {
        guard case .object(var rules) = schema else { return schema }
        if rules["additionalProperties"] == .bool(false) { rules.removeValue(forKey: "additionalProperties") }
        let required = Set((rules["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        if case .object(let properties)? = rules["properties"] {
            rules["properties"] = .object(Dictionary(uniqueKeysWithValues: properties.map { name, property in
                (name, required.contains(name) ? faceNeeds(property) : ToolSchema.nullable(faceNeeds(property)))
            }))
        }
        if let items = rules["items"] { rules["items"] = faceNeeds(items) }
        return .object(rules)
    }
}

struct ToolHost: OwnedProgramHostProfile {
    let base: any OwnedProgramToolHost
    let candidate: OwnedProgramStore.Candidate
    let broker: ToolPrimitiveBroker
    let dataRoot: URL
    let openScreenWatch: (@Sendable (MacScreenWatch.Request, Bool) async throws -> MacScreenWatch)?
    var projection = false
    var preview = false
    /// A verb the part declares read runs read-confined: its app events, app actions and primitives can only read.
    var readOnly = false
    let admission: @Sendable () async throws -> Void
    private var appTargets: [String: String] {
        var targets: [String: String] = [:]
        for permission in candidate.program.permissions {
            let parts = permission.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, ["app_read", "app_write"].contains(parts[0]), targets[parts[1]] != "write" {
                targets[parts[1]] = parts[0] == "app_write" && !readOnly ? "write" : "read"
            }
        }
        return targets
    }
    private var readPaths: [String] { Parts.strings(Parts.fields(Parts.fields(candidate.manifest)["reach"] ?? .null)["readPaths"] ?? .array([])) }
    /// A read verb's run refuses anything that can change something, before it is admitted or sent.
    private func readRefusal(_ operation: String, _ arguments: JSONValue) -> JSONValue? {
        guard readOnly else { return nil }
        let reads = operation == "apps.call" ? AuthoredToolEffects.appReadOnly(Parts.fields(arguments))
            : operation != "part.call" && ToolPrimitiveBroker.readOnly(operation, arguments)
        return reads ? nil : Self.failure("read_verb", "\(operation) can change something, and this verb is declared read, so it only reads. Nothing ran.",
            effects: "none", execution: "not_run")
    }
    var actionIDs: [String] { candidate.program.dependencies }
    private func declaredDependency(_ id: String) throws -> String? {
        let resolved = try base.canonicalAction(id)
        return try candidate.program.dependencies.first { try base.canonicalAction($0) == resolved }
    }
    var floorReasons: Set<String> { base.floorReasons.union(["undeclared_dependency", "state_changed"]) }
    var scriptKey: String { base.scriptKey }
    func action(_ id: String) throws -> OwnedProgramAction? {
        if projection { return nil }
        guard let action = try base.action(id) else { return nil }
        let permissions = candidate.program.permissions
        return try declaredDependency(id) != nil || AbilityStore.reachActions(permissions).contains(base.canonicalAction(id)) ? action : nil
    }
    func canonicalAction(_ id: String) throws -> String { try base.canonicalAction(id) }
    func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
        do {
        guard try action(id) != nil else {
            if try declaredDependency(id) != nil, try base.action(id) == nil {
                return .failure(.init(reason: "dependency_unavailable", detail: """
                    \(id) is declared by ability \(candidate.id), but is unavailable in this app door. Use app find to inspect it; an authored dependency \
                    may need to be kept or enabled. It was not called.
                    """))
            }
            let declared = Parts.fields(candidate.manifest)["declaredActions"].map { Parts.strings($0) } ?? candidate.program.dependencies
            let actions = Set(declared + [id]).sorted().map { "\"" + $0 + "\"" }.joined(separator: ", ")
            return .failure(.init(reason: "undeclared_dependency",
                detail: "\(id) is not among the actions ability \(candidate.id) declares, so it was not called. "
                + "An action named at run time isn't read off the code: declare it with ability.save {id:\"\(candidate.id)\", actions:[\(actions)]}."))
        }
        return base.doorInput(id: id, given: given)
        } catch { return .failure(.init(reason: "action_catalog_unavailable",
            detail: "The ability's action catalog is unavailable: \(error.localizedDescription). Repair its owner before running this call.")) }
    }
    func opensHomeItem(_ input: [String: JSONValue]) -> Bool { base.opensHomeItem(input) }
    func callArgumentsForEvidence(_ id: String, given: [JSONValue]) throws -> [JSONValue] {
        try base.callArgumentsForEvidence(id, given: given)
    }
    func secretLine(_ text: String) -> Bool { base.secretLine(text) }
    func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence { base.evidence(receipt) }
    func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { base.receiptField(key, in: receipt) }
    func answer(_ receipt: JSONValue) -> JSONValue { base.answer(receipt) }
    /// Read/find envelopes need no action declaration because every part may inspect its app surface.
    private func reads(_ call: [String: JSONValue]) -> Bool {
        call["action"] == nil && (call["page"] != nil || call["find"] != nil)
    }
    func validationPerform(_ call: [String: JSONValue], fixture: OwnedProgramFixtures, execution: OwnedProgramExecution) async -> JSONValue {
        if reads(call) { return await fixture.reply(call, execution: execution) }
        guard case .string(let id)? = call["action"] else {
            return Self.failure("invalid_args", "A rehearsal call needs an action id.", effects: "none", execution: "not_run")
        }
        if case .failure(let error) = doorInput(id: id, given: [call["args"] ?? .object([:])]) {
            var fields = Parts.fields(Self.failure(error.reason, error.detail, effects: "none", execution: "not_run"))
            fields["try_instead"] = error.tryInstead
            return .object(fields)
        }
        // Interception must not turn a malformed dynamic call into a successful rehearsal. Live execution reaches this same schema at the app door.
        do {
            if let problem = try base.callProblem(id, given: [.object((call["args"]?.objectValue ?? [:]).mapValues(OwnedProgram.Calls.Argument.value))]) {
                var fields = Parts.fields(Self.failure("invalid_args", "\(id) \(problem).", effects: "none", execution: "not_run"))
                fields["try_instead"] = try await base.callAdvice(id, given: [.value(call["args"] ?? .object([:]))])
                return .object(fields)
            }
        } catch {
            return Self.failure(error, effects: "none", execution: "not_run")
        }
        return await fixture.reply(call, execution: execution)
    }

    func perform(_ call: [String: JSONValue], execution: OwnedProgramExecution) async -> JSONValue {
        if projection { return Self.failure("projection_only", "A face reads only its frozen sources.", effects: "none") }
        var call = call
        // A thought in a preview has the same preview posture as its code; raw model JSON can never turn a preview into a live effect.
        if preview { call["preview"] = .bool(true) }
        // JavaScript and model tools share this boundary. Neither can bypass authored secret/typed-text restrictions by supplying raw app JSON.
        if opensHomeItem(call) {
            return Self.failure("home_item_in_script", "A part cannot open a home arrival from inside its own run.", effects: "none")
        }
        if let id = Parts.string(call, "action"),
           case .failure(let error) = doorInput(id: id, given: [call["args"] ?? .object([:])]) {
            return Self.failure(error.reason, error.detail, effects: "none")
        }
        // A named action read must pass its declaration and read classification so preview/live reads cannot become writes.
        do {
        if reads(call), let page = Parts.string(call, "page"), page.contains("."), let named = try base.action(page) {
            guard named.read else {
                return Self.failure("not_a_read", "app.read(\"\(page)\") names an action that changes something; a read never runs it. "
                    + "Call it as its own action, declared, if the ability means to.", effects: "none")
            }
            call = call.filter { $0.key.hasPrefix("__") }.merging(["action": .string(page), "args": .object([:])]) { $1 }
        }
        // A read goes through the same selection check and gates as any call.
        guard try reads(call) || Parts.string(call, "action").map({ try action($0) != nil }) == true else {
            return Self.failure("undeclared_dependency", "An ability calls only its declared app actions.", effects: "none")
        }
        if readOnly, let id = Parts.string(call, "action"), let named = try base.action(id),
           !(named.read || named.readOnly(Parts.fields(call["args"] ?? .null))) {
            return Self.failure("read_verb", "\(id) changes something, and this verb is declared read, so it only reads. Nothing ran.", effects: "none")
        }
            try Task.checkCancellation()
            try await admission()
            try Task.checkCancellation()
            let permissions = candidate.program.permissions
            let reach = permissions.contains("app_data_read") || permissions.contains("app_data_write")
                ? (root: dataRoot, write: permissions.contains("app_data_write")) : nil
            var execution = execution
            if var turn = execution.turn { turn.fileReach = reach; execution.turn = turn }
            return await base.perform(call, execution: execution)
        } catch {
            return Self.failure(error, effects: "none", execution: "not_run")
        }
    }

    func primitiveAction(_ operation: String) -> OwnedProgramAction? {
        if operation == "part.call" { return .init(id: operation, page: "tools", read: false, program: true, readOnly: { _ in false }) }
        let files = OwnedProgramRunner.hostFilePrimitives.contains(operation)
        guard operation == "apps.call" || files || ToolPrimitiveBroker.operations.contains(operation) else { return nil }
        let read = ToolPrimitiveBroker.readOperations.contains(operation)
        let space = String(operation.prefix { $0 != "." })
        let page = operation == "apps.call" ? "apps" : files ? "files" : ["screen", "frame", "hand"].contains(space) ? "screen"
            : space == "program" ? "shell" : "network"
        return OwnedProgramAction(id: operation, page: page, read: read,
                                  journaled: !ToolPrimitiveBroker.frameOperations.union(ToolPrimitiveBroker.programOperations).contains(operation),
                                  readOnly: { ToolPrimitiveBroker.readOnly(operation, .object($0)) })
    }

    func checkPrimitive(_ operation: String, arguments: JSONValue, execution: OwnedProgramExecution) async -> JSONValue? {
        if projection { return Self.failure("projection_only", "A face reads only its frozen sources.", effects: "none") }
        if let refused = readRefusal(operation, arguments) { return refused }
        do {
            if OwnedProgramRunner.hostFilePrimitives.contains(operation) {
                _ = try PartFileReads.admitted(Parts.fields(arguments)["path"], readPaths: readPaths, permissions: candidate.program.permissions)
            } else if operation == "part.call" {
                _ = try partRequest(arguments)
            } else if operation == "apps.call" {
                try Task.checkCancellation()
                guard case .object(let args) = arguments, case .string(let bundleID)? = args["bundle_id"],
                      let access = appTargets[bundleID] else {
                    throw SenseFailure(code: "undeclared_target", message: "Declare app_read:<bundle_id> or app_write:<bundle_id> for this target.")
                }
                guard access == "write" || AuthoredToolEffects.appReadOnly(args) else {
                    throw SenseFailure(code: "read_only", message: "A read-declared app refuses modifying or unclassified events.")
                }
                try AppleScriptExecution.checkAppScript(args)
                if !AuthoredToolEffects.appReadOnly(args), let refusal = MacAppActGate.refusal(bundleID: bundleID, throughAppleEvents: true,
                    context: execution.macOperation(dataRoot: dataRoot)) { throw refusal }
            } else { try await broker.check(operation, arguments: arguments) }
            return nil
        } catch {
            return Self.failure(error, effects: "none", execution: "not_run")
        }
    }

    private func partRequest(_ arguments: JSONValue) throws -> (id: String, input: JSONValue) {
        try Task.checkCancellation()
        let args = Parts.fields(arguments)
        guard !projection, let id = Parts.string(args, "id"), AbilityStore.isAbilityID(id),
              let input = args["input"], case .object = input,
              try input.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
            throw SenseFailure(code: "bad_input", message: "part.call takes an exact id and a JSON object input of at most 4 MiB.")
        }
        guard try declaredDependency("authored." + id) != nil else {
            throw SenseFailure(code: "undeclared_dependency", message: "Declare authored.\(id) in actions before calling that part.")
        }
        return (id, input)
    }

    func primitive(_ operation: String, arguments: JSONValue, preview: Bool, execution: OwnedProgramExecution) async throws -> JSONValue {
        if let refused = readRefusal(operation, arguments) { return refused }
        if operation == "part.call" {
            // Pin before any admission/card wait. The existing gated authored action runs it, retaining its terminal envelope for value calls.
            do {
                let (id, input) = try partRequest(arguments)
                guard let version = try Parts(root: dataRoot).row(id)?["codeFingerprint"]?.stringValue else {
                    throw Parts.missing(id)
                }
                var execution = execution
                execution.valueIdentity = (id, version); execution.wake = nil
                let receipt = await perform(["action": .string("authored." + id), "args": input, "preview": .bool(preview)], execution: execution)
                let result = Parts.callResult(receipt, as: JSONValue.self)
                let fields = Parts.fields(receipt)
                let effects = Parts.string(fields, "effects") ?? Parts.string(Parts.fields(fields["result"] ?? .null), "effects") ?? "unknown"
                return Self.receipt(try .fromEncodable(result), effects: effects)
            } catch {
                let failure = PartCallResult<JSONValue>.failure(.init(code: error is CancellationError ? "cancelled"
                    : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed", message: error.localizedDescription))
                return Self.receipt(try .fromEncodable(failure), effects: "none")
            }
        }
        if let refused = await checkPrimitive(operation, arguments: arguments, execution: execution) { return refused }
        if operation == "model.call" { return try await performPrimitive(operation, arguments: arguments, execution: execution) }
        // Watch frames and program reads/close stay inside their admitted operation while the same enabled version owns them.
        if ToolPrimitiveBroker.frameOperations.contains(operation) || ["program.receive", "program.close"].contains(operation) {
            do {
                if operation.hasPrefix("program.") {
                    do { try await admission() } catch { await broker.end(arguments); throw error }
                }
                return Self.receipt(try await broker.perform(operation, arguments: arguments, host: base, execution: execution,
                    openScreenWatch: openScreenWatch),
                                    effects: ToolPrimitiveBroker.readOnly(operation, arguments) ? "none" : "occurred")
            }
            catch {
                return Self.failure(error, effects: ToolPrimitiveBroker.readOnly(operation, arguments) ? "none" : "unknown", execution: "attempted")
            }
        }
        // Each new effect requires current ability admission and Trust; refused program input ends its program.
        let effect = AuthoredToolEffects.primitiveEffect(operation, arguments: arguments)
        let args = Parts.fields(arguments)
        let result = await base.admitTool(effect.tool, input: args, execution: execution, effect: {
            try await self.performPrimitive(operation, arguments: arguments, execution: execution)
        })
                ?? Self.failure(SenseFailure(code: "door_unavailable", message: "A primitive needs the app door's gate chain from a conversation or wake run.",
                    remedy: Repair.reconcile(instruction: """
                        Read ability \(candidate.id) and its recorded effects, then do only the missing work through the gated app door of a conversation \
                        or wake run.
                        """, nextCall: Parts.readCall(candidate.id))), effects: "none", execution: "not_run")
        if operation == "program.send", Parts.fields(result)["status"] != .string("ok") { await broker.end(arguments) }
        return result
    }

    private func performPrimitive(_ operation: String, arguments: JSONValue, execution: OwnedProgramExecution) async throws -> JSONValue {
        var dispatched = false
        do {
            try await admission()
            guard await !broker.closed else { throw CancellationError() }
            dispatched = true
            let result = if operation == "apps.call" {
                try await AppleScriptExecution().callApp(arguments, targets: appTargets, context: execution.macOperation(dataRoot: dataRoot))
            } else if operation == "files.query" {
                try PartFileReads.query(try PartFileReads.admitted(Parts.fields(arguments)["path"], readPaths: readPaths,
                    permissions: candidate.program.permissions), Parts.fields(arguments))
            } else if operation == "files.mime" {
                try PartFileReads.mime(try PartFileReads.admitted(Parts.fields(arguments)["path"], readPaths: readPaths,
                    permissions: candidate.program.permissions), Parts.fields(arguments))
            } else { try await broker.perform(operation, arguments: arguments, host: base, profile: self, execution: execution,
                openScreenWatch: openScreenWatch) }
            // The thought's envelope already carries its nested tool effects.
            if operation == "model.call" { return result }
            if operation == "apps.call", result.objectValue?["status"] == .string("denied") { return result }
            let read = ToolPrimitiveBroker.readOnly(operation, arguments)
            // Effect receipts derive from observed events, never app-call intent.
            let observed = if operation == "apps.call", case .object(let fields) = result, case .string(
                let effects)? = fields["effects"] { effects } else { nil as String? }
            if operation == "apps.call", case .object(let fields) = result, case .string(let state)? = fields["state"] {
                let effects = observed ?? (read || ["needs_consent", "denied", "unavailable"].contains(state) ? "none" : "unknown")
                // A write that may have landed is unknown, never refused: a refusal says nothing happened.
                var refusal: [String: JSONValue] = ["status": .string(effects == "unknown" ? "unknown" : "refused"), "reason": .string(state),
                    "detail": fields["detail"] ?? .string(state), "result": result, "effects": .string(effects)]
                refusal["remedy"] = fields["remedy"]
                return .object(refusal)
            }
            return Self.receipt(result, effects: observed ?? (read ? "none" : "occurred"))
        } catch {
            // A refused screen-control card cannot claim execution.
            if let refusal = error as? MacScreenWatch.Refusal {
                return .object(Parts.fields(refusal.receipt).merging(["effects": .string("none")]) { said, _ in said })
            }
            return Self.failure(error,
                effects: !dispatched || ToolPrimitiveBroker.readOnly(operation, arguments) ? "none" : "unknown",
                execution: dispatched ? "attempted" : "not_run")
        }
    }

    static func receipt(_ result: JSONValue, effects: String) -> JSONValue {
        .object(["status": .string("ok"), "effects": .string(effects), "result": result])
    }
    static func failure(_ error: Error, effects: String, execution: String) -> JSONValue {
        if let refusal = error as? MacAppActRefusal { return .object(refusal.fields.merging([
            "effects": .string(effects), "execution": .string(execution)
        ]) { said, _ in said }) }
        let owned = error as? ToolFailureError
        let sense = error as? SenseFailure
        let reason = owned?.failureCode ?? sense?.code ?? (error is CancellationError ? "cancelled" : "world_error")
        var fields = sense?.failureEvidence() ?? Parts.fields(failure(reason, error.localizedDescription,
            effects: owned?.effects.rawValue ?? effects, execution: execution,
            status: owned?.status.rawValue ?? (reason == "cancelled" ? "cancelled" : "failed")))
        fields["effects"] = .string(owned?.effects.rawValue ?? effects)
        fields["execution"] = .string(execution)
        fields["result"] = .null
        fields["failure_code"] = .string(reason)
        if let owned {
            fields.merge(owned.failureEvidence(defaultCode: reason)) { _, owned in owned }
        } else if fields["remedy"] == nil, reason == "cancelled" {
            fields["remedy"] = Repair.terminal(instruction: "The caller cancelled this work; do not resume it without a new request.")
        }
        return .object(fields)
    }

    static func failure(_ reason: String, _ detail: String, effects: String, execution: String? = nil, status: String = "refused") -> JSONValue {
        var fields: [String: JSONValue] = ["status": .string(status), "reason": .string(reason), "detail": .string(detail),
                                         "effects": .string(effects), "result": .null]
        if let execution { fields["execution"] = .string(execution) }
        return .object(fields)
    }
}
