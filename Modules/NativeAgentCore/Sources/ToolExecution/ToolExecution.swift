import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry
import Senses

// MARK: - Errors

/// Errors raised by the tool-execution proposal lifecycle.
public enum ToolExecutionError: Error, LocalizedError {
    case invalidProposal(String)
    case proposalNotFound(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProposal(let msg): return "invalid proposal: \(msg)"
        case .proposalNotFound(let id): return "proposal not found: \(id)"
        case .underlying(let m): return m
        }
    }
}

// MARK: - ProposalRecord
//
// The daemon writes a schema-loose dict per proposal (create_tool_proposal
// in the retired daemon). We carve the typed fields the
// Swift lifecycle reasons about (id/name/description/manifest/riskClass/
// permissions/status/createdAt/validatedAt/validationErrors) and stash
// EVERYTHING ELSE in `extras` so a round-trip never drops daemon-written
// keys. Mirrors the ToolRecord pattern in ToolRegistry.

public struct ProposalRecord: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var description: String?
    public var manifest: JSONValue
    public var riskClass: String?
    public var permissions: [String]?
    public var status: String   // proposed | valid | rejected | promoted
    public var createdAt: String
    public var validatedAt: String?
    public var validationErrors: [String]?
    public var extras: JSONValue?
}

extension ProposalRecord {
    static let typedKeys: Set<String> = [
        "id", "name", "description", "manifest", "riskClass",
        "permissions", "status", "createdAt", "validatedAt",
        "validationErrors", "extras",
    ]

    /// Parse from a daemon-shaped JSON object. Returns nil if id/name/status
    /// /createdAt are missing — those are required fields.
    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        func str(_ k: String) -> String {
            if case .string(let s) = obj[k] ?? .null { return s }
            return ""
        }
        let idS = str("id")
        let nameS = str("name")
        let statusS = str("status")
        let createdS = str("createdAt")
        if idS.isEmpty || nameS.isEmpty || statusS.isEmpty || createdS.isEmpty {
            return nil
        }
        self.id = idS
        self.name = nameS
        self.status = statusS
        self.createdAt = createdS

        func optStr(_ k: String) -> String? {
            if case .string(let s) = obj[k] ?? .null { return s.isEmpty ? nil : s }
            return nil
        }
        self.description = optStr("description")
        self.riskClass = optStr("riskClass")
        self.validatedAt = optStr("validatedAt")

        if case .array(let arr) = obj["permissions"] ?? .null {
            self.permissions = arr.compactMap { v in
                if case .string(let s) = v { return s } else { return nil }
            }
        } else {
            self.permissions = nil
        }
        if case .array(let arr) = obj["validationErrors"] ?? .null {
            self.validationErrors = arr.compactMap { v in
                if case .string(let s) = v { return s } else { return nil }
            }
        } else {
            self.validationErrors = nil
        }
        // manifest: the daemon's create_tool_proposal stores the manifest at
        // the top level of the record (it spreads `**manifest`). For our
        // typed shape we ALSO accept an explicit "manifest" key, and fall
        // back to "everything that isn't a carved typed key" — same logic
        // ToolRecord uses for extras.
        if let m = obj["manifest"], case .object = m {
            self.manifest = m
        } else {
            self.manifest = .object(obj)
        }
        var extra: [String: JSONValue] = [:]
        for (k, v) in obj where !ProposalRecord.typedKeys.contains(k) {
            extra[k] = v
        }
        self.extras = extra.isEmpty ? nil : .object(extra)
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "status": .string(status),
            "createdAt": .string(createdAt),
            "manifest": manifest,
        ]
        if let d = description { obj["description"] = .string(d) }
        if let r = riskClass { obj["riskClass"] = .string(r) }
        if let p = permissions { obj["permissions"] = .array(p.map { .string($0) }) }
        if let v = validatedAt { obj["validatedAt"] = .string(v) }
        if let e = validationErrors { obj["validationErrors"] = .array(e.map { .string($0) }) }
        if case .object(let extra)? = extras {
            for (k, v) in extra where !ProposalRecord.typedKeys.contains(k) {
                obj[k] = v
            }
        }
        return .object(obj)
    }
}

// MARK: - ProposalValidationResult

