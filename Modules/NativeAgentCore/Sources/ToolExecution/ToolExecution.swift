import AuthoredCapabilities
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
    /// The candidate was staged by this call (committed: the write returned; else
    /// the write was attempted and may be on disk) and the call did not complete.
    case stagedButFailed(digest: String, committed: Bool, why: String)

    public var errorDescription: String? {
        switch self {
        case .invalidProposal(let msg): return "invalid proposal: \(msg)"
        case .stagedButFailed(_, let committed, let why): return "\(committed ? "staged" : "staging attempted"), the call did not complete: \(why)"
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
    public var evidence: JSONValue?
    /// The id it was filed under, when the id rule respelled the one given.
    public var respelled: String?

    public init(valid: Bool, autoPromotable: Bool, errors: [String], candidateDigest: String? = nil, capture: String? = nil, evidence: JSONValue? = nil) {
        self.valid = valid
        self.autoPromotable = autoPromotable
        self.errors = errors
        self.candidateDigest = candidateDigest
        self.capture = capture
        self.evidence = evidence
    }
}


public actor SwiftNativeToolExecution {
    let root: URL
    var store: OwnedProgramStore { OwnedProgramStore(root: root.appendingPathComponent("tools")) }
    var abilities: AbilityStore { AbilityStore(dataRoot: root) }

    public init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.root = root
    }

    package func bundledSeed(_ seed: AbilityStore.File) async throws -> AbilityStore.File {
        guard let record = seed.record, case .string(let description)? = record["description"], !description.isEmpty else {
            throw ToolExecutionError.invalidProposal("Seed \(seed.id) needs a description in its record. Fix the bundled seed and relaunch.")
        }
        let actions = try Self.declaredStrings(record["actions"], name: "actions")
        let permissions = try Self.declaredStrings(Self.fields(seed.part["reach"] ?? .null)["capabilities"], name: "reach.capabilities")
        let schema = record["inputSchema"] ?? .object(["type": .string("object")])
        let manifest = record.merging([
            "id": .string(seed.id), "name": record["name"] ?? .string(seed.id), "origin": .string("self"),
            "language": .string("javascript"), "entrypoint": .string("tool.js"), "inputSchema": schema,
            "actions": .array(actions.map(JSONValue.string)),
        ]) { _, value in value }.merging(seed.part) { _, value in value }
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .tool, id: seed.id, version: "seed", source: seed.body, entry: .run,
                schema: schema, dependencies: actions, permissions: permissions, resident: seed.part["resident"] == .bool(true)),
            manifest: .object(manifest), fixtures: .array([]), dependencyShapes: dependencyShapes(actions), prior: .null)
        try checkDependencies(candidate)
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        let version: Int64 = if case .int(let value)? = seed.metadata["version"] { value } else { 1 }
        var file = try store.bundledSeed(candidate, version: version, key: key)
        let admission = try await signer.sign(["id": .string(seed.id), "candidate": .string(candidate.digest), "proof": file.metadata["proof"]!])
        let stamp = Self.isoTimestamp(Date())
        var row = manifest.merging([
            "status": .string("active"), "phase": .string("active"), "createdAt": .string(stamp), "updatedAt": .string(stamp),
            "codeFingerprint": .string(candidate.digest), "activePath": .string(try abilities.path(id: seed.id).path),
            "admission": .object(admission),
        ]) { _, value in value }
        for field in ["manifestSignature", "signedAt", "signatureVersion"] { row[field] = admission[field] }
        file.metadata["record"] = .object(row)
        return file
    }

    /// The id rule's own spelling of a tool id: days-left-year is days_left_year.
    public static func toolID(_ given: String) -> String {
        given.lowercased().replacingOccurrences(of: #"[\s-]+"#, with: "_", options: .regularExpression)
    }

    public func propose(id given: String, description: String, code: String, tests: [JSONValue],
                        permissions: [String], inputSchema: JSONValue?, actions: [String] = [],
                        origin: JSONValue = .string("self"), capture: Bool = false, input: JSONValue? = nil,
                        converts: JSONValue? = nil, header: [String: JSONValue] = [:]) async throws -> ProposalValidationResult {
        let id = Self.toolID(given)
        let part = try AbilityStore.partHeader(header.merging(["permissions": .array(permissions.map(JSONValue.string))]) { first, _ in first })
        let declared = try Self.declaredStrings(Self.fields(part["reach"] ?? .null)["capabilities"], name: "reach.capabilities")
        guard permissions.isEmpty || permissions == declared else { throw ToolExecutionError.invalidProposal("Use reach.capabilities or matching legacy permissions.") }
        let permissions = declared
        let pages = Set(permissions).intersection(["calendar", "reminders", "contacts"])
        let fileReads = !Set(permissions).isDisjoint(with: ["app_data_read", "app_data_write", "computer_files", "arbitrary_file_write"])
        let fileWrites = !Set(permissions).isDisjoint(with: ["app_data_write", "arbitrary_file_write"])
        let reachActions = OwnedProgramInvocation.host.map { host in
            host.actionIDs.filter { host.action($0).map {
                pages.contains($0.page) || $0.page == "files" && (fileWrites || fileReads && $0.read)
            } == true }
        } ?? []
        let actions = actions + reachActions.filter { !actions.contains($0) }
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
            "actions": .array(actions.map(JSONValue.string)), "origin": origin,
            "converts": try OwnedProgramStore.conversionSources(converts),
        ].merging(part) { _, value in value })
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .tool, id: id, version: "candidate", source: code, entry: .run,
                                  schema: schema, dependencies: actions, permissions: permissions, resident: part["resident"] == .bool(true)),
            manifest: manifest, fixtures: .array(tests), dependencyShapes: dependencyShapes(actions),
            prior: OwnedProgramStore.selection(existing?.toJSON()))
        let path = try abilities.path(id: id, slot: .next).path
        let stamp = Self.isoTimestamp(Date())
        let candidateStore = store
        // From the moment the candidate is written, a failure says so by itself.
        let staged = StagedFlag()
        do {
        try await ToolRegistryActions.mutate(id: id, dataRoot: root) { current in
            // A respelled id files a new tool; it never replaces one it was not given.
            guard id == given || current == nil else {
                throw ToolExecutionError.invalidProposal("\(given) is \(id) by the id rule, and \(id) is already a tool. "
                    + "To change it, tool.propose with tool_id \(id); otherwise pick another tool_id")
            }
            guard OwnedProgramStore.selection(current.map(JSONValue.object)) == candidate.prior else {
                throw ToolExecutionError.invalidProposal("The selected tool changed; propose against its current version")
            }
            try candidateStore.stage(candidate, writing: staged.attempt)
            staged.commit()
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
        // This call's own candidate is validated, never whatever the registry
        // holds by then (another call may have replaced it); publishing checks
        // the digest is still the one selected.
        var result = try await publish(try await validate(candidate, capture: capture, input: input), id: id, candidate: candidate)
        if id != given { result.respelled = id }
        return result
        } catch {
            if case .stagedButFailed = error as? ToolExecutionError { throw error }
            switch staged.state {
            case .none: throw error
            case .attempted, .committed:
                throw ToolExecutionError.stagedButFailed(digest: candidate.digest, committed: staged.state == .committed, why: error.localizedDescription)
            }
        }
    }

    /// Where the candidate write stands, read by the failure path: not begun,
    /// attempted (the writer may have landed it before failing), or committed.
    private final class StagedFlag: @unchecked Sendable {
        enum State { case none, attempted, committed }
        private let lock = NSLock()
        private var value = State.none
        func attempt() { lock.withLock { value = .attempted } }
        func commit() { lock.withLock { value = .committed } }
        var state: State { lock.withLock { value } }
    }

    public func validateProposal(id: String, capture: Bool = false, input: JSONValue? = nil) async throws -> ProposalValidationResult {
        guard let row = try await SwiftNativeToolRegistry(root: root).getTool(id: id),
              try abilities.read(id: id, slot: .next) != nil,
              let candidate = try candidate(for: row) else { throw ToolExecutionError.proposalNotFound(id) }
        return try await publish(try await validate(candidate, capture: capture, input: input), id: id, candidate: candidate)
    }

    /// A validation lands on the registry only while its exact candidate is still the selected one.
    private func publish(_ result: ProposalValidationResult, id: String, candidate: OwnedProgramStore.Candidate) async throws -> ProposalValidationResult {
        if !result.valid { return result }
        try await ToolRegistryActions.mutate(id: id, dataRoot: root) { current in
            guard var fields = current, fields["candidateDigest"] == .string(candidate.digest) else {
                throw ToolExecutionError.invalidProposal("A newer candidate replaced this validation")
            }
            fields["candidateValidation"] = .string(result.valid ? "rehearsed" : "invalid")
            fields["validationErrors"] = .array(result.errors.map(JSONValue.string))
            if fields["status"] != .string("active") { fields["validationStatus"] = fields["candidateValidation"] }
            return fields
        }
        return result
    }

    /// `digest`, when given, is the one candidate this promotion may publish.
    @discardableResult public func promote(id: String, allowRisky: Bool, ownerAuthorized: Bool = false, digest: String? = nil) async throws -> ProposalRecord {
        guard let tool = try await SwiftNativeToolRegistry(root: root).getTool(id: id),
              let candidate = try candidate(for: tool) else { throw ToolExecutionError.proposalNotFound(id) }
        guard digest == nil || digest == candidate.digest else {
            throw ToolExecutionError.invalidProposal("\(id)'s candidate is no longer \(digest ?? ""); read the Tools page and approve the one it lists")
        }
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
                    && row["candidateSelection"] == OwnedProgramStore.selection(rows[index]) && row["candidateValidation"] == .string("rehearsed")
                : row["codeFingerprint"] == .string(candidate.digest)
                    && OwnedProgramStore.selection(rows[index]) == OwnedProgramStore.selection(tool.toJSON()) && row["validationStatus"] == .string("rehearsed")
            guard matches else { throw ToolExecutionError.invalidProposal("The candidate, selected version or off-switch changed; propose and validate again") }
            row.merge(Self.fields(candidate.manifest)) { $1 }
            row["status"] = .string("active"); row["phase"] = .string("active")
            row["codeFingerprint"] = .string(candidate.digest); row["activePath"] = .string(path)
            row["validationStatus"] = .string("rehearsed"); row["admission"] = .object(admission)
            for field in ["manifestSignature", "signedAt", "signatureVersion"] { row[field] = admission[field] }
            row["promotedAt"] = .string(stamp); row["updatedAt"] = .string(stamp)
            rows[index] = .object(row); value = .array(rows)
        }
        guard let updated = try await SwiftNativeToolRegistry(root: root).getTool(id: id),
              let record = ProposalRecord(json: updated.toJSON()) else { throw ToolExecutionError.underlying("Published tool did not read back") }
        return record
    }

    public func runTool(id: String, input: JSONValue, requiredFingerprint: String) async throws -> JSONValue {
        do { return try await runSelectedTool(id: id, input: input, requiredFingerprint: requiredFingerprint) }
        catch {
            try abilities.recordRun(id: id, version: requiredFingerprint, receipt: .object([
                "status": .string("refused"), "reason": .string("admission"), "detail": .string(error.localizedDescription)]))
            throw error
        }
    }

    private func runSelectedTool(id: String, input: JSONValue, requiredFingerprint: String) async throws -> JSONValue {
        guard let host = OwnedProgramInvocation.host else { throw ToolExecutionError.invalidProposal("Authored execution requires the originating app door") }
        let catalogRevision = try abilities.revision()
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
        let revision = try catalogRevision + host.dependencyRevision(candidate.program.dependencies)
        try await checkAdmission(candidate, row: row)
        try checkDependencies(candidate)
        let binding = OwnedProgramRunner.Binding(revision: revision)
        if let problem = input.schemaProblem(schema: candidate.program.schema) {
            throw SenseFailure(code: "bad_input", message: "Tool input \(problem.path) must be \(problem.expected).")
        }
        if let refused = await host.admitTool(id, input: Self.fields(input)) {
            try abilities.recordRun(id: id, version: pinned, receipt: refused)
            return refused
        }
        let broker = ToolPrimitiveBroker(permissions: Set(candidate.program.permissions), host: host, abilityID: id)
        let profile = ToolHost(base: host, candidate: candidate, broker: broker, dataRoot: root,
            admission: {
                try await binding.check(self.abilities.revision() + host.dependencyRevision(candidate.program.dependencies)) {
                    try await self.checkSelected(candidate, pinned: pinned)
                }
            })
        let helper = SenseHostLocator.helperURL, dataRoot = root
        let runner = OwnedProgramRunner(helperURL: helper, dataRoot: dataRoot) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helper, scratch: scratch,
                dataRoot: dataRoot, personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        }
        var result = Self.fields(await runner.run(candidate.program, input: input, preview: false, replay: nil, host: profile))
        // A watch leaves one receipt for all its frames, however it ended.
        let watched = await broker.close()
        if !watched.isEmpty { result["watch"] = watched.count == 1 ? watched[0] : .array(watched) }
        result["toolId"] = .string(id); result["version"] = .string(candidate.digest)
        result["codeFingerprint"] = .string(candidate.digest)
        if result["status"] == .string("stopped") {
            let stopped = Self.fields(result["stopped"] ?? .null)
            result["status"] = .string(stopped["not_run_status"] == .string("approval_filed") ? "waiting_approval"
                : stopped["reason"] == .string("cancelled") ? "cancelled" : "refused")
            result["reason"] = stopped["reason"]; result["detail"] = stopped["detail"]
            for key in ["approvalId", "not_run_status", "remedy"] { result[key] = stopped[key] }
        }
        if result["status"] == .string("timed_out") { result["detail"] = .string("The tool exceeded its \(Int(candidate.program.seconds))-second deadline.") }
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
        guard Self.fields(candidate.manifest).allSatisfy({ fields[$0.key] == $0.value
            || $0.key == "learned" && Self.fields(fields[$0.key] ?? .null)["declared"] == $0.value }),
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
        if let action = Self.string(Self.fields(Self.fields(candidate.manifest)["face"] ?? .null), "action"),
           let owner = OwnedProgramInvocation.host?.action(action), owner.partID != candidate.id {
            throw ToolExecutionError.invalidProposal("face.action \(action) is already provided by another tool.")
        }
        // No door in this turn is not a changed dependency: say which it is.
        guard let host = OwnedProgramInvocation.host else {
            throw SenseFailure(code: "door_unavailable", message: "This turn has no app door, so the tool's app-action dependencies could not be checked; nothing ran. Run it from a chat turn.")
        }
        for action in candidate.program.dependencies where !host.dependencyMatches(action, Self.fields(candidate.dependencyShapes)[action]) {
            let before = Self.fields(candidate.dependencyShapes)[action] ?? .null
            let after = host.dependencyShape(action) ?? .null
            let fields = JSONValue.differences(before, after).map { $0.isEmpty ? "contract" : $0 }.joined(separator: ", ")
            let file = AbilityStore.File(id: candidate.id, kind: .tool, metadata: ["record": candidate.manifest],
                body: candidate.program.source, pathExtension: "js")
            throw ToolFailureError("Dependency \(action) changed at \(fields). Saved: \(try before.serialize(pretty: false)); current: \(try after.serialize(pretty: false)). Revise \(candidate.id) version \(candidate.digest) with tool.propose, validate and approve against this contract, then repeat the failed operation.",
                effects: .none, owner: "part \(candidate.id) version \(candidate.digest) > candidate.dependencyShapes.\(action) > \(fields)",
                nextCall: try abilities.repairCall(file))
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
            }
            selected["updatedAt"] = .string(Self.isoTimestamp(Date()))
            previous.metadata["record"] = .object(selected)
            try abilities.write(previous)
        }
        return ProposalValidationResult(valid: true, autoPromotable: false, errors: [], candidateDigest: target.digest,
            evidence: AbilityStore.validationEvidence(previous.metadata["proof"], fixtures: Self.fields(previous.metadata["candidate"] ?? .null)["fixtures"]))
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
        guard var fields = file.record, fields["admission"] != nil else { return false }
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
