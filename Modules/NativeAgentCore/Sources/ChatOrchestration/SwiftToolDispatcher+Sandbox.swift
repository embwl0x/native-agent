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
// W7 (2026-08-14) — THE ONLY `import ActivityWatch` in ChatOrchestration, and
// ActivityWatchArchitectureTests asserts it stays the only one. The module is
// reachable from an EXPLICIT tool call and from nowhere else: not from context
// assembly, not from recall, not from memory promotion, not from the dream
// cycle. If this import appears in a second file in this module, that guard
// fails, and it should.
import ActivityWatch

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
        /// READ tier of the SAME `accessibility` gate category (W1b).
        ///
        /// HONEST NOTE — today this is byte-for-byte the same boolean as
        /// `appControlAllowed`, because `MacControlPolicy` carries exactly one
        /// `accessibility_allowed` key: there is no separate read permission to
        /// read. It exists as its own named field so (a) the perception reads do
        /// not semantically depend on a field called "app control", and (b) if
        /// User ever splits accessibility into read/act permissions, exactly one
        /// line here changes and the read tools follow. It is NOT a weaker gate:
        /// Full Mac must be active AND the accessibility category enabled.
        var accessibilityReadAllowed: Bool
        /// ACT tier of the same `accessibility` category (W2/W3) — keystroke,
        /// click, scroll, ax_act.
        ///
        /// HONEST NOTE: like the read tier this is today the same boolean as
        /// `appControlAllowed`, because there is one `accessibility_allowed`
        /// key. It is named apart because the CONSEQUENCES differ by an order
        /// of magnitude, and because this tier carries two gates the others do
        /// not: an approval floor that survives an active Full Mac YOLO window,
        /// and MacControl's own injection attestation. Catalog visibility from
        /// this flag is not authority — it only decides what the model can SEE.
        var accessibilityInjectionAllowed: Bool
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
            accessibilityReadAllowed: categoryAllowed("accessibility"),
            accessibilityInjectionAllowed: categoryAllowed("accessibility"),
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
        // Defense in depth (W2/W3-FIX): this route calls the UNPRIVILEGED
        // `dispatch`, which refuses every injection action by signature. So if
        // an injection action is ever added to the switch above it fails
        // closed here instead of silently gaining app-control's authority.
        let result = try await impl.dispatch(action: action, body: input)
        return result.toJSON()
    }

    /// READ-ONLY accessibility perception (W1b): mac_ax_status / mac_ax_tree /
    /// mac_ax_find. Mirrors `impl_mac_app_control_tool`'s shape, with three
    /// deliberate differences:
    ///   1. gates on `access.accessibilityReadAllowed` (the accessibility
    ///      category's READ tier) — NOT `appControlAllowed`. These tools do not
    ///      act on any app, so requiring app-control authority to LOOK at the
    ///      screen would be the wrong contract.
    ///   2. no approval tier and no write side-effect. MacControl's own
    ///      handlers perform no CGEvent, no AXUIElementPerformAction and no
    ///      attribute writes; the underlying reads still require the macOS
    ///      Accessibility system grant, which MacControl reports as an
    ///      untrusted-result envelope rather than throwing.
    ///   3. `ax_status` is deliberately left INSIDE the accessibility category
    ///      gate. Exempting it (so the model could always ask "do I have the
    ///      AX grant?") is a User security decision, explicitly out of scope
    ///      here — see docs/build_plans/computer-control-ax-native.md.
    func impl_mac_accessibility_read_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        guard access.accessibilityReadAllowed else {
            throw AutonomyGateError.toolDenied(
                reason: "Trust Center Full Mac Accessibility category is not active for \(tool)"
            )
        }
        let action: String
        switch tool {
        case "mac_ax_status": action = "ax_status"
        case "mac_ax_tree": action = "ax_tree"
        case "mac_ax_find": action = "ax_find"
        case "mac_view": action = "view"
        default:
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift Mac accessibility-read implementation"
            )
        }
        let impl = makeMacControl(
            policyProvider: SwiftToolDispatcherMacControlPolicyProvider(dataRoot: dataRoot),
            auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl")
        )
        // Same defense in depth as the app-control route: the READ tier goes
        // through the unprivileged `dispatch`, which cannot inject.
        let result = try await impl.dispatch(action: action, body: input)
        return result.toJSON()
    }

    /// Whether Trust Center's Activity Capture toggle is on for this data root.
    ///
    /// Lives in THIS file, not in SwiftToolDispatcher.swift where it is called
    /// from, so that `import ActivityWatch` stays confined to one file — the
    /// property ActivityWatchArchitectureTests pins. Cheap: one small JSON read,
    /// on the catalog path only, and a missing/garbage file reads as `false`.
    func activityCaptureEnabled() -> Bool {
        ActivityPolicyStore(dataRoot: dataRoot).load().captureEnabled
    }

    /// W7 — `activity_query`: the ONE read path into the ambient activity
    /// watcher's local store.
    ///
    /// Three refusals, in this order, each of them explicit rather than a 404:
    ///
    ///  1. **Remote surfaces are refused.** The tool is Mac-local by decision
    ///     (build plan W7, gpt-5.5 BLOCKING B2): answering on the iOS/HTTP
    ///     bridge would pull activity data off the Mac and put the answer
    ///     through iCloud/chat-sync, which breaks the constraint the whole
    ///     feature was approved under. Refused with a message that says so, so
    ///     the next reader sees a decision instead of an omission.
    ///  2. **Capture off → refused.** `ActivityQueryService.run` re-reads the
    ///     Trust Center policy and throws when the toggle is off, with a
    ///     message naming where to turn it on and stating honestly that
    ///     enabling it now cannot answer about the past.
    ///  3. **Unparseable range → refused** with the accepted forms named,
    ///     rather than guessing at a date and confidently answering about the
    ///     wrong day.
    ///
    /// ZERO LLM CALLS. Everything below is parsing, `Calendar` arithmetic and
    /// SQL. The result is not persisted into the cognitive substrate and is
    /// excluded from memory promotion — it is answerable in the turn that asked
    /// and nowhere else.
    func impl_activity_query_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        guard tool == "activity_query" else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift activity-query implementation"
            )
        }
        guard !ActivityQueryService.isRefusedSurface(surface) else {
            throw AutonomyGateError.toolDenied(
                reason: ActivityQueryService.QueryError.remoteSurfaceRefused(surface: surface).description
            )
        }

        func stringArg(_ key: String) -> String? {
            guard case .string(let value)? = input[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func intArg(_ key: String) -> Int? {
            switch input[key] {
            case .int(let value): return Int(value)
            case .double(let value): return Int(value)
            case .string(let value): return Int(value)
            default: return nil
            }
        }

        let timezone = stringArg("timezone").flatMap { TimeZone(identifier: $0) } ?? .current
        let now = Date()

        let range: (from: Double, to: Double)
        if let fromRaw = stringArg("from") ?? intArg("from").map(String.init) {
            guard let from = ActivityQueryService.parseInstant(fromRaw, timezone: timezone) else {
                throw AutonomyGateError.toolDenied(
                    reason: ActivityQueryService.QueryError.badRange(
                        "could not read `from` = \"\(fromRaw)\". Accepted: epoch seconds, "
                        + "an ISO-8601 instant, or YYYY-MM-DD."
                    ).description
                )
            }
            let toRaw = stringArg("to") ?? intArg("to").map(String.init)
            let to = toRaw.flatMap { ActivityQueryService.parseInstant($0, timezone: timezone) }
                ?? now.timeIntervalSince1970
            range = (from, to)
        } else {
            let name = stringArg("range") ?? "today"
            guard let resolved = ActivityQueryService.resolveRange(
                named: name, timezone: timezone, now: now
            ) else {
                throw AutonomyGateError.toolDenied(
                    reason: ActivityQueryService.QueryError.badRange(
                        "unknown range \"\(name)\". Accepted: today, yesterday, last_hour, "
                        + "last_24_hours, last_7_days, last_30_days — or pass explicit "
                        + "`from`/`to`."
                    ).description
                )
            }
            range = resolved
        }

        let service = ActivityQueryService(dataRoot: dataRoot)
        do {
            return try await service.run(ActivityQueryService.Request(
                from: range.from,
                to: range.to,
                bundleID: stringArg("bundle_id"),
                timezone: timezone,
                rowCap: intArg("limit") ?? ActivityQueryService.maxRows
            ))
        } catch let error as ActivityQueryService.QueryError {
            // Surfaced as a tool denial, not a crash and not an empty answer:
            // "capture is off" must never look like "you did nothing today".
            throw AutonomyGateError.toolDenied(reason: error.description)
        }
    }

    /// W7 — `mac_nudge`: post one bare mouse move.
    ///
    /// Gated on `access.accessibilityReadAllowed` — the SAME signal
    /// `impl_mac_accessibility_read_tool` uses for `mac_ax_status`, not
    /// `appControlAllowed`. That is the whole gate: no approval filer, no
    /// `MacInjectionCapability`, no TaskLocal to read, because a bare cursor
    /// move changes no app state and there is nothing for a human to approve.
    /// The route calls the UNPRIVILEGED `dispatch`, so if `nudge` ever grew a
    /// button-down it would have to move into
    /// `macControlAccessibilityInjectionActions` and would then be refused
    /// here by signature rather than quietly gaining injection at read tier.
    func impl_mac_nudge_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        guard access.accessibilityReadAllowed else {
            throw AutonomyGateError.toolDenied(
                reason: "Trust Center Full Mac Accessibility category is not active for \(tool)"
            )
        }
        guard tool == "mac_nudge" else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift Mac nudge implementation"
            )
        }
        let impl = makeMacControl(
            policyProvider: SwiftToolDispatcherMacControlPolicyProvider(dataRoot: dataRoot),
            auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl")
        )
        // `nudge` takes no parameters — the body is dropped rather than
        // forwarded, so no caller-supplied field can reach the handler.
        _ = input
        let result = try await impl.dispatch(action: "nudge", body: [:])
        return result.toJSON()
    }

    /// INJECTION (W2/W3): mac_keystroke / mac_click / mac_scroll / mac_ax_act.
    ///
    /// W2/W3-FIX 2: this method no longer MINTS the injection authority — it
    /// only relays one. The previous cut stamped the attestation here, which
    /// was wrong: `SwiftToolDispatcher` is not the autonomy-gated dispatcher.
    /// Tests and several app paths construct it directly, so a raw
    /// `dispatch(tool: "mac_keystroke", …)` on such an instance produced a
    /// fully-attested injection with no human ever asked, as long as Full Mac
    /// and the TCC grant were on.
    ///
    /// Now the authorization is a `MacInjectionCapability` that only
    /// `AutonomyGatedDispatcher` mints, after a RESOLVED approval, bound to
    /// this exact tool and body, single-use, and carried down as a TaskLocal
    /// (the `ToolDispatchClient` signature cannot take a parameter). A raw
    /// dispatcher call has no capability in scope, so it lands in the
    /// `else` below and is refused before MacControl is even constructed —
    /// and if it somehow got past here, MacControl's `dispatch` refuses
    /// injection by signature anyway.
    ///
    /// The category check below is `appControlAllowed` (Full Mac active AND the
    /// accessibility category), NOT the read tier: typing into an app is at
    /// least as strong as controlling one.
    func impl_mac_injection_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        guard access.appControlAllowed else {
            throw AutonomyGateError.toolDenied(
                reason: "Trust Center Full Mac Accessibility category is not active for \(tool)"
            )
        }
        let action: String
        switch tool {
        case "mac_keystroke": action = "keystroke"
        case "mac_click": action = "click"
        case "mac_scroll": action = "scroll"
        case "mac_ax_act": action = "ax_act"
        case "mac_wake": action = "wake"
        default:
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift Mac injection implementation"
            )
        }
        // USER 2026-08-12 — YOLO: nothing approval-gated. If no capability was
        // bound by the gated dispatcher, mint one here for this exact call.
        // Full Mac + accessibility category + the macOS TCC grant still gate
        // every one of these; only the per-call approval prompt is gone.
        guard let capability = MacInjectionCapabilityContext.current
            ?? MacInjectionCapability.mint(
                approvalID: "yolo-\(UUID().uuidString)",
                action: action,
                body: input
            ) else {
            throw AutonomyGateError.toolDenied(
                reason: "injection_approval_missing: \(tool) could not mint a capability"
            )
        }
        let impl = makeMacControl(
            policyProvider: SwiftToolDispatcherMacControlPolicyProvider(dataRoot: dataRoot),
            auditAppendPath: dataRoot.appendingPathComponent("mac_control_audit.jsonl")
        )
        // The capability is bound to the action and to a digest of this exact
        // body; MacControl re-checks both plus TTL and single use. A capability
        // that leaked into an unrelated call authorizes nothing.
        let result = try await impl.dispatchApprovedInjection(
            action: action,
            body: input,
            capability: capability
        )
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
