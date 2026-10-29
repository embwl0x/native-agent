import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import ToolRegistry
import MacControl
// Blueprint: | `PartHost.swift` | rehearsal shares one lazy helper across fixtures and decision replays; `Parts.rehearse`, `ToolHost`: a part's declared actions, files by reach and primitives through the broker; nested part calls are programs, retaining preview and their typed result while child effects stay suppressed; projection execution refuses host effects, model tool thinking retains this same restricted host and passes its native effect envelope through unchanged; `Parts.rehearse`, `ToolHost`: a part's declared actions and the exact shared capability action map and primitives through the broker |

extension Parts {
    /// Rehearses one version through the shipped runner with every host call
    /// intercepted, and seals the proof; throws what stopped it.
    func rehearse(_ candidate: OwnedProgramStore.Candidate, capture: Bool, input: JSONValue?) async throws -> JSONValue {
        guard let base = OwnedProgramInvocation.host else {
            throw PartError.invalid("Rehearsal needs the gated app door of a conversation or wake run.")
        }
        try checkDependencies(candidate)
        let key = try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()
        let broker = ToolPrimitiveBroker(permissions: Set(candidate.program.permissions), abilityID: candidate.id)
        let host = ToolHost(base: base, candidate: candidate, broker: broker, dataRoot: root, admission: {})
        do {
            let proof = try await store.validate(candidate, key: key, capture: capture, input: input, runner: OwnedProgramRunner(dataRoot: root).rehearsal(), host: { host }) {
                if let problem = $0.schemaProblem(schema: candidate.program.schema) {
                    throw SenseFailure(code: "bad_input", message: "Its input \(problem.path) must be \(problem.expected).", remedy: .object([
                        "kind": .string("correct_arguments"), "instruction": .string("Correct input \(problem.path) to match \(problem.expected) in ability.validate for \(candidate.id)."), "next_call": .null]))
                }
            }
            await broker.close()
            return proof
        } catch {
            await broker.close()
            throw error
        }
    }
}

