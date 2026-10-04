import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry
import Desk
import CryptoKit

// MARK: - Errors

/// Errors raised by the tool-execution proposal lifecycle.
public enum ToolExecutionError: Error, LocalizedError {
    case invalidProposal(String)
    case proposalNotFound(String)
    case validationFailed([String])
    case invalidResponse(status: Int)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProposal(let msg): return "invalid proposal: \(msg)"
        case .proposalNotFound(let id): return "proposal not found: \(id)"
        case .validationFailed(let errs): return "validation failed: \(errs.joined(separator: "; "))"
        case .invalidResponse(let status): return "invalid response: HTTP \(status)"
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

    public init(
        id: String,
        name: String,
        description: String? = nil,
        manifest: JSONValue,
        riskClass: String? = nil,
        permissions: [String]? = nil,
        status: String,
        createdAt: String,
        validatedAt: String? = nil,
        validationErrors: [String]? = nil,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.manifest = manifest
        self.riskClass = riskClass
        self.permissions = permissions
        self.status = status
        self.createdAt = createdAt
        self.validatedAt = validatedAt
        self.validationErrors = validationErrors
        self.extras = extras
    }
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

    public init(valid: Bool, autoPromotable: Bool, errors: [String]) {
        self.valid = valid
        self.autoPromotable = autoPromotable
        self.errors = errors
    }
}

// MARK: - Protocol

public protocol ToolExecutionProtocol: Sendable {
    func createProposal(_ body: JSONValue) async throws -> ProposalRecord
    func listProposals() async throws -> [ProposalRecord]
    func getProposal(id: String) async throws -> ProposalRecord?
    func validateProposal(id: String, promote: Bool) async throws -> ProposalValidationResult
    // RUN sandbox + PROMOTE-with-signing land in sibling files
    // (ToolExecution+Run.swift / ToolExecution+Promote.swift). The stubs
    // here exist so callers can write against the full protocol surface
    // today; calling them throws an explicit carve-out message.
    func runTool(id: String, input: JSONValue) async throws -> JSONValue
    @discardableResult
    func promote(id: String, allowRisky: Bool) async throws -> ProposalRecord
}

// MARK: - SwiftNative impl

