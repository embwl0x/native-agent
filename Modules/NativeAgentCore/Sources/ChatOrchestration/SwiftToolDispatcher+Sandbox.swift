import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

private struct SwiftToolDispatcherMacControlPolicyProvider: MacControlPolicyProvider {
    let dataRoot: URL

    func currentPolicy() async -> MacControlPolicy? {
        let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        return MacControlPolicy.fromTrustPolicyObject(policy)
    }
}

// MARK: - Sandbox

extension SwiftToolDispatcher {
    /// Top-level subdirs under the SOURCE-REPO root the dispatcher allows
    /// reads under:
    ///   - `persona/` → canonical SOUL/USER/AGENTS/VOICE/GROWTH (flat) + Agent/
    ///   - `data/`    → skills/, kg/, chat/, memory/, graphs/, dream_diary/, ...
    ///   - `script/`  → install_app.sh, build_and_run.sh, smoke_all.sh, ...
    ///   - `workspace/` → user scratch + drafts
    ///
    /// Both `persona/` and `data/` subdirs are reachable from here, so a
    /// caller asking for `persona/SOUL.md` or `data/skills/registry.json`
    /// both resolve via the SAME root — no "two tools, two roots" seam.
    static let allowedTopLevels: Set<String> = ["workspace", "persona", "data", "script"]