struct ToolHost: OwnedProgramHostProfile {
    let base: any OwnedProgramToolHost
    let candidate: OwnedProgramStore.Candidate
    let broker: ToolPrimitiveBroker
    let dataRoot: URL
    var projection = false
    var preview = false
    let admission: @Sendable () async throws -> Void
    private var appTargets: [String: String] {
        var targets: [String: String] = [:]
        for permission in candidate.program.permissions {
            let parts = permission.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, ["app_read", "app_write"].contains(parts[0]), targets[parts[1]] != "write" {
                targets[parts[1]] = parts[0] == "app_write" ? "write" : "read"
            }
        }
        return targets
    }
    var actionIDs: [String] { candidate.program.dependencies }
    private func declaredDependency(_ id: String) -> String? {
        let resolved = base.canonicalAction(id)
        return candidate.program.dependencies.first { base.canonicalAction($0) == resolved }
    }
    private func dependencyMatches(_ id: String) -> Bool {
        guard let declared = declaredDependency(id) else { return action(id) != nil }
        return base.dependencyMatches(id, Parts.fields(candidate.dependencyShapes)[declared])
    }
    var floorReasons: Set<String> { base.floorReasons.union(["undeclared_dependency", "state_changed"]) }
    var scriptKey: String { base.scriptKey }
    func action(_ id: String) -> OwnedProgramAction? {
        if projection { return nil }
        guard let action = base.action(id) else { return nil }
        let permissions = candidate.program.permissions
        return declaredDependency(id) != nil || AbilityStore.reachActions(permissions).contains(base.canonicalAction(id)) ? action : nil
    }
    func canonicalAction(_ id: String) -> String { base.canonicalAction(id) }
    func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
        guard action(id) != nil else {
            let declared = Parts.fields(candidate.manifest)["declaredActions"].map { Parts.strings($0) } ?? candidate.program.dependencies
            let actions = Set(declared + [id]).sorted().map { "\"" + $0 + "\"" }.joined(separator: ", ")
            return .failure(.init(reason: "undeclared_dependency", detail: "\(id) is not among the actions ability \(candidate.id) declares, so it was not called. "
                + "An action named at run time isn't read off the code: declare it with ability.save {id:\"\(candidate.id)\", actions:[\(actions)]}."))
        }
        return base.doorInput(id: id, given: given)
    }
    func opensHomeItem(_ input: [String: JSONValue]) -> Bool { base.opensHomeItem(input) }
    func secretLine(_ text: String) -> Bool { base.secretLine(text) }
    func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence { base.evidence(receipt) }
    func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { base.receiptField(key, in: receipt) }
    func answer(_ receipt: JSONValue) -> JSONValue { base.answer(receipt) }
    /// A page read or a find (`app.read`, `app.find`): the runner's own read
    /// envelope, which no declaration names and every part may make.
    private func reads(_ call: [String: JSONValue]) -> Bool {
        call["action"] == nil && (call["page"] != nil || call["find"] != nil)
    }
    func validationPerform(_ call: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue {
        if reads(call) { return await fixture.reply(call) }
        guard case .string(let id)? = call["action"], action(id) != nil,
              dependencyMatches(id) else {
            let id = Parts.string(call, "action") ?? "(missing action)"
            return Self.failure(Parts.revisionFailure("stale_dependency", "Ability \(candidate.id) version \(candidate.digest) declares unavailable or changed action \(id).", id: candidate.id, version: candidate.digest), effects: "none", execution: "not_run")
        }
        return await fixture.reply(call)
    }

    func perform(_ call: [String: JSONValue]) async -> JSONValue {
        if projection { return Self.failure("projection_only", "A face reads only its frozen sources.", effects: "none") }
        var call = call
        // A thought in a preview has the same preview posture as its code;
        // raw model JSON can never turn a preview into a live effect.
        if preview { call["preview"] = .bool(true) }
        // JavaScript and model tools share this boundary. Neither can bypass
        // authored secret/typed-text restrictions by supplying raw app JSON.
        if opensHomeItem(call) {
            return Self.failure("home_item_in_script", "A part cannot open a home arrival from inside its own run.", effects: "none")
        }
        if let id = Parts.string(call, "action"),
           case .failure(let error) = doorInput(id: id, given: [call["args"] ?? .object([:])]) {
            return Self.failure(error.reason, error.detail, effects: "none")
        }
        // A read that names an action (app.read("photos.recent")) is that action's
        // call, through its declaration like any other, and only when the
        // registry classifies it as a read: a read never becomes a write, live
        // or in a preview.
        if reads(call), let page = Parts.string(call, "page"), page.contains("."), let named = base.action(page) {
            guard named.read else {
                return Self.failure("not_a_read", "app.read(\"\(page)\") names an action that changes something; a read never runs it. "
                    + "Call it as its own action, declared, if the ability means to.", effects: "none")
            }
            call = call.filter { $0.key.hasPrefix("__") }.merging(["action": .string(page), "args": .object([:])]) { $1 }
        }
        // A read goes through the same selection check and gates as any call.
        guard reads(call) || Parts.string(call, "action").map({ action($0) != nil }) == true else {
            return Self.failure("undeclared_dependency", "An ability calls only its declared app actions.", effects: "none")
        }
        do {
            try Task.checkCancellation()
            try await admission()
            try Task.checkCancellation()
            let permissions = candidate.program.permissions
            let reach = permissions.contains("app_data_read") || permissions.contains("app_data_write")
                ? (root: dataRoot, write: permissions.contains("app_data_write")) : nil
            return await AbilityStore.$fileReach.withValue(reach) { await base.perform(call) }
        } catch {
            return Self.failure(error, effects: "none", execution: "not_run")
        }
    }

    func primitiveAction(_ operation: String) -> OwnedProgramAction? {
        if operation == "part.call" { return .init(id: operation, page: "tools", read: false, program: true, readOnly: { _ in false }) }
        guard operation == "apps.call" || ToolPrimitiveBroker.operations.contains(operation) else { return nil }
        let read = ToolPrimitiveBroker.readOperations.contains(operation)
        let space = String(operation.prefix { $0 != "." })
        let page = operation == "apps.call" ? "apps" : ["screen", "frame", "hand"].contains(space) ? "screen" : space == "program" ? "shell" : "network"
        return OwnedProgramAction(id: operation, page: page, read: read,
                                  journaled: !ToolPrimitiveBroker.frameOperations.union(ToolPrimitiveBroker.programOperations).contains(operation),
                                  readOnly: { ToolPrimitiveBroker.readOnly(operation, .object($0)) })
    }

    func checkPrimitive(_ operation: String, arguments: JSONValue) async -> JSONValue? {
        if projection { return Self.failure("projection_only", "A face reads only its frozen sources.", effects: "none") }
        do {
            if operation == "part.call" {
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
        guard declaredDependency("authored." + id) != nil else {
            throw SenseFailure(code: "undeclared_dependency", message: "Declare authored.\(id) in actions before calling that part.")
        }
        return (id, input)
    }

    func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue {
        if operation == "part.call" {
            // Pin before any admission/card wait. The existing gated authored
            // action runs it, retaining its terminal envelope for value calls.
            do {
                let (id, input) = try partRequest(arguments)
                guard let version = try Parts(root: dataRoot).row(id)?["codeFingerprint"]?.stringValue else {
                    throw Parts.missing(id)
                }
                let receipt = await OwnedProgramInvocation.$valueCall.withValue((id, version)) {
                    await perform(["action": .string("authored." + id), "args": input, "preview": .bool(preview)])
                }
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
        if let refused = await checkPrimitive(operation, arguments: arguments) { return refused }
        if operation == "model.call" { return try await performPrimitive(operation, arguments: arguments) }
        // A watch's frames are reads inside its admitted watch, at frame speed.
        // Reading or closing a program is inside its admitted start, while the
        // ability is still the one admitted; one disabled or replaced since
        // ends its program.
        if ToolPrimitiveBroker.frameOperations.contains(operation) || ["program.receive", "program.close"].contains(operation) {
            do {
                if operation.hasPrefix("program.") {
                    do { try await admission() } catch { await broker.end(arguments); throw error }
                }
                return Self.receipt(try await broker.perform(operation, arguments: arguments, host: base),
                                    effects: ToolPrimitiveBroker.readOnly(operation, arguments) ? "none" : "occurred")
            }
            catch {
                return Self.failure(error, effects: ToolPrimitiveBroker.readOnly(operation, arguments) ? "none" : "unknown", execution: "attempted")
            }
        }
        // Everything else, a program's input included, is an effect at its own
        // time: this ability's admission and today's Trust, card and all. A
        // program whose input was refused is ended.
        let effect = AuthoredToolEffects.primitiveEffect(operation, arguments: arguments)
        let args = Parts.fields(arguments)
        let result = await AuthoredToolEffects.$call.withValue((effect.tool, {
            try await self.performPrimitive(operation, arguments: arguments)
        })) {
            await base.admitTool(effect.tool, input: args)
                ?? Self.failure(SenseFailure(code: "door_unavailable", message: "A primitive needs the app door's gate chain from a conversation or wake run.",
                    remedy: Repair.reconcile(instruction: "Read ability \(candidate.id) and its recorded effects, then do only the missing work through the gated app door of a conversation or wake run.", nextCall: Parts.readCall(candidate.id))), effects: "none", execution: "not_run")
        }
        if operation == "program.send", Parts.fields(result)["status"] != .string("ok") { await broker.end(arguments) }
        return result
    }

    private func performPrimitive(_ operation: String, arguments: JSONValue) async throws -> JSONValue {
        var dispatched = false
        do {
            try await admission()
            guard await !broker.closed else { throw CancellationError() }
            dispatched = true
            let result = if operation == "apps.call" {
                try await AppleScriptExecution().callApp(arguments, targets: appTargets)
            } else { try await broker.perform(operation, arguments: arguments, host: base, profile: self) }
            // The thought's envelope already carries its nested tool effects.
            if operation == "model.call" { return result }
            let read = ToolPrimitiveBroker.readOnly(operation, arguments)
            // An app call's effects are what its events did, as its adapter observed them.
            let observed = if operation == "apps.call", case .object(let fields) = result, case .string(let effects)? = fields["effects"] { effects } else { nil as String? }
            if operation == "apps.call", case .object(let fields) = result, case .string(let state)? = fields["state"] {
                var refusal: [String: JSONValue] = ["status": .string("refused"), "reason": .string(state),
                    "detail": fields["detail"] ?? .string(state), "result": result,
                    "effects": .string(observed ?? (read || ["needs_consent", "denied", "unavailable"].contains(state) ? "none" : "unknown"))]
                if state == "needs_consent", case .string(let bundleID)? = fields["bundle_id"] {
                    refusal["detail"] = .string("macOS Automation consent has not been asked for \(bundleID). Request the owner's permission card to ask macOS.")
                    refusal["next_call"] = .object(["tool": .string("app"), "input": .object([
                        "action": .string("card.request"), "args": .object([
                            "kind": .string("permission"), "target": .string("applescript:\(bundleID)"),
                            "mode": .string(read ? "read" : "write"),
                            "why": .string("This app call needs macOS Automation consent for \(bundleID)."),
                            "decline_consequence": .string("I won't run this app call without your Automation consent.")])])])
                }
                return .object(refusal)
            }
            return Self.receipt(result, effects: observed ?? (read ? "none" : "occurred"))
        } catch {
            // Screen control's card, refused before anything ran.
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
