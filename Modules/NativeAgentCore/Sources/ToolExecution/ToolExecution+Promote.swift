import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import ToolRegistry

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
        let broker = ToolPrimitiveBroker(root: root, permissions: Set(candidate.program.permissions))
        let host = ToolHost(base: base, candidate: candidate, broker: broker, input: Self.fields(input ?? .object([:])), admission: {})
        do {
            let proof = try await store.validate(candidate, key: key, capture: capture, input: input, runner: runner, host: { host }) {
                try ToolPrimitiveBroker.checkInput($0, schema: candidate.program.schema)
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
    let input: [String: JSONValue]
    let admission: @Sendable () async throws -> Void
    var actionIDs: [String] { candidate.program.dependencies }
    var floorReasons: Set<String> { base.floorReasons.union(["undeclared_dependency", "state_changed"]) }
    var scriptKey: String { base.scriptKey }
    func action(_ id: String) -> OwnedProgramAction? { actionIDs.contains(id) ? base.action(id) : nil }
    func canonicalAction(_ id: String) -> String { base.canonicalAction(id) }
    func doorInput(id: String, given: [JSONValue]) -> Result<[String: JSONValue], OwnedProgramRunner.ScriptError> {
        guard actionIDs.contains(id) else {
            return .failure(.init(reason: "undeclared_dependency", detail: "Declare \(id) as an app-action dependency and validate it. It was not called."))
        }
        return base.doorInput(id: id, given: given)
    }
    func opensHomeItem(_ input: [String: JSONValue]) -> Bool { base.opensHomeItem(input) }
    func secretLine(_ text: String) -> Bool { base.secretLine(text) }
    func evidence(_ receipt: JSONValue) -> OwnedProgramReceiptEvidence { base.evidence(receipt) }
    func receiptField(_ key: String, in receipt: JSONValue) -> JSONValue? { base.receiptField(key, in: receipt) }
    func validationPerform(_ call: [String: JSONValue], fixture: OwnedProgramFixtures) async -> JSONValue {
        guard case .string(let id)? = call["action"], actionIDs.contains(id),
              base.dependencyMatches(id, SwiftNativeToolExecution.fields(candidate.dependencyShapes)[id]) else {
            return Self.failure("stale_dependency", "The declared app action is unavailable or changed.", effects: "none")
        }
        return await fixture.reply(call)
    }

    func perform(_ call: [String: JSONValue]) async -> JSONValue {
        guard case .string(let id)? = call["action"], actionIDs.contains(id) else {
            return Self.failure("undeclared_dependency", "A tool calls only its declared app actions.", effects: "none")
        }
        do {
            try Task.checkCancellation()
            guard base.dependencyMatches(id, SwiftNativeToolExecution.fields(candidate.dependencyShapes)[id]) else {
                throw SenseFailure(code: "stale_dependency", message: "The app action changed after validation.")
            }
            try await admission()
            try Task.checkCancellation()
            return await base.perform(call)
        } catch {
            return Self.failure((error as? SenseFailure)?.code ?? (error is CancellationError ? "cancelled" : "failed"),
                                error.localizedDescription, effects: "none")
        }
    }

    func primitiveAction(_ operation: String) -> OwnedProgramAction? {
        guard ToolPrimitiveBroker.operations.contains(operation) else { return nil }
        let read = ToolPrimitiveBroker.readOperations.contains(operation)
        return OwnedProgramAction(id: operation, page: operation.hasPrefix("files.") ? "files" : operation == "apps.call" ? "apps" : "network",
                                  read: read, readOnly: { ToolPrimitiveBroker.readOnly(operation, .object($0)) })
    }

    func checkPrimitive(_ operation: String, arguments: JSONValue) async -> JSONValue? {
        do {
            try await broker.check(operation, arguments: arguments)
            return nil
        } catch {
            let reason = (error as? SenseFailure)?.code ?? (error is CancellationError ? "cancelled" : "world_error")
            return Self.failure(reason, error.localizedDescription, effects: "none")
        }
    }

    func primitive(_ operation: String, arguments: JSONValue, preview: Bool) async throws -> JSONValue {
        if let refused = await checkPrimitive(operation, arguments: arguments) { return refused }
        var dispatched = false
        do {
            try await admission()
            if let refused = await base.admitTool(candidate.program.id, input: input.merging([
                "__authored_primitive": .object(["operation": .string(operation), "arguments": arguments,
                                                "fingerprint": .string(candidate.digest)])
            ]) { $1 }) {
                guard case .object(var fields) = refused else { return refused }
                fields["execution"] = .string("not_run")
                return .object(fields)
            }
            dispatched = true
            let result = try await broker.perform(operation, arguments: arguments)
            let read = ToolPrimitiveBroker.readOnly(operation, arguments)
            if operation == "apps.call", case .object(let fields) = result, case .string(let state)? = fields["state"] {
                var refusal: [String: JSONValue] = ["status": .string("refused"), "reason": .string(state),
                    "detail": fields["detail"] ?? .string(state), "result": result,
                    "effects": .string(read || ["needs_consent", "denied", "unavailable"].contains(state) ? "none" : "unknown")]
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
            return Self.receipt(result, effects: read ? "none" : "occurred")
        } catch {
            let reason = (error as? SenseFailure)?.code ?? (error is CancellationError ? "cancelled" : "world_error")
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