/// File-backed proposal lifecycle mirroring the retired daemon
/// create_tool_proposal (L33285-33356). Actor-isolated for R-M-W safety on
/// `<root>/tools/proposals/<id>/manifest.json`.
///
/// Split across sibling Swift files:
///   - manifestSignature / signedAt / signatureVersion       (HMAC signing)
///   - codeFingerprint                                       (run sandbox path)
///   - activePath / quarantinePath                           (promote/quarantine)
///   - autoPromotable / autoRun / autoPromote                (policy fields)
/// All carve-outs round-trip via `extras` untouched on read; the SwiftNative
/// validate pass here is intentionally small (manifest presence + permission
/// shape) because full validation lives in `ToolExecution+Promote.swift` and
/// `ToolExecution+RunSandbox.swift`.
public actor SwiftNativeToolExecution: ToolExecutionProtocol {
    private let root: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date

    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.clock = clock
    }

    public var proposalsDir: URL {
        root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("proposals", isDirectory: true)
    }

    public func createProposal(_ body: JSONValue) async throws -> ProposalRecord {
        guard case .object(let obj) = body else {
            throw ToolExecutionError.invalidProposal("body must be a JSON object")
        }
        let id: String = {
            if case .string(let s) = obj["id"] ?? .null, !s.isEmpty { return s }
            return ""
        }()
        let name: String = {
            if case .string(let s) = obj["name"] ?? .null, !s.isEmpty { return s }
            return ""
        }()
        if id.isEmpty { throw ToolExecutionError.invalidProposal("id is required") }
        if name.isEmpty { throw ToolExecutionError.invalidProposal("name is required") }
        // The id becomes an on-disk directory name — reject traversal /
        // separator ids before any path construction (audit 2026-06-09).
        guard Self.isSafeToolId(id) else {
            throw ToolExecutionError.invalidProposal("id must be a single safe path component")
        }
        let dir = proposalsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestPath = dir.appendingPathComponent("manifest.json")
        let stamp = Self.isoTimestamp(clock())
        var manifestObj = obj
        manifestObj["id"] = .string(id)
        manifestObj["name"] = .string(name)
        if manifestObj["status"] == nil { manifestObj["status"] = .string("proposed") }
        if manifestObj["createdAt"] == nil { manifestObj["createdAt"] = .string(stamp) }
        // Persist the manifest atomically via PersistenceCore.
        try await persistence.writeJSON(.object(manifestObj), to: manifestPath)
        // Build the record: status=proposed, createdAt=now. The carve-outs
        // (validationStatus/autoPromotable/signing) are absent here — they
        // get filled by validate / promote in sibling subsystems.
        var rec = ProposalRecord(
            id: id,
            name: name,
            manifest: .object(manifestObj),
            status: "proposed",
            createdAt: stamp
        )
        if case .string(let d) = obj["description"] ?? .null { rec.description = d }
        if case .string(let r) = obj["riskClass"] ?? .null { rec.riskClass = r }
        if case .array(let arr) = obj["permissions"] ?? .null {
            rec.permissions = arr.compactMap { v in
                if case .string(let s) = v { return s } else { return nil }
            }
        }
        return rec
    }

    public func listProposals() async throws -> [ProposalRecord] {
        let dir = proposalsDir
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        var out: [ProposalRecord] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let manifestPath = entry.appendingPathComponent("manifest.json")
            let raw = try await persistence.readJSON(manifestPath, ifMissing: .null)
            if case .null = raw { continue }
            guard case .object(var obj) = raw else { continue }
            // Synthesize required fields if the on-disk manifest lacks them
            // (the daemon's `no_tool.json` skip-marker files contain no id).
            if obj["status"] == nil { obj["status"] = .string("proposed") }
            if obj["createdAt"] == nil { obj["createdAt"] = .string("") }
            // Use directory name as id fallback so daemon-written manifests
            // that put id at top level still parse.
            if case .string(let s) = obj["id"] ?? .null, s.isEmpty || s == "" {
                obj["id"] = .string(entry.lastPathComponent)
            } else if obj["id"] == nil {
                obj["id"] = .string(entry.lastPathComponent)
            }
            if obj["name"] == nil, case .string(let s) = obj["id"] ?? .null {
                obj["name"] = .string(s)
            }
            if let rec = ProposalRecord(json: .object(obj)) {
                out.append(rec)
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    public func getProposal(id: String) async throws -> ProposalRecord? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let all = try await listProposals()
        return all.first { $0.id == trimmed }
    }

    public func validateProposal(id: String, promote: Bool) async throws -> ProposalValidationResult {
        // U5 W-B: wired to the REAL SwiftToolValidator — the same checks the
        // promote path applies (tests.json presence, dangerous-import scan
        // of the entrypoint, permission allow-list, safe-auto subset). The
        // pre-U5 stub here returned valid+autoPromotable for ANY readable
        // manifest — a silent pass-through. The `promote` flag does not
        // relax or tighten anything: validation ground truth is identical
        // either way, and the promote engine re-runs it before activation.
        guard let rec = try await getProposal(id: id) else {
            throw ToolExecutionError.proposalNotFound(id)
        }
        var errors: [String] = []
        if rec.name.isEmpty { errors.append("name is required") }
        guard case .object(let manifestObj) = rec.manifest else {
            errors.append("manifest missing")
            return ProposalValidationResult(valid: false, autoPromotable: false, errors: errors)
        }
        let proposalDir = proposalsDir.appendingPathComponent(rec.id, isDirectory: true)
        let deep = await SwiftToolValidator.validate(manifest: manifestObj, proposalDir: proposalDir)
        errors.append(contentsOf: deep.errors)
        let valid = errors.isEmpty && deep.valid
        return ProposalValidationResult(
            valid: valid,
            autoPromotable: valid && deep.autoPromotable,
            errors: errors
        )
    }

    public func runTool(id: String, input: JSONValue) async throws -> JSONValue {
        try await runTool(id: id, input: input, requiredFingerprint: nil)
    }

    /// R9 (review round 2): `requiredFingerprint` lets a caller that already
    /// ADMITTED a specific code fingerprint pin the run to it — closing the
    /// TOCTOU where a registry/manifest mutation between the caller's check
    /// and this run would otherwise downgrade to an unverified execution.
    /// When non-nil it OVERRIDES the record/manifest fingerprint as the
    /// expected value; a swap then fails as fingerprintMismatch.
    public func runTool(
        id: String,
        input: JSONValue,
        requiredFingerprint: String?
    ) async throws -> JSONValue {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeToolId(trimmed) else {
            throw ToolExecutionError.invalidProposal("tool id is required and must be a single safe path component")
        }
        let registry = SwiftNativeToolRegistry(root: root, persistence: persistence, clock: clock)
        guard let record = try await registry.getTool(id: trimmed) else {
            throw ToolExecutionError.proposalNotFound(trimmed)
        }
        guard record.status == "active" else {
            throw ToolRunError.toolNotActive(id: trimmed, currentStatus: record.status)
        }

        let activeRoot = root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
        let toolRoot = try Self.resolveActiveToolRoot(record: record, id: trimmed, activeRoot: activeRoot)
        let manifestRaw = try await persistence.readJSON(
            toolRoot.appendingPathComponent("manifest.json"),
            ifMissing: .null
        )
        guard case .object(let manifest) = manifestRaw else {
            throw ToolExecutionError.underlying("active tool manifest is missing or unreadable: \(trimmed)")
        }
        let entrypoint = try Self.safeEntrypointName(manifest)
        let timeoutSeconds = Self.timeoutSeconds(manifest)
        let expectedFingerprint = requiredFingerprint
            ?? record.codeFingerprint
            ?? Self.stringField(manifest, "codeFingerprint")
        let actualFingerprint = computeToolCodeFingerprint(toolRoot: toolRoot, entrypointName: entrypoint)
        guard case .array(let declared)? = manifest["permissions"],
              declared.allSatisfy({ if case .string = $0 { return true }; return false }) else {
            throw ToolExecutionError.underlying("active tool permissions are missing or malformed: \(trimmed)")
        }
        let permissions = Set(declared.compactMap { if case .string(let permission) = $0 { return permission }; return nil })
        guard let registeredPermissions = record.permissions,
              permissions == Set(registeredPermissions) else {
            throw ToolExecutionError.underlying("active tool permissions do not match its registry: \(trimmed)")
        }
        let runner = ToolRunSandboxRunner()
        let result: ToolRunResult
        do {
            result = try await runner.runTool(
                sandbox: ToolRunSandbox(
                    toolRoot: toolRoot,
                    entrypoint: entrypoint,
                    timeoutSeconds: timeoutSeconds,
                    dataRoot: root,
                    permissions: permissions
                ),
                input: input,
                expectedFingerprint: expectedFingerprint,
                actualFingerprint: actualFingerprint
            )
        } catch {
            await noteCall(trimmed, failed: true)
            throw error
        }
        let envelope = Self.runEnvelope(toolId: trimmed, result: result)
        let failed = result.timedOut || result.exitCode != 0 || Self.parsedToolStatus(result.parsedOutput ?? .null) == "failed"
        await noteCall(trimmed, failed: failed, clean: failed ? nil
            : (try? String(contentsOf: toolRoot.appendingPathComponent(entrypoint), encoding: .utf8)).map(Self.sha))
        return envelope
    }

    /// A call is a use (`CapabilityLifecycle`), a clean one names its code;
    /// failing twice in a row asks, as one quiet MY QUEUE line, whether to improve it.
    private func noteCall(_ id: String, failed: Bool, clean: String? = nil) async {
        guard let line = try? await ToolRegistryActions.recordCall(id: id, failed: failed, cleanCode: clean, dataRoot: root)
        else { return }
        _ = try? await MyQueue.add(DeskStep(words: line, when: "quiet"), store: SwiftNativeDeskStore(dataRoot: root))
    }

    @discardableResult
    public func promote(id: String, allowRisky: Bool) async throws -> ProposalRecord {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same gate as runTool: the id becomes a path component that the
        // promote engine removeItem()s — a traversal id like "../active/<x>"
        // must never get that far (audit 2026-06-09).
        guard Self.isSafeToolId(trimmed) else {
            throw ToolExecutionError.invalidProposal("tool id is required and must be a single safe path component")
        }
        let signer = SwiftNativeManifestSigner(dataRoot: root, clock: clock)
        // FINDING #1 fix — wire the real SwiftToolValidator instead of the
        // permissive default. Pinned to the proposal dir so the validator
        // can ground-truth tests.json + entrypoint off disk.
        let proposalDir = root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("proposals", isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
        let engine = ToolPromoteEngine(
            signer: signer,
            dataRoot: root,
            validator: SwiftToolValidator.make(proposalDir: proposalDir),
            clock: clock
        )
        let promoted: [String: JSONValue]
        do {
            promoted = try await engine.promote(
                proposalId: trimmed,
                allowRisky: allowRisky,
                approvedBy: allowRisky ? "user_requested" : "safe_auto"
            )
        } catch ToolPromoteError.unknownProposal {
            throw ToolExecutionError.proposalNotFound(trimmed)
        } catch ToolPromoteError.validationFailed(let errs) {
            throw ToolExecutionError.validationFailed(errs)
        } catch ToolPromoteError.riskyWithoutAllowRisky(let perms) {
            throw ToolExecutionError.validationFailed(
                ["risky permissions require allowRisky=true: \(perms.joined(separator: ","))"]
            )
        } catch {
            throw ToolExecutionError.underlying(error.localizedDescription)
        }
        // The engine returns the full merged manifest+record dict. Every
        // promoted field round-trips through ProposalRecord's typed slots +
        // extras-bag (activePath / manifestSignature / signedAt /
        // signatureVersion / codeFingerprint / phase / promotedAt /
        // validationStatus / risk-ack fields all land in extras and survive
        // toJSON()). No ProposalRecord schema extension needed.
        guard let rec = ProposalRecord(json: .object(promoted)) else {
            throw ToolExecutionError.underlying("promote returned malformed record")
        }
        return rec
    }

    public nonisolated static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    private nonisolated static func isSafeToolId(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if id == "." || id == ".." { return false }
        if id.contains("/") || id.contains("\\") || id.contains("\0") { return false }
        // Reserved for the promote engine's staged-swap machinery (U5 W-B):
        // a tool named like swap litter would be swept/restored by the
        // promote entry sweep.
        if id.hasPrefix(ToolPromoteEngine.stagingPrefix) || id.hasPrefix(ToolPromoteEngine.retiredPrefix) {
            return false
        }
        return true
    }

    private nonisolated static func resolveActiveToolRoot(
        record: ToolRecord,
        id: String,
        activeRoot: URL
    ) throws -> URL {
        let activeRootResolved = activeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let expected = activeRootResolved
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate: URL
        if let raw = record.activePath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            candidate = URL(fileURLWithPath: raw, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        } else {
            candidate = expected
        }
        guard candidate.path == expected.path else {
            throw ToolExecutionError.underlying(
                "activePath for \(id) must resolve to \(expected.path)"
            )
        }
        return candidate
    }

    private nonisolated static func safeEntrypointName(_ manifest: [String: JSONValue]) throws -> String {
        let entrypoint = stringField(manifest, "entrypoint") ?? "tool.swift"
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if entrypoint.hasPrefix("/") || parts.contains(where: { $0 == ".." || $0.isEmpty }) {
            throw ToolExecutionError.underlying("unsafe tool entrypoint: \(entrypoint)")
        }
        return entrypoint
    }

    private nonisolated static func timeoutSeconds(_ manifest: [String: JSONValue]) -> Int {
        let raw = manifest["timeoutSeconds"] ?? manifest["timeout_seconds"]
        let parsed: Int
        switch raw {
        case .int(let i): parsed = Int(i)
        case .double(let d): parsed = Int(exactly: d.rounded(.towardZero)) ?? 10
        case .string(let s): parsed = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 10
        case .bool(let b): parsed = b ? 1 : 10
        default: parsed = 10
        }
        return min(120, max(1, parsed))
    }

    private nonisolated static func stringField(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = obj[key], !s.isEmpty { return s }
        return nil
    }

    private nonisolated static func runEnvelope(toolId: String, result: ToolRunResult) -> JSONValue {
        let parsed = result.parsedOutput ?? .null
        let status = parsedToolStatus(parsed)
        var obj: [String: JSONValue] = [
            "toolId": .string(toolId),
            "status": .string(status),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exitCode": .int(Int64(result.exitCode)),
            "durationSeconds": .double(result.durationSeconds),
            "timedOut": .bool(result.timedOut),
            "parsedOutput": parsed,
            "result": parsedResult(parsed),
        ]
        if status == "failed", case .object(let parsedObj) = parsed {
            if let error = parsedObj["error"] { obj["error"] = error }
            if let detail = parsedObj["detail"] { obj["detail"] = detail }
        }
        return .object(obj)
    }

    private nonisolated static func parsedToolStatus(_ parsed: JSONValue) -> String {
        guard case .object(let obj) = parsed else { return "ok" }
        if case .bool(false)? = obj["ok"] { return "failed" }
        if case .string(let status)? = obj["status"], !status.isEmpty { return status }
        return "ok"
    }

    private nonisolated static func parsedResult(_ parsed: JSONValue) -> JSONValue {
        if case .object(let obj) = parsed, let result = obj["result"] {
            return result
        }
        return parsed
    }
}

// MARK: - Her authoring surface

extension SwiftNativeToolExecution {
    /// `tool.propose`: a tool she wrote, filed as a proposal (manifest,
    /// tool.swift, tests.json), validated as promote validates it, and listed
    /// on the Tools page as proposed, where activating it is User's Approve.
    /// A tool that runs now is changed under a new id or after quarantine, so
    /// proposing never stops one that works. Proposing over a version keeps
    /// that one (`tool.rollback`); approval starts over.
    public func propose(id: String, description: String, code: String, tests: [JSONValue],
                        permissions: [String], inputSchema: JSONValue?) async throws -> ProposalValidationResult {
        guard id.range(of: #"^[a-z][a-z0-9_]{1,47}$"#, options: .regularExpression) != nil else {
            throw ToolExecutionError.invalidProposal(
                "tool_id is 2 to 48 lowercase letters, digits and underscores, starting with a letter")
        }
        guard !description.isEmpty, !code.isEmpty else {
            throw ToolExecutionError.invalidProposal("description and code are both required")
        }
        let existing = try await unlessActive(id)
        try keepVersion(id)
        var manifest: [String: JSONValue] = [
            "id": .string(id), "name": .string(id), "description": .string(description), "triggers": .array([]),
            "permissions": .array(permissions.map(JSONValue.string)), "entrypoint": .string("tool.swift"),
            "language": .string("swift"),
        ]
        if let inputSchema { manifest["inputSchema"] = inputSchema }
        _ = try await createProposal(.object(manifest))
        let dir = proposalsDir.appendingPathComponent(id, isDirectory: true)
        try Data(code.utf8).write(to: dir.appendingPathComponent("tool.swift"), options: .atomic)
        try JSONValue.array(tests).serializedData(pretty: true).write(to: dir.appendingPathComponent("tests.json"), options: .atomic)
        var result = try await validateProposal(id: id, promote: false)
        // Promote activates only permissions that are all app data, or that
        // include one User acknowledges as risky; say so now, not at Approve.
        if result.valid, !result.autoPromotable, Set(permissions).isDisjoint(with: ToolPromoteEngine.riskyToolPermissions) {
            result.valid = false
            result.errors.append("Approve can't activate these permissions: a tool that reads declares app_data_read, "
                + "one that changes app state app_data_write; past that, add the one it needs (shell, network_public)")
        }
        let stamp = Self.isoTimestamp(clock())
        var row = manifest
        row["status"] = .string("proposed")
        row["phase"] = .string("proposed")
        row["validationStatus"] = .string(result.valid ? "valid" : "invalid")
        row["validationErrors"] = .array(result.errors.map(JSONValue.string))
        row["proposalPath"] = .string(dir.path)
        row["createdAt"] = .string(existing?.createdAt ?? stamp)
        row["updatedAt"] = .string(stamp)
        row["failuresInARow"] = .int(0)
        try await ToolRegistryActions.upsertProposal(.object(row), dataRoot: root)
        return result
    }

    /// Its row, refused while active: a tool that runs now is changed under a
    /// new id or after quarantine.
    private func unlessActive(_ id: String) async throws -> ToolRecord? {
        let existing = try await SwiftNativeToolRegistry(root: root, persistence: persistence, clock: clock).getTool(id: id)
        if existing?.status == "active" {
            throw ToolExecutionError.invalidProposal(
                "\(id) is active. Propose the change under a new tool_id, or tool.quarantine \(id) first")
        }
        return existing
    }

    /// `tool.rollback`: the version she wrote before this one (its last clean
    /// one when kept), proposed again, drafted and waiting for approval; the
    /// one it replaces is kept in turn. Refused while active, as proposing is.
    public func rollback(id: String) async throws -> ProposalValidationResult {
        guard case .object(let version) = try rollbackTarget(id).row, case .string(let code)? = version["code"] else {
            throw ToolExecutionError.invalidProposal("\(id) has no earlier version to roll back to")
        }
        let manifest: [String: JSONValue] = if case .object(let given)? = version["manifest"] { given } else { [:] }
        let tests: [JSONValue] = if case .array(let given)? = version["tests"] { given } else { [] }
        let permissions: [String] = if case .array(let given)? = manifest["permissions"] {
            given.compactMap { if case .string(let p) = $0 { p } else { nil } }
        } else { [] }
        let description = if case .string(let text)? = manifest["description"] { text } else { id }
        return try await propose(id: id, description: description, code: code, tests: tests, permissions: permissions,
                                 inputSchema: manifest["inputSchema"])
    }

    /// `tool.rollback`'s preview: the digest of the version it would land on,
    /// refused as the rollback would be. Writes nothing.
    public func rollbackPreview(id: String) async throws -> String {
        let target = try rollbackTarget(id)
        _ = try await unlessActive(id)
        return target.sha
    }

    /// The version rollback lands on: the last clean earlier one, else the previous.
    private func rollbackTarget(_ id: String) throws -> (sha: String, row: JSONValue) {
        let earlier = earlierVersions(id)
        guard let target = earlier.clean ?? earlier.previous else {
            throw ToolExecutionError.invalidProposal("\(id) has no earlier version to roll back to")
        }
        return target
    }

    /// The code on disk now, and of the kept earlier versions the previous
    /// and the last clean one; `cleanSha` is the last clean call's code.
    private func earlierVersions(_ id: String) -> (current: String?, previous: (sha: String, row: JSONValue)?,
                                                   clean: (sha: String, row: JSONValue)?, cleanSha: String?) {
        let current = (try? String(contentsOf: proposalsDir.appendingPathComponent("\(id)/tool.swift"), encoding: .utf8)).map(Self.sha)
        let earlier = keptVersions(id).filter { $0.sha != current }
        let clean = ToolRegistryActions.lastCleanCode(id: id, dataRoot: root)
        return (current, earlier.last, earlier.last { $0.sha == clean }, clean)
    }

    /// A tool's current, previous and last clean versions (`CapabilityLifecycle`),
    /// each its code's digest (12), when it was made and the status it lands
    /// in (a rollback lands proposed); null when not kept.
    public func versions(id: String) async -> JSONValue {
        let earlier = earlierVersions(id)
        let row = try? await SwiftNativeToolRegistry(root: root, persistence: persistence, clock: clock).getTool(id: id)
        func version(_ sha: String?, _ at: String?, _ lands: String) -> JSONValue {
            guard let sha else { return .null }
            return .object(["digest": .string(String(sha.prefix(12))), "at": at.map(JSONValue.string) ?? .null,
                            "lands": .string(lands)])
        }
        func kept(_ entry: (sha: String, row: JSONValue)?) -> JSONValue {
            guard let entry else { return .null }
            let at: String? = if case .object(let fields) = entry.row, case .string(let text)? = fields["at"] { text } else { nil }
            return version(entry.sha, at, "proposed")
        }
        let current = version(earlier.current, row?.updatedAt ?? row?.createdAt, row?.status ?? "proposed")
        return .object(["current": current, "previous": kept(earlier.previous),
                        "last_clean": earlier.cleanSha != nil && earlier.cleanSha == earlier.current ? current : kept(earlier.clean)])
    }

    private func historyFile(_ id: String) -> URL {
        root.appendingPathComponent("tools/history/\(id).json")
    }

    private func keptVersions(_ id: String) -> [(sha: String, row: JSONValue)] {
        guard case .array(let rows)? = try? JSONValue.parse(Data(contentsOf: historyFile(id))) else { return [] }
        return rows.compactMap { row in
            guard case .object(let fields) = row, case .string(let code)? = fields["code"] else { return nil }
            return (Self.sha(code), row)
        }
    }

    /// The proposal on disk now, kept as a version before a new one replaces
    /// it. With the one on disk, a tool has its current, previous and last
    /// clean versions, never more (`CapabilityLifecycle`).
    private func keepVersion(_ id: String) throws {
        let dir = proposalsDir.appendingPathComponent(id, isDirectory: true)
        guard let code = try? String(contentsOf: dir.appendingPathComponent("tool.swift"), encoding: .utf8) else { return }
        let read = { (name: String) in (try? JSONValue.parse(Data(contentsOf: dir.appendingPathComponent(name)))) ?? .null }
        let kept = keptVersions(id) + [(Self.sha(code), JSONValue.object([
            "at": .string(Self.isoTimestamp(clock())), "code": .string(code), "tests": read("tests.json"), "manifest": read("manifest.json"),
        ]))]
        let held = CapabilityLifecycle.keptVersions(kept.map { ($0.sha, $0.sha) }, recent: 1,
                                                    clean: ToolRegistryActions.lastCleanCode(id: id, dataRoot: root))
        try FileManager.default.createDirectory(at: historyFile(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONValue.array(held.map { kept[$0].row }).serializedData(pretty: true).write(to: historyFile(id), options: .atomic)
    }

    /// SHA-256 of a tool's code: the key its versions and clean calls share.
    static func sha(_ code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Factory

public func makeToolExecution() -> any ToolExecutionProtocol {
    return SwiftNativeToolExecution()
}