public struct ProposalValidationResult: Sendable, Equatable, Codable {
    public var valid: Bool
    public var autoPromotable: Bool
    public var errors: [String]
    public var candidateDigest: String?
    public var capture: String?

    public init(valid: Bool, autoPromotable: Bool, errors: [String], candidateDigest: String? = nil, capture: String? = nil) {
        self.valid = valid
        self.autoPromotable = autoPromotable
        self.errors = errors
        self.candidateDigest = candidateDigest
        self.capture = capture
    }
}


public actor SwiftNativeToolExecution {
    let root: URL
    var store: OwnedProgramStore { OwnedProgramStore(root: root.appendingPathComponent("tools")) }
    var abilities: AbilityStore { AbilityStore(dataRoot: root) }

    public init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.root = root
    }

    public func propose(id: String, description: String, code: String, tests: [JSONValue],
                        permissions: [String], inputSchema: JSONValue?, actions: [String] = [],
                        origin: JSONValue = .string("self"), capture: Bool = false, input: JSONValue? = nil,
                        converts: JSONValue? = nil) async throws -> ProposalValidationResult {
        guard id.range(of: #"^[a-z][a-z0-9_]{1,47}$"#, options: .regularExpression) != nil,
              !description.isEmpty, !code.isEmpty else {
            throw ToolExecutionError.invalidProposal("tool_id is 2 to 48 lowercase letters, digits and underscores; description and code are required")
        }
        guard permissions.count == Set(permissions).count,
              permissions.allSatisfy(ToolPrimitiveBroker.knownPermission),
              actions.count == Set(actions).count, actions.count <= OwnedProgramRunner.actionLimit else {
            throw ToolExecutionError.invalidProposal("Declare known permissions and distinct app actions; omit tests to capture validation")
        }
        let existing = try await SwiftNativeToolRegistry(root: root).getTool(id: id)
        let schema = inputSchema ?? .object(["type": .string("object"), "properties": .object([:])])
        guard case .object = schema else { throw ToolExecutionError.invalidProposal("input_schema must be an object") }
        let manifest: JSONValue = .object([
            "id": .string(id), "name": .string(id), "description": .string(description), "triggers": .array([]),
            "language": .string("javascript"), "entrypoint": .string("tool.js"), "inputSchema": schema,
            "permissions": .array(permissions.map(JSONValue.string)), "actions": .array(actions.map(JSONValue.string)), "origin": origin,
            "converts": try OwnedProgramStore.conversionSources(converts),
        ])
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .tool, id: id, version: "candidate", source: code, entry: .run,
                                  schema: schema, dependencies: actions, permissions: permissions),
            manifest: manifest, fixtures: .array(tests), dependencyShapes: dependencyShapes(actions),
            prior: OwnedProgramStore.selection(existing?.toJSON()))
        let path = try abilities.path(id: id, slot: .next).path
        let stamp = Self.isoTimestamp(Date())
        let candidateStore = store
        try await ToolRegistryActions.mutate(id: id, dataRoot: root) { current in
            guard OwnedProgramStore.selection(current.map(JSONValue.object)) == candidate.prior else {
                throw ToolExecutionError.invalidProposal("The selected tool changed; propose against its current version")
            }
            try candidateStore.stage(candidate)
            var row = current ?? [:]
            if current == nil {
                row.merge(Self.fields(manifest)) { $1 }
                row["status"] = .string("proposed"); row["phase"] = .string("proposed")
                row["validationStatus"] = .string("invalid")
            }
            row["createdAt"] = row["createdAt"] ?? .string(stamp); row["updatedAt"] = .string(stamp)
            row["candidateDigest"] = .string(candidate.digest); row["candidatePrior"] = candidate.prior
            row["candidateValidation"] = .string("invalid"); row["proposalPath"] = .string(path)
            row = try CapabilityLifecycle.preservingOwnerOff(row, before: current)
            row["candidateSelection"] = OwnedProgramStore.selection(.object(row))
            return row
        }
        return try await validateProposal(id: id, capture: capture, input: input)
    }

    public func validateProposal(id: String, capture: Bool = false, input: JSONValue? = nil) async throws -> ProposalValidationResult {
        guard let row = try await SwiftNativeToolRegistry(root: root).getTool(id: id),
              try abilities.read(id: id, slot: .next) != nil,
              let candidate = try candidate(for: row) else { throw ToolExecutionError.proposalNotFound(id) }
        let result = try await validate(candidate, capture: capture, input: input)
        if !result.valid { return result }
        try await ToolRegistryActions.mutate(id: id, dataRoot: root) { current in
            guard var fields = current, fields["candidateDigest"] == .string(candidate.digest) else {
                throw ToolExecutionError.invalidProposal("A newer candidate replaced this validation")
            }
            fields["candidateValidation"] = .string(result.valid ? "valid" : "invalid")
            fields["validationErrors"] = .array(result.errors.map(JSONValue.string))
            if fields["status"] != .string("active") { fields["validationStatus"] = fields["candidateValidation"] }
            return fields
        }
        return result
    }

    @discardableResult public func promote(id: String, allowRisky: Bool, ownerAuthorized: Bool = false) async throws -> ProposalRecord {
        guard let tool = try await SwiftNativeToolRegistry(root: root).getTool(id: id),
              let candidate = try candidate(for: tool) else { throw ToolExecutionError.proposalNotFound(id) }
        if let refusal = ToolApprovalEligibility.refusal(for: tool, ownerAuthorized: ownerAuthorized) { throw ToolExecutionError.invalidProposal(refusal) }
        guard allowRisky || (!candidate.program.permissions.isEmpty
            && Set(candidate.program.permissions).isSubset(of: ["app_data_read"])) else {
            throw ToolExecutionError.invalidProposal("The declared permissions require the existing approval decision")
        }
        try checkDependencies(candidate)
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        let proof = try store.proof(candidate, key: key)
        let admission = try await signer.sign(["id": .string(id), "candidate": .string(candidate.digest), "proof": proof])
        let path = try abilities.path(id: id).path, stamp = Self.isoTimestamp(Date())
        try await store.keep(candidate, key: key, ownerAuthorized: ownerAuthorized) { value in
            guard case .array(var rows) = value,
                  let index = rows.firstIndex(where: { Self.fields($0)["id"] == .string(id) }),
                  case .object(var row) = rows[index] else {
                throw ToolExecutionError.invalidProposal("The candidate, selected version or off-switch changed; propose and validate again")
            }
            let matches = row["candidateDigest"] != nil
                ? row["candidateDigest"] == .string(candidate.digest) && row["candidatePrior"] == candidate.prior
                    && row["candidateSelection"] == OwnedProgramStore.selection(rows[index]) && row["candidateValidation"] == .string("valid")
                : row["codeFingerprint"] == .string(candidate.digest)
                    && OwnedProgramStore.selection(rows[index]) == OwnedProgramStore.selection(tool.toJSON()) && row["validationStatus"] == .string("valid")
            guard matches else { throw ToolExecutionError.invalidProposal("The candidate, selected version or off-switch changed; propose and validate again") }
            row.merge(Self.fields(candidate.manifest)) { $1 }
            row["status"] = .string("active"); row["phase"] = .string("active")
            row["codeFingerprint"] = .string(candidate.digest); row["activePath"] = .string(path)
            row["validationStatus"] = .string("valid"); row["admission"] = .object(admission)
            for field in ["manifestSignature", "signedAt", "signatureVersion"] { row[field] = admission[field] }
            row["promotedAt"] = .string(stamp); row["updatedAt"] = .string(stamp); row["failuresInARow"] = .int(0)
            rows[index] = .object(row); value = .array(rows)
        }
        guard let updated = try await SwiftNativeToolRegistry(root: root).getTool(id: id),
              let record = ProposalRecord(json: updated.toJSON()) else { throw ToolExecutionError.underlying("Published tool did not read back") }
        return record
    }

    public func runTool(id: String, input: JSONValue, requiredFingerprint: String) async throws -> JSONValue {
        guard let row = try await SwiftNativeToolRegistry(root: root).getTool(id: id) else { throw ToolExecutionError.proposalNotFound(id) }
        guard row.status == "active" else { throw SenseFailure(code: "not_active", message: "\(id) is \(row.status); enable its exact JS version before running it.") }
        let pinned = requiredFingerprint
        guard !pinned.isEmpty else {
            throw ToolExecutionError.invalidProposal("Execution requires an admitted exact fingerprint")
        }
        guard row.language == "javascript" else { throw ToolExecutionError.invalidProposal("The tool has no JavaScript executable") }
        guard row.codeFingerprint == pinned else { throw SenseFailure(code: "state_changed", message: "The tool version changed after admission.") }
        let candidate: OwnedProgramStore.Candidate
        do { candidate = try store.load(id: id, digest: pinned) }
        catch { throw SenseFailure(code: "integrity", message: "The admitted candidate is unreadable: \(error.localizedDescription)") }
        try await checkAdmission(candidate, row: row)
        try checkDependencies(candidate)
        guard let host = OwnedProgramInvocation.host else { throw ToolExecutionError.invalidProposal("Authored execution requires the originating app door") }
        var fields = Self.fields(input)
        let primitive = fields.removeValue(forKey: "__authored_primitive")
        let input = JSONValue.object(fields)
        try ToolPrimitiveBroker.checkInput(input, schema: candidate.program.schema)
        if let refused = await host.admitTool(id, input: Self.fields(input)) { return refused }
        let broker = ToolPrimitiveBroker(root: root, permissions: Set(candidate.program.permissions))
        let profile = ToolHost(base: host, candidate: candidate, broker: broker, input: Self.fields(input),
            admission: { try await self.checkSelected(candidate, pinned: pinned) })
        if let primitive {
            // The inbox approves one blocked primitive, never a repeat of earlier effects.
            guard AuthoredToolEffects.approvedCall?.tool == id, case .object(let call) = primitive,
                  call["fingerprint"] == .string(pinned), call["operation"] == .string("apps.call"),
                  let arguments = call["arguments"] else {
                await broker.close()
                throw SenseFailure(code: "state_changed", message: "The exact primitive and tool version require a verified approval.")
            }
            let result = try await profile.primitive("apps.call", arguments: arguments, preview: false)
            await broker.close()
            return result
        }
        let helper = SenseHostLocator.helperURL, dataRoot = root
        let runner = OwnedProgramRunner(helperURL: helper, dataRoot: dataRoot) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helper, scratch: scratch,
                dataRoot: dataRoot, personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        }
        var result = Self.fields(await runner.run(candidate.program, input: input, preview: false, replay: nil, host: profile))
        await broker.close()
        result["toolId"] = .string(id); result["version"] = .string(candidate.digest)
        result["codeFingerprint"] = .string(candidate.digest); result["result"] = result["returned"] ?? .null
        if result["status"] == .string("stopped") {
            let stopped = Self.fields(result["stopped"] ?? .null)
            result["status"] = .string(stopped["not_run_status"] == .string("approval_filed") ? "waiting_approval"
                : stopped["reason"] == .string("cancelled") ? "cancelled" : "refused")
            result["reason"] = stopped["reason"]; result["detail"] = stopped["detail"]
            for key in ["approvalId", "not_run_status", "remedy"] { result[key] = stopped[key] }
        }
        if result["status"] == .string("timed_out") { result["detail"] = .string("The tool exceeded its \(Int(candidate.program.seconds))-second deadline.") }
        try await ToolRegistryActions.recordUse(id: id, version: pinned, receipt: .object(result), codeFault: Self.codeFault(result),
            cleanCode: result["status"] == .string("ok") ? candidate.program.digest : nil, dataRoot: root)
        return .object(result)
    }

    func checkSelected(_ candidate: OwnedProgramStore.Candidate, pinned: String) async throws {
        guard let row = try await SwiftNativeToolRegistry(root: root).getTool(id: candidate.program.id),
              row.status == "active", row.codeFingerprint == pinned else {
            throw SenseFailure(code: "state_changed", message: "The selected tool was stopped or replaced. Nothing more ran.")
        }
        try await checkAdmission(candidate, row: row)
        try checkDependencies(candidate)
    }

    public func checkAdmission(_ candidate: OwnedProgramStore.Candidate, row: ToolRecord) async throws {
        let fields = Self.fields(row.toJSON())
        guard Self.fields(candidate.manifest).allSatisfy({ fields[$0.key] == $0.value }),
              row.codeFingerprint == candidate.digest, row.permissions == candidate.program.permissions,
              fields["inputSchema"] == candidate.program.schema,
              fields["actions"] == .array(candidate.program.dependencies.map(JSONValue.string)),
              row.activePath == (try store.directory(id: row.id, digest: candidate.digest).path),
              case .object(let admission)? = fields["admission"] else {
            throw SenseFailure(code: "integrity", message: "The selected tool's admission or metadata changed.")
        }
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let errors = try await signer.verify(admission)
        guard errors.isEmpty, admission["candidate"] == .string(candidate.digest) else {
            throw SenseFailure(code: "integrity", message: errors.joined(separator: "; "))
        }
        let key = try await signer.loadOrCreateSigningKey()
        guard admission["proof"] == (try store.proof(candidate, key: key)) else {
            throw SenseFailure(code: "integrity", message: "The admitted validation proof changed.")
        }
    }

    func candidate(for row: ToolRecord) throws -> OwnedProgramStore.Candidate? {
        let fields = Self.fields(row.toJSON())
        let selectedProposal = row.status == "proposed" || row.status == "disabled" && fields["admission"] == nil
        guard let digest = Self.string(fields, "candidateDigest") ?? (selectedProposal ? row.codeFingerprint : nil) else { return nil }
        return try store.load(id: row.id, digest: digest)
    }

    func dependencyShapes(_ actions: [String]) throws -> JSONValue {
        var shapes: [String: JSONValue] = [:]
        for action in actions {
            guard let shape = OwnedProgramInvocation.host?.dependencyShape(action) else {
                throw ToolExecutionError.invalidProposal("Dependency \(action) is unavailable in this app door")
            }
            shapes[action] = shape
        }
        return .object(shapes)
    }

    func checkDependencies(_ candidate: OwnedProgramStore.Candidate) throws {
        guard let host = OwnedProgramInvocation.host, candidate.program.dependencies.allSatisfy({
            host.dependencyMatches($0, Self.fields(candidate.dependencyShapes)[$0])
        }) else {
            throw SenseFailure(code: "stale_dependency", message: "An app-action dependency changed. Propose and validate against its current shape.")
        }
    }

    public func rollback(id: String, version: String?) async throws -> ProposalValidationResult {
        guard let current = try await SwiftNativeToolRegistry(root: root).getTool(id: id) else { throw ToolExecutionError.proposalNotFound(id) }
        let target = try rollbackTarget(current, version: version)
        guard var previous = try abilities.read(id: id, slot: .previous),
              case .object(var selected)? = previous.metadata["record"] else { throw ToolExecutionError.invalidProposal("The previous version's record is unreadable") }
        let admitted = try await rollbackAdmission(target, file: previous)
        try AbilityStore.withLock {
            guard try abilities.read(id: id, slot: .previous) == previous,
                  case .array(let beforeRows) = try abilities.registry(kind: .tool),
                  let before = beforeRows.first(where: { Self.fields($0)["id"] == .string(id) }).map(Self.fields),
                  before["codeFingerprint"] == current.codeFingerprint.map(JSONValue.string) else {
                throw ToolExecutionError.invalidProposal("The tool changed during rollback; read it again.")
            }
            try abilities.swap(id: id)
            for key in ["status", "phase", "disabledBy"] { selected[key] = before[key] }
            if !admitted {
                for key in ["admission", "manifestSignature", "signedAt", "signatureVersion"] { selected.removeValue(forKey: key) }
                if selected["status"] != .string("disabled") { selected["status"] = .string("proposed"); selected["phase"] = .string("proposed") }
                selected["validationStatus"] = .string("valid")
            }
            selected["updatedAt"] = .string(Self.isoTimestamp(Date()))
            previous.metadata["record"] = .object(selected)
            try abilities.write(previous)
        }
        return ProposalValidationResult(valid: true, autoPromotable: false, errors: [], candidateDigest: target.digest)
    }

    public func rollbackPreview(id: String, version: String?) async throws -> (version: String, status: String, ownerOff: Bool) {
        guard let tool = try await SwiftNativeToolRegistry(root: root).getTool(id: id) else { throw ToolExecutionError.proposalNotFound(id) }
        let target = try rollbackTarget(tool, version: version)
        guard let previous = try abilities.read(id: id, slot: .previous) else { throw ToolExecutionError.invalidProposal("No previous version") }
        let admitted = try await rollbackAdmission(target, file: previous)
        return (target.digest, admitted || tool.status == "disabled" ? tool.status : "proposed", CapabilityLifecycle.requiresOwnerToEnable(Self.fields(tool.toJSON())))
    }

    private func rollbackAdmission(_ candidate: OwnedProgramStore.Candidate, file: AbilityStore.File) async throws -> Bool {
        let key = try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()
        _ = try store.proof(candidate, key: key)
        guard case .object(var fields)? = file.metadata["record"], fields["admission"] != nil else { return false }
        fields["activePath"] = .string(try store.directory(id: file.id, digest: candidate.digest).path)
        guard let record = ToolRecord(json: .object(fields)) else { throw ToolExecutionError.invalidProposal("The previous version's record is unreadable") }
        do { try await checkAdmission(candidate, row: record); return true }
        catch let failure as SenseFailure where failure.code == "integrity" { return false }
    }

    private func rollbackTarget(_ row: ToolRecord, version: String?) throws -> OwnedProgramStore.Candidate {
        guard let digest = ToolRegistryActions.rollbackVersion(row.toJSON()) else {
            throw ToolExecutionError.invalidProposal("No previous version")
        }
        guard version == nil || version == digest else { throw ToolExecutionError.invalidProposal("Only the previous version can be rolled back") }
        return try store.load(id: row.id, digest: digest)
    }

    /// Only the current, previous and proposed files can describe conversions.
    public func convertedVersions(for row: ToolRecord) throws -> JSONValue {
        let id = row.id
        return .array(try store.conversions(id: id).map { candidate in
            var fields: [String: JSONValue] = ["version": .string(candidate.digest),
                "converts": Self.fields(candidate.manifest)["converts"] ?? .array([])]
            do {
                _ = try rollbackTarget(row, version: candidate.digest)
                fields["rollback_call"] = .object(["action": .string("tool.rollback"),
                    "args": .object(["tool_id": .string(id), "version": .string(candidate.digest)])])
            } catch {
                fields["rollback_unavailable"] = .string(error.localizedDescription)
            }
            return .object(fields)
        })
    }

    public func versions(id: String) async -> JSONValue {
        do {
            guard let row = try await SwiftNativeToolRegistry(root: root).getTool(id: id) else { return .null }
            return Self.fields(ToolRegistryActions.read(row))["versions"] ?? .null
        } catch { return .object(["status": .string("unavailable"), "detail": .string(error.localizedDescription)]) }
    }

    static func codeFault(_ fields: [String: JSONValue]) -> Bool {
        if fields["status"] == .string("timed_out") {
            return array(fields["calls"] ?? .array([])).allSatisfy {
                [JSONValue.string("ok"), .string("preview")].contains(Self.fields($0)["status"] ?? .null)
            }
        }
        guard case .object(let error)? = fields["error"] else { return false }
        if error["origin"] == .string("javascript") {
            if case .int(let n)? = error["n"], n > 0 {
                let calls = array(fields["calls"] ?? .array([]))
                if calls.indices.contains(Int(n) - 1), Self.fields(calls[Int(n) - 1])["status"] != .string("ok") { return false }
            }
            return true
        }
        let reason = string(error, "reason") ?? "javascript"
        return ["javascript", "script_syntax", "script_name", "bad_output", "output_limit", "unreadable_return"].contains(reason)
    }

    static func fields(_ value: JSONValue) -> [String: JSONValue] { if case .object(let fields) = value { fields } else { [:] } }
    static func array(_ value: JSONValue) -> [JSONValue] { if case .array(let values) = value { values } else { [] } }
    static func strings(_ value: JSONValue?) -> [String] { array(value ?? .null).compactMap { if case .string(let text) = $0 { text } else { nil } } }
    public nonisolated static func declaredStrings(_ value: JSONValue?, name: String) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let values) = value, values.allSatisfy({ if case .string = $0 { true } else { false } }) else {
            throw ToolExecutionError.invalidProposal("\(name) must be an array of strings")
        }
        return strings(value)
    }
    static func string(_ fields: [String: JSONValue], _ key: String) -> String? { if case .string(let text)? = fields[key] { text } else { nil } }
    public nonisolated static func isoTimestamp(_ date: Date) -> String { SwiftNativeToolRegistry.isoTimestamp(date) }
}