    /// Resolve a caller-supplied relative path under `rootForRead`,
    /// enforcing:
    ///   * no absolute paths,
    ///   * no `..` escapes — verified by `.standardizedFileURL` (normalizes
    ///     `.`/`..`) AND then re-resolved via `.resolvingSymlinksInPath` so
    ///     a symlink inside the root that points outside is rejected,
    ///   * the first path component is in `allowedTopLevels`.
    /// Throws `AutonomyGateError.toolDenied` on any violation.
    func resolveSandboxed(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: path escapes data root ('\(trimmed)')"
            )
        }
        // Suffix (path after root/). First component must be allow-listed.
        let suffix: String
        if candidatePath == rootPath {
            suffix = ""
        } else {
            suffix = String(candidatePath.dropFirst(rootPath.count + 1))
        }
        let firstComponent = suffix.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard Self.allowedTopLevels.contains(firstComponent) else {
            let allowed = Self.allowedTopLevels.sorted().joined(separator: ", ")
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(trimmed)' is not under an allowed subdir of data/ (one of: \(allowed))"
            )
        }
        return candidateResolved
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            guard case .string(let s) = value else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func expandTildePath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return homeDirectory
                .appendingPathComponent(suffix)
                .path
        }
        return path
    }

    static func normalizeFullMacPathArgument(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed.hasPrefix("~") {
            return Self.expandTildePath(trimmed, homeDirectory: homeDirectory)
        }

        let lower = trimmed.lowercased()
        let documentsAlias = "/documents"
        if lower == documentsAlias || lower.hasPrefix(documentsAlias + "/") {
            let documentsRoot = homeDirectory
                .appendingPathComponent("Documents", isDirectory: true)
                .path
            if lower == documentsAlias {
                return documentsRoot
            }
            let suffix = String(trimmed.dropFirst(documentsAlias.count))
            return documentsRoot + suffix
        }
        return path
    }

    static func normalizeWorkspaceAlias(_ path: String, workspaceRoot: URL) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "workspace" || trimmed == "workspace/" {
            return workspaceRoot.path
        }
        if trimmed.hasPrefix("workspace/") {
            return workspaceRoot
                .appendingPathComponent(String(trimmed.dropFirst("workspace/".count)))
                .standardizedFileURL
                .path
        }
        return path
    }

    static func suggestedFullMacPathCorrection(
        for path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }

        var candidates: [String] = []
        func appendCandidate(_ candidate: String?) {
            guard let candidate else { return }
            let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard !normalized.isEmpty, !candidates.contains(normalized) else { return }
            candidates.append(normalized)
        }

        let aliasNormalized = Self.normalizeFullMacPathArgument(trimmed, homeDirectory: homeDirectory)
        appendCandidate(aliasNormalized)
        appendCandidate(Self.pathByReplacingMismatchedUserHome(aliasNormalized, homeDirectory: homeDirectory))

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            if let withoutDescriptor = Self.pathByDroppingTrailingFolderDescriptor(candidate),
               fileManager.fileExists(atPath: withoutDescriptor) {
                return withoutDescriptor
            }
        }
        return nil
    }

    private static func pathByReplacingMismatchedUserHome(
        _ path: String,
        homeDirectory: URL
    ) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 4,
              components[0] == "/",
              components[1] == "Users" else {
            return nil
        }
        let requestedUser = components[2]
        let currentUser = homeDirectory.standardizedFileURL.lastPathComponent
        guard requestedUser != currentUser, !currentUser.isEmpty else { return nil }

        var corrected = homeDirectory.standardizedFileURL
        for component in components.dropFirst(3) {
            corrected.appendPathComponent(component)
        }
        return corrected.path
    }

    private static func pathByDroppingTrailingFolderDescriptor(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        let suffix = " folder"
        guard name.lowercased().hasSuffix(suffix) else { return nil }
        let base = String(name.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(base).path
    }

    private static func normalizedUniqueRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for root in roots {
            let normalized = root
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let path = normalized.path
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    private static func isSelfOrAncestor(root: URL, of candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        if candidatePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    func trustedWorkspaceRoots() async -> [URL] {
        let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        var roots = TrustCenterDefaultWorkspaceRoots.defaultRoots(dataRoot: dataRoot)

        func appendRoots(from obj: [String: JSONValue]) {
            for key in ["workspaceRoots", "workspace_roots", "trustedWorkspaceRoots", "trustedRoots"] {
                for raw in Self.stringArray(obj[key]) {
                    let expanded = Self.expandTildePath(raw)
                    roots.append(URL(fileURLWithPath: expanded))
                }
            }
        }

        appendRoots(from: policy)
        if case .object(let filePolicy)? = policy["filePolicy"] {
            appendRoots(from: filePolicy)
        }
        return Self.normalizedUniqueRoots(roots)
    }

    func resolveTrustedFilePath(
        _ rawPath: String,
        includeRepoSandbox: Bool = true
    ) async throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: empty path")
        }

        let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        let workspaceAlias = Self.normalizeWorkspaceAlias(
            trimmed,
            workspaceRoot: workspaceRoot
        )
        if workspaceAlias != trimmed {
            let candidate = URL(fileURLWithPath: workspaceAlias)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard Self.isSelfOrAncestor(root: workspaceRoot, of: candidate) else {
                throw AutonomyGateError.toolDenied(
                    reason: "SwiftToolDispatcher: workspace path escapes the canonical workspace"
                )
            }
            return candidate
        }

        if includeRepoSandbox,
           !trimmed.hasPrefix("/"),
           !trimmed.hasPrefix("~"),
           let sandboxed = try? resolveSandboxed(trimmed) {
            return sandboxed
        }

        // Ordinary relative paths belong to NativeAgent's own workspace. This
        // makes write, read, and list calls converge on the same public-install
        // location without teaching the model a machine-specific absolute path.
        if !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") {
            let candidate = workspaceRoot
                .appendingPathComponent(trimmed)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard Self.isSelfOrAncestor(root: workspaceRoot, of: candidate) else {
                throw AutonomyGateError.toolDenied(
                    reason: "SwiftToolDispatcher: relative path escapes the canonical workspace"
                )
            }
            return candidate
        }

        let expanded = Self.expandTildePath(trimmed)
        guard expanded.hasPrefix("/") else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(trimmed)' must be workspace-relative or an absolute/~/ path under a Trust Center workspace root"
            )
        }
        let candidate = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let roots = await trustedWorkspaceRoots()
        guard roots.contains(where: { Self.isSelfOrAncestor(root: $0, of: candidate) }) else {
            let renderedRoots = roots.map(\.path).sorted().joined(separator: ", ")
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(trimmed)' is outside trusted workspace roots (\(renderedRoots))"
            )
        }
        return candidate
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
    func optionalInt(_ input: [String: JSONValue], _ key: String) -> Int? {
        switch input[key] {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)): return Int(d)
        case .some(.string(let s)): return Int(s)
        default: return nil
        }
    }

    func personaRootForTools() -> URL {
        if let verifiedRepo = resolveSandboxRepoRoot(dataRoot: dataRoot) {
            return PersonaRootResolver.resolve(
                repoRoot: verifiedRepo,
                dataRootProvider: { dataRoot }
            )
        }
        // App-only installs and synthetic roots must stay inside their exact
        // data root. Falling through to PersonaRootResolver's process-CWD
        // lookup here can expose the developer checkout to an isolated body.
        return PersonaRootResolver.resolveIsolated(dataRoot: dataRoot)
    }

    func canonicalPersonaKind(_ kind: String) -> String {
        kind
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func validatePersonaSkillName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
        }
    }

    func personaToolPath(kind: String, skillName: String?) -> URL? {
        let personaRoot = personaRootForTools()
        switch kind {
        case "soul": return personaRoot.appendingPathComponent("SOUL.md")
        case "user": return personaRoot.appendingPathComponent("USER.md")
        case "voice": return personaRoot.appendingPathComponent("VOICE.md")
        case "growth": return personaRoot.appendingPathComponent("GROWTH.md")
        case "agents": return personaRoot.appendingPathComponent("AGENTS.md")
        case "skill":
            guard let skillName, validatePersonaSkillName(skillName) else { return nil }
            let personaSkill = personaRoot
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("bodies", isDirectory: true)
                .appendingPathComponent("\(skillName).md")
            if FileManager.default.fileExists(atPath: personaSkill.path) {
                return personaSkill
            }
            return dataRoot
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("bodies", isDirectory: true)
                .appendingPathComponent("\(skillName).md")
        default:
            return nil
        }
    }

    func personaWriteResultJSON(_ result: PersonaToolWriteResult) -> JSONValue {
        var obj: [String: JSONValue] = [
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
        var fullMacActive: Bool
        var fileOpsAllowed: Bool
        var systemAllowed: Bool
        var appControlAllowed: Bool
        var permissionLevel: String
        var outsideWorkspaceDefault: String
    }

    func fullMacToolAccess(surface: String = "chat") async -> FullMacToolAccess {
        let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policy)
        let trust = macPolicy.trustPolicy ?? MacControlTrustPolicy()
        let fullMacActive = MacControlGate.fullMacActive(trust)
        let trigger = Self.fullMacTrigger(forSurface: surface)

        func categoryAllowed(_ category: String) -> Bool {
            guard fullMacActive else { return false }
            return MacControlGate.gate(macPolicy, category: category, trigger: trigger).allowed
        }

        return FullMacToolAccess(
            fullMacActive: fullMacActive,
            fileOpsAllowed: categoryAllowed("file_ops"),
            systemAllowed: categoryAllowed("system"),
            appControlAllowed: categoryAllowed("accessibility"),
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
        if Self.fullMacFileToolNames.contains(tool) || tool == "read_file" || tool == "list_dir" {
            return "file_ops"
        }
        if Self.fullMacSystemToolNames.contains(tool) {
            return "system"
        }
        if Self.fullMacAppToolNames.contains(tool) {
            return "accessibility"
        }
        return nil
    }

    func impl_local_connector_tool(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        let allowed: Bool
        switch categoryForLocalConnectorTool(tool) {
        case "file_ops": allowed = access.fileOpsAllowed
        case "system": allowed = access.systemAllowed
        case "accessibility": allowed = access.appControlAllowed
        default: allowed = false
        }
        guard allowed else {
            throw AutonomyGateError.toolDenied(
                reason: "Trust Center Full Mac mode is not active for \(tool)"
            )
        }
        let workspaceRoot = NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        let operationalRoot = Self.builderSourceRepoRoot(dataRoot: dataRoot)
            ?? workspaceRoot
        let ctx = ConnectorActionContext(
            repoRoot: operationalRoot.path,
            fileAccess: [
                "mode": .string("full"),
                "sandbox": .string("danger-full-access"),
            ],
            dataRoot: dataRoot.path,
            extraAllowedRoots: [
                rootForRead.path,
                PersonaRootResolver.resolve().path,
                workspaceRoot.path,
            ],
            personaRoot: PersonaRootResolver.resolve().path,
            workspaceRoot: workspaceRoot.path
        )
        // Expand a leading `~` in path args BEFORE LocalConnectorActions runs:
        // it resolves relative paths against repoRoot and does NOT expand `~`,
        // so "~/Desktop/x" would land at <repoRoot>/~/Desktop/x (a literal `~`
        // dir) instead of $HOME/Desktop/x. Full-mac file ops (danger-full-access
        // sandbox) should honor `~` (2026-06-15: caught live — an execution wrote
        // agent_yolo.txt under the repo's `~/` instead of the real Desktop).
        var resolvedInput = input
        for key in ["path", "source", "destination", "dest", "src", "to", "from"] {
            if case .string(let p)? = resolvedInput[key] {
                let workspacePath = Self.normalizeWorkspaceAlias(
                    p,
                    workspaceRoot: workspaceRoot
                )
                resolvedInput[key] = .string(
                    Self.normalizeFullMacPathArgument(workspacePath)
                )
            }
        }
        // Audit H1 (2026-07-09): `run` is SYNCHRONOUS and can block up to 30s on
        // proc.waitUntilExit (grep/git_* subprocesses). This async fn runs on the
        // cooperative pool, whose thread count is core-bounded — parallel tool
        // fan-out (ToolLoop withTaskGroup) could pin every pool thread and starve
        // the whole app (the exact hazard FileSystemActions.swift:1296 documents
        // one layer down). Hop to a detached utility thread, same pattern as
        // MacSyncEngine+Inbox.swift:144.
        let detachedResult = await Task.detached(priority: .utility) {
            LocalConnectorActions.fileSystemDefault.run(tool, input: resolvedInput, ctx: ctx)
        }.value
        guard let result = detachedResult else {
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
        guard case .string(let code)? = obj["error_code"], code == "file_not_found" else {
            return nil
        }
        var out = obj
        out["tool"] = .string(tool)
        out["permission_denied"] = .bool(false)
        var hint = "This is a path lookup miss, not a Full Mac or Trust Center denial. Check the exact path and retry."
        if case .string(let rawPath)? = input["path"],
           let personaDoc = Self.personaDocumentHint(for: rawPath) {
            out["suggested_tool"] = .string("get_persona_doc")
            out["suggested_input"] = .object(["doc": .string(personaDoc)])
            hint = "Persona documents are not workspace files on app-only installs. Use get_persona_doc with suggested_input; do not retry read_file with another relative path."
        } else if case .string(let rawPath)? = input["path"],
                  let suggestion = Self.suggestedFullMacPathCorrection(for: rawPath) {
            out["suggested_path"] = .string(suggestion)
            hint = "This is a path lookup miss, not a Full Mac or Trust Center denial. Retry once with suggested_path."
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

    func impl_mac_app_control_tool(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        guard access.appControlAllowed else {
            throw AutonomyGateError.toolDenied(
                reason: "Trust Center Full Mac Accessibility app control is not active for \(tool)"
            )
        }
        let action: String
        switch tool {
        case "mac_focus_app": action = "focus_app"
        case "mac_quit_app": action = "quit_app"
        default:
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift Mac app-control implementation"
            )
        }
        let impl = makeMacControl(
            policyProvider: SwiftToolDispatcherMacControlPolicyProvider(dataRoot: dataRoot),
            auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl")
        )
        let result = try await impl.dispatch(action: action, body: input)
        return result.toJSON()
    }

    func impl_full_mac_read_file(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let result = try await impl_local_connector_tool(tool: "read_file", input: input, surface: surface)
        guard case .object(let obj) = result else { return result }
        if case .string(let content)? = obj["content"] {
            return .string(content)
        }
        if let pathMiss = filePathMissEnvelope(tool: "read_file", input: input, resultObject: obj) {
            return pathMiss
        }
        if case .string(let error)? = obj["error"] {
            throw AutonomyGateError.toolDenied(reason: error)
        }
        return result
    }

    func impl_full_mac_list_dir(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let result = try await impl_local_connector_tool(tool: "list_dir", input: input, surface: surface)
        guard case .object(let obj) = result else { return result }
        if case .array(let entries)? = obj["entries"] {
            return .array(entries)
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
