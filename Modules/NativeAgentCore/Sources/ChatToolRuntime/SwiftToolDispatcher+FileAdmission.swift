import AuthoredCapabilities
import AgentWorkspace
import Foundation
import TurnTrace
import Experiences
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
import Senses
import ToolRegistry
import ActivityWatch
import ChatTurnContracts
import NativeAgentShared
// Blueprint: | `SwiftToolDispatcher+FileAdmission.swift` | `SwiftToolDispatcher`: file-root admission, bundled document reads, Full Mac access projection, local connector execution and file-result errors; connector work preserves call-scoped image and source-material context |

extension SwiftToolDispatcher {
    /// Source-repository reads share one root and its top-level allowlist.
    static let allowedTopLevels: Set<String> = ["workspace", "persona", "data", "script"]

    /// Resolve a caller-supplied relative path under `rootForRead`,
    /// enforcing:
    ///   * no absolute paths,
    ///   * no `..` escapes — verified by `.standardizedFileURL` (normalizes
    ///     `.`/`..`) AND then re-resolved via `.resolvingSymlinksInPath` so
    ///     a symlink inside the root that points outside is rejected,
    ///   * the first path component is in `allowedTopLevels`.
    /// Throws `AutonomyGateError.toolDenied` on any violation.
    func resolveSandboxed(_ relativePath: String, followFinalLink: Bool = true) throws -> URL {
        let trimmed = relativePath
        guard !trimmed.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: empty path")
        }
        guard !trimmed.hasPrefix("/") else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: absolute paths are not allowed ('\(trimmed)')"
            )
        }

        let root = rootForRead
        let rootPath = root.resolvingSymlinksInPath().path
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        // .standardizedFileURL handles `.`/`..` but NOT symlinks. Resolve
        // symlinks too so a workspace/link -> /etc can't escape the sandbox.
        let candidateResolved = candidate.resolvingSymlinksInPath()
        let candidatePath = candidateResolved.path

        // Strict prefix: must be inside root (resolved). Equality alone is
        // not enough — the caller asked for SOMETHING under the root.
        guard let suffix = NativeAgentWorkspaceRoot.relativePath(candidatePath, under: rootPath) else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: path escapes data root ('\(trimmed)')"
            )
        }
        // Suffix (path after root/). First component must be allow-listed.
        let firstComponent = suffix.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard Self.allowedTopLevels.contains(firstComponent) else {
            let allowed = Self.allowedTopLevels.sorted().joined(separator: ", ")
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(trimmed)' is not under an allowed subdir of data/ (one of: \(allowed))"
            )
        }
        return followFinalLink ? candidateResolved : candidate
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            guard case .string(let s) = value else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
    func trustedWorkspaceRoots() async -> [URL] {
        let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        return SwiftNativeSecurityCenter.trustedWorkspaceRoots(policy: policy,
            filePolicy: policy["filePolicy"]?.objectValue ?? [:], dataRoot: dataRoot)
    }

    // MARK: - Bundled docs (read-only)

    /// Signed reference documents are reachable only through file reads.
    static func bundledDocsRoot(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let docs = resources
            .appendingPathComponent("docs", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return docs
    }

    /// Resolve `docs/...` (and `docs` itself) against the bundled docs tree.
    /// Returns nil for anything else, for an escape attempt, or when the path
    /// does not exist; ordinary paths retain the normal sandbox errors.
    static func resolveBundledDocsPath(_ path: String, bundle: Bundle = .main) -> URL? {
        let trimmed = path
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "docs" else { return nil }
        guard let root = bundledDocsRoot(bundle: bundle) else { return nil }
        let candidate = parts.count == 1
            ? root
            : root
                .appendingPathComponent(parts.dropFirst().joined(separator: "/"))
                .standardizedFileURL
                .resolvingSymlinksInPath()
        guard SwiftNativeSecurityCenter.isSelfOrAncestor(root: root, of: candidate) else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    package func resolveTrustedFilePath(
        _ rawPath: String,
        includeRepoSandbox: Bool = true,
        followFinalLink: Bool = true,
        trustedRoots: [URL]? = nil
    ) async throws -> URL {
        guard !rawPath.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: empty path")
        }
        let path = NativeAgentWorkspaceRoot.fileSpelling(rawPath)
        guard !path.hasPrefix("~") else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: '\(rawPath)' has no supported home directory")
        }
        let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        let workspaceAlias = NativeAgentWorkspaceRoot.normalizeWorkspaceAlias(path, workspaceRoot: workspaceRoot) != path
        if includeRepoSandbox, !workspaceAlias {
            if let bundled = Self.resolveBundledDocsPath(path) { return bundled }
            if !path.hasPrefix("/"), let sandboxed = try? resolveSandboxed(path, followFinalLink: followFinalLink) {
                return sandboxed
            }
        }
        let candidate = NativeAgentWorkspaceRoot.fileCandidate(rawPath, relativeTo: workspaceRoot, workspaceRoot: workspaceRoot)
        if workspaceAlias || !path.hasPrefix("/") {
            guard SwiftNativeSecurityCenter.isSelfOrAncestor(root: workspaceRoot, of: candidate) else {
                throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: relative path escapes the canonical workspace")
            }
        } else {
            let roots = if let trustedRoots { trustedRoots } else { await trustedWorkspaceRoots() }
            guard AbilityStore.fileReachAllows(candidate, write: !includeRepoSandbox)
                || roots.contains(where: { SwiftNativeSecurityCenter.isSelfOrAncestor(root: $0, of: candidate) }) else {
                let renderedRoots = roots.map(\.path).sorted().joined(separator: ", ")
                throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: '\(rawPath)' is outside trusted workspace roots (\(renderedRoots))")
            }
        }
        return NativeAgentWorkspaceRoot.canonicalFileURL(candidate, followFinalLink: followFinalLink)
    }

    func requireString(_ input: [String: JSONValue], _ key: String) throws -> String {
        if case .string(let s)? = input[key] { return s }
        throw AutonomyGateError.toolDenied(
            reason: "SwiftToolDispatcher: missing or non-string '\(key)'"
        )
    }
    func optionalString(_ input: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s)? = input[key] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : s
    }
    func canonicalPersonaKind(_ kind: String) -> String {
        SwiftNativePersonaEngine.canonicalizeKind(kind)
    }

    func personaWriteResultJSON(_ result: PersonaToolWriteResult) -> JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string("saved"),
            "ok": .bool(true),
            "kind": .string(result.kind),
            "path": .string(result.path),
        ]
        if let backupPath = result.backupPath {
            obj["backup_path"] = .string(backupPath)
        } else {
            obj["backup_path"] = .null
        }
        if let bytesWritten = result.bytesWritten {
            obj["bytes_written"] = .int(Int64(bytesWritten))
        }
        if let bytesAppended = result.bytesAppended {
            obj["bytes_appended"] = .int(Int64(bytesAppended))
        }
        return .object(obj)
    }

    struct FullMacToolAccess: Sendable {
        /// The exact policy snapshot used to admit this tool call. Passing the
        /// same snapshot into MacControl avoids reading and decoding Trust
        /// Center a second time inside one dispatch while keeping every new
        /// tool call sensitive to policy changes.
        var macPolicy: MacControlPolicy
        var fullMacActive: Bool
        var fileOpsAllowed: Bool
        var systemAllowed: Bool
        var accessibilityAllowed: Bool
        var permissionLevel: String
        var outsideWorkspaceDefault: String
    }

    func fullMacYoloAdmitted(surface: String) async -> Bool {
        await ChatFullMacYoloAdmission.admitted(surface: surface,
            dataRoot: dataRoot, source: "swift_tool_dispatcher")
    }

    func fullMacToolAccess(surface: String = "chat") async -> FullMacToolAccess {
        let snapshot = try? await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
        let policy = snapshot?.policy ?? [:]
        let admitted = if let snapshot {
            await ChatFullMacYoloAdmission.admitted(surface: surface,
                dataRoot: dataRoot, source: "swift_tool_dispatcher", snapshot: snapshot)
        } else { false }
        let macPolicy = MacControlGate.policyForAdmittedFullMac(
            MacControlPolicy.fromTrustPolicyObject(policy, dataRoot: dataRoot), admitted: admitted
        )
        let trust = macPolicy.trustPolicy ?? MacControlTrustPolicy()
        let fullMacActive = MacControlGate.fullMacActive(trust)
        let trigger = Self.fullMacTrigger(forSurface: surface)

        func categoryAllowed(_ category: String) -> Bool {
            guard fullMacActive else { return false }
            return MacControlGate.gate(macPolicy, category: category, trigger: trigger).allowed
        }

        return FullMacToolAccess(
            macPolicy: macPolicy,
            fullMacActive: fullMacActive,
            fileOpsAllowed: categoryAllowed("file_ops"),
            systemAllowed: categoryAllowed("system"),
            accessibilityAllowed: categoryAllowed("accessibility"),
            permissionLevel: trust.permissionLevel,
            outsideWorkspaceDefault: trust.outsideWorkspaceDefault
        )
    }

    private static func fullMacTrigger(forSurface surface: String) -> String {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios", "icloud", "iphone", "ipad", "mobile", "watch":
            return "ios"
        default:
            return "user"
        }
    }

    func categoryForLocalConnectorTool(_ tool: String) -> String? {
        if Self.fullMacFileToolNames.contains(tool) || ["read_file", "list_dir", "file_info"].contains(tool) {
            return "file_ops"
        }
        if Self.fullMacSystemToolNames.contains(tool) {
            return "system"
        }
        return nil
    }

    func impl_local_connector_tool(tool: String, input: [String: JSONValue], surface: String, attachment: (filename: String, data: Data)? = nil) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        let category = categoryForLocalConnectorTool(tool)
        let allowed: Bool
        switch category {
        case "file_ops": allowed = access.fileOpsAllowed
        case "system": allowed = access.systemAllowed
        default: allowed = false
        }
        guard allowed else {
            // Not a refusal to relay as prose — a decision the person has not
            // made. It gets asked where the work is, carrying the axis this
            // call wanted, and it never touches the Trust posture itself.
            if let category, let need = macControlCategoryNeedEnvelope(
                categories: [category],
                mode: ["read_file", "list_dir", "file_info"].contains(tool) ? .read : .write,
                why: "\(tool) needs \(InlineInteractionRegistry.macCapabilityDisplayName(category).lowercased()), which is off right now."
            ) {
                return need
            }
            throw AutonomyGateError.toolDenied(
                reason: "Trust Full Mac mode is not active for \(tool)"
            )
        }
        let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        if ["mac_volume", "mac_media"].contains(tool) {
            let impl = makeMacControl(
                policyProvider: SwiftToolDispatcherMacControlPolicyProvider(policy: access.macPolicy),
                auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl"))
            return try await impl.dispatch(action: tool == "mac_volume" ? "volume" : "media", body: input).toJSON()
        }
        let operationalRoot = Self.builderSourceRepoRoot(dataRoot: dataRoot)
            ?? workspaceRoot
        let ctx = ConnectorActionContext(
            repoRoot: operationalRoot,
            fileAccess: [
                "mode": .string("full"),
                "sandbox": .string("danger-full-access"),
            ],
            dataRoot: dataRoot,
            extraAllowedRoots: [
                rootForRead,
                PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot),
                workspaceRoot,
            ],
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot),
            workspaceRoot: workspaceRoot
        )
        // Blocking connector filesystem work runs outside the cooperative pool.
        let imageSink = LocalToolImage.sink
        let sourceMaterialOnly = FileReadSourceMaterial.metadataOnly
        if let attachment { return LocalConnectorActions.saveAttachment(attachment, input: input, ctx: ctx) }
        let connectorResult: JSONValue? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = FileReadSourceMaterial.$metadataOnly.withValue(sourceMaterialOnly) {
                    LocalToolImage.$sink.withValue(imageSink) {
                        LocalConnectorActions.fileSystemDefault.run(tool, input: input, ctx: ctx)
                    }
                }
                continuation.resume(returning: result)
            }
        }
        guard let result = connectorResult else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift local connector implementation"
            )
        }
        return result
    }

    func filePathMissEnvelope(
        tool: String,
        input: [String: JSONValue],
        resultObject obj: [String: JSONValue]
    ) -> JSONValue? {
        guard obj["path_kind"] != nil else { return nil }
        var out = obj
        out["tool"] = .string(tool)
        out["permission_denied"] = .bool(false)
        var hint = "Path lookup failed. Check the exact path; this is not a Trust denial."
        if case .string(let rawPath)? = input["path"],
           let personaDoc = Self.personaDocumentHint(for: rawPath) {
            out["suggested_tool"] = .string("app")
            out["suggested_input"] = .object(["action": .string("persona.doc"), "args": .object(["doc": .string(personaDoc)])])
            hint = "Persona documents are not workspace files on app-only installs. Use app with suggested_input; do not retry read_file with another relative path."
        } else if case .string(let path)? = obj["path"] {
            if obj["path_kind"] == .string("directory") { hint = "\(path) is a folder, not a file. Use list_dir on it." }
            else if obj["path_kind"] == .string("file") { hint = "\(path) is a file, not a folder. Use read_file on it." }
            else if obj["parent_exists"] == .bool(false) {
                hint = "Not found, and its folder \(URL(fileURLWithPath: path).deletingLastPathComponent().path) does not exist either. Check the folder path."
            }
        }
        out["hint"] = .string(hint)
        return .object(out)
    }

    private static func personaDocumentHint(for rawPath: String) -> String? {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2,
              components[0].lowercased() == "persona" else {
            return nil
        }
        let file = String(components[1])
        let stem = file.lowercased().hasSuffix(".md")
            ? String(file.dropLast(3))
            : file
        let allowed: Set<String> = ["soul", "user", "agents", "voice", "growth", "memory"]
        guard allowed.contains(stem.lowercased()) else { return nil }
        return stem.uppercased()
    }


    func impl_full_mac_list_dir(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let result = try await impl_local_connector_tool(tool: "list_dir", input: input, surface: surface)
        guard case .object(let obj) = result else { return result }
        if case .array? = obj["entries"] { return result }
        if case .string(let code)? = obj["error_code"], ["directory_changed", "bad_input"].contains(code) {
            return result
        }
        if let pathMiss = filePathMissEnvelope(tool: "list_dir", input: input, resultObject: obj) {
            return pathMiss
        }
        if case .string(let error)? = obj["error"] {
            throw AutonomyGateError.toolDenied(reason: error)
        }
        return result
    }
}
