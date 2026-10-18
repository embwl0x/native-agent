import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import ToolRegistry
import MacControl

extension SwiftNativeToolExecution {
    func validate(_ candidate: OwnedProgramStore.Candidate, capture: Bool = false, input: JSONValue? = nil) async throws -> ProposalValidationResult {
        guard let base = OwnedProgramInvocation.host else {
            throw ToolExecutionError.invalidProposal("Runtime validation requires the app door and installed helper")
        }
        try checkDependencies(candidate)
        let key = try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()
        let helper = SenseHostLocator.helperURL, dataRoot = root
        let runner = OwnedProgramRunner(helperURL: helper, dataRoot: dataRoot) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helper, scratch: scratch,
                dataRoot: dataRoot, personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        }
        let broker = ToolPrimitiveBroker(permissions: Set(candidate.program.permissions), host: base, abilityID: candidate.id)
        let host = ToolHost(base: base, candidate: candidate, broker: broker, dataRoot: root, admission: {})
        do {
            let proof = try await store.validate(candidate, key: key, capture: capture, input: input, runner: runner, host: { host }) {
                if let problem = $0.schemaProblem(schema: candidate.program.schema) {
                    throw SenseFailure(code: "bad_input", message: "Tool input \(problem.path) must be \(problem.expected).")
                }
            }
            await broker.close()
            return ProposalValidationResult(valid: true,
                autoPromotable: !candidate.program.permissions.isEmpty
                    && Set(candidate.program.permissions).isSubset(of: ["app_data_read", "app_data_write"]), errors: [],
                candidateDigest: candidate.digest, capture: Self.string(Self.fields(proof), "capture"))
        } catch {
            await broker.close()
            if (error as? SenseFailure)?.code == "stale_validation" { throw error }
            return ProposalValidationResult(valid: false, autoPromotable: false, errors: [error.localizedDescription],
                                            candidateDigest: candidate.digest)
        }
    }
}

struct ToolHost: OwnedProgramHostProfile {
    let base: any OwnedProgramToolHost
    let candidate: OwnedProgramStore.Candidate
    let broker: ToolPrimitiveBroker
    let dataRoot: URL
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
        return base.dependencyMatches(id, SwiftNativeToolExecution.fields(candidate.dependencyShapes)[declared])
    }
    var floorReasons: Set<String> { base.floorReasons.union(["undeclared_dependency", "state_changed"]) }
    var scriptKey: String { base.scriptKey }
    func action(_ id: String) -> OwnedProgramAction? {
        guard let action = base.action(id) else { return nil }
        let permissions = candidate.program.permissions
        return declaredDependency(id) != nil || action.page == "files" && (permissions.contains("app_data_write")
            || action.read && permissions.contains("app_data_read")) ? action : nil
    }
    func canonicalAction(_ id: String) -> String { base.canonicalAction(id) }
    func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
        guard action(id) != nil else {
            return .failure(.init(reason: "undeclared_dependency", detail: "Declare \(id) as an app-action dependency and validate it. It was not called."))
        }
        return base.doorInput(id: id, given: given)
    }
    func opensHomeItem(_ input: [String: JSONValue]) -> Bool { base.opensHomeItem(input) }
    func secretLine(_ text: String) -> Bool { base.secretLine(text) }
    func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence { base.evidence(receipt) }
    func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { base.receiptField(key, in: receipt) }
    func validationPerform(_ call: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue {
        guard case .string(let id)? = call["action"], action(id) != nil,
              dependencyMatches(id) else {
            return Self.failure("stale_dependency", "The declared app action is unavailable or changed.", effects: "none")
        }
        return await fixture.reply(call)
    }

    func perform(_ call: [String: JSONValue]) async -> JSONValue {
        guard case .string(let id)? = call["action"], action(id) != nil else {
            return Self.failure("undeclared_dependency", "A tool calls only its declared app actions.", effects: "none")
        }
        do {
            try Task.checkCancellation()
            guard dependencyMatches(id) else {
                throw SenseFailure(code: "stale_dependency", message: "The app action changed after validation.")
            }
            try await admission()
            try Task.checkCancellation()
            let permissions = candidate.program.permissions
            let reach = permissions.contains("app_data_read") || permissions.contains("app_data_write")
                ? (root: dataRoot, write: permissions.contains("app_data_write")) : nil
            return await AbilityStore.$fileReach.withValue(reach) { await base.perform(call) }
        } catch {
            return Self.failure((error as? SenseFailure)?.code ?? (error is CancellationError ? "cancelled" : "failed"),
                                error.localizedDescription, effects: "none")
        }
    }

    func primitiveAction(_ operation: String) -> OwnedProgramAction? {
        guard operation == "apps.call" || ToolPrimitiveBroker.operations.contains(operation) else { return nil }
        let read = ToolPrimitiveBroker.readOperations.contains(operation)
        return OwnedProgramAction(id: operation, page: operation == "apps.call" ? "apps" : "network",
                                  read: read, readOnly: { ToolPrimitiveBroker.readOnly(operation, .object($0)) })
    }

    func checkPrimitive(_ operation: String, arguments: JSONValue) async -> JSONValue? {
        do {
            if operation == "apps.call" {
                try Task.checkCancellation()
                guard case .object(let args) = arguments, case .string(let bundleID)? = args["bundle_id"],
                      let access = appTargets[bundleID] else {
                    throw SenseFailure(code: "undeclared_target", message: "Declare app_read:<bundle_id> or app_write:<bundle_id> for this target.")
                }
                guard access == "write" || AuthoredToolEffects.appReadOnly(args) else {
                    throw SenseFailure(code: "read_only", message: "A read-declared app refuses modifying or unclassified events.")
                }
                try SystemAppleScriptAdapter.checkAppScript(args)
            } else { try await broker.check(operation, arguments: arguments) }
            return nil
        } catch {
            let reason = (error as? SenseFailure)?.code ?? (error is CancellationError ? "cancelled" : "world_error")
            return Self.failure(reason, error.localizedDescription, effects: "none")
        }
    }

    func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue {
        if let refused = await checkPrimitive(operation, arguments: arguments) { return refused }
        if operation == "model.call" { return try await performPrimitive(operation, arguments: arguments) }
        let effect = AuthoredToolEffects.primitiveEffect(operation, arguments: arguments)
        let args = SwiftNativeToolExecution.fields(arguments)
        return await AuthoredToolEffects.$call.withValue((effect.tool, {
            try await self.performPrimitive(operation, arguments: arguments)
        })) {
            await base.admitTool(effect.tool, input: args)
                ?? Self.failure("door_unavailable", "A primitive needs the originating turn's gate chain.", effects: "none")
        }
    }

    private func performPrimitive(_ operation: String, arguments: JSONValue) async throws -> JSONValue {
        var dispatched = false
        do {
            try await admission()
            guard await !broker.closed else { throw CancellationError() }
            dispatched = true
            let result = if operation == "apps.call" {
                try await SystemAppleScriptAdapter().callApp(arguments, targets: appTargets)
            } else { try await broker.perform(operation, arguments: arguments) }
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
            let code = (error as? SenseFailure)?.code
            let reason = error is CancellationError ? "cancelled" : code ?? "world_error"
            return Self.failure(reason, error.localizedDescription,
                effects: !dispatched || ToolPrimitiveBroker.readOnly(operation, arguments) ? "none" : "unknown",
                execution: dispatched ? "attempted" : "not_run")
        }
    }

    static func receipt(_ result: JSONValue, effects: String) -> JSONValue {
        .object(["status": .string("ok"), "effects": .string(effects), "result": result])
    }
    static func failure(_ reason: String, _ detail: String, effects: String, execution: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["status": .string("refused"), "reason": .string(reason), "detail": .string(detail),
                                         "effects": .string(effects), "result": .null]
        if let execution { fields["execution"] = .string(execution) }
        return .object(fields)
    }
}
