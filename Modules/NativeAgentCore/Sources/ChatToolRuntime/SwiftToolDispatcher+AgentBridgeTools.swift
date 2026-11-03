import AgentWorkspace
import Foundation
import NativeAgentShared
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Desk
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import MacIntegration
import ToolRegistry
// Blueprint: | `SwiftToolDispatcher+AgentBridgeTools.swift` | `SwiftToolDispatcher`: driven-agent launch admission, executable rebinding, cwd authority and wake-helper execution |

/// SecurityCenter's launch decision for the real origin and re-verified approved program.
enum DrivenAgentLaunch: Sendable {
    struct Program: Sendable {
        let permission: DrivenAgentLaunchPermission
        let executable: String
        let arguments: [String]
        var receipt: JSONValue {
            .object(["permission": .string(permission == .fullMac ? "full_mac" : "restricted")])
        }
    }
    case admitted(Program)
    case refused(JSONValue)

    static func refusal(_ reason: String, remedy: JSONValue? = nil) -> Self {
        var result: [String: JSONValue] = ["status": .string("failed"), "reason": .string("launch_blocked"),
            "sent": .bool(false), "ran": .bool(false), "completed": .bool(false),
            "detail": .string("Nothing was launched: \(reason).")]
        if let remedy { result["remedy"] = remedy }
        return .refused(.object(result))
    }

    var receipt: JSONValue {
        switch self {
        case .admitted(let program): return program.receipt
        case .refused(let result): return result
        }
    }
}

extension SwiftToolDispatcher {

    /// `contact` carries the approved program's receipt: the contact itself
    /// for agent_message, otherwise the connected contact for that agent.
    static func drivenAgentLaunch(surface: String, contact: AgentPeerContact?,
                                  name: String, dataRoot: URL) async -> DrivenAgentLaunch {
        let origin = SecurityOriginContext.currentTurn(
            verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface)
        let permission = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .drivenAgentLaunchPermission(origin: origin)
        if case .denied(let reason) = permission { return .refusal(reason) }
        // Rebinding follows the installation without changing the launch's authority.
        let store = AgentPeerStore(dataRoot: dataRoot)
        var problem = "\(name)'s installed executable could not be bound to its contact"
        do {
            if let contact, let current = try store.list().first(where: { $0.id == contact.id }),
               let row = AgentPeerStore.hostRowID(current.endpoint).flatMap(AgentHostDirectory.row(named:)),
               let line = row.commandLine, let installed = row.resolveExecutable(line.executable) {
                if installed != current.verifiedExecutablePath {
                    guard try store.approveExecutable(peerID: current.id, path: installed) else {
                        throw AgentCommunicationError.invalid("the contact was disconnected")
                    }
                }
                if let path = try store.list().first(where: { $0.id == current.id })?.verifiedExecutablePath {
                    return .admitted(.init(permission: permission, executable: path,
                        arguments: line.permissionFlags.map(permission.arguments) ?? []))
                }
            }
        } catch {
            problem = "\(name)'s executable binding could not be reconciled: \(error.localizedDescription)"
        }
        return .refusal(problem,
            remedy: Repair.remedy(owner: "agents/peers.json peer:" + (contact?.id ?? name),
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.connect"),
                    "args": .object(["name": .string(contact.map { "peer:" + $0.id } ?? name)])])]), tap: nil))
    }

    /// The connected contact for a known command-line agent ("codex", "claude-code").
    static func drivenAgentContact(host: String, dataRoot: URL) -> AgentPeerContact? {
        (try? AgentPeerStore(dataRoot: dataRoot).list())?.first {
            $0.transport == .mcpHost && AgentPeerStore.hostRowID($0.endpoint) == host
        }
    }

    /// Stamp delegated wakes with producer evidence; unstamped records remain uncertain.
    static func stampDelegationProducer(on payload: inout [String: JSONValue]) {
        payload["producerSchemaVersion"] = .int(1)
        // Delegated wakes retain the untrusted origin of the turn.
        if let taint = PeerDataTaint.current, taint.isTainted { payload["peerTainted"] = .string(taint.sourceDescription) }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "NativeAgentSourceRevision") as? String else {
            return
        }
        let revision = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard revision.count == 40, revision.allSatisfy({ $0.isHexDigit }) else { return }
        payload["producerSourceRevision"] = .string(revision)
    }

    /// Resolve an exact Desk handle or alias to the stable live handle, without inference.
    /// Drop stale references and return them unchanged for the receipt.
    func delegationDeskHandleDroppingStale(
        _ input: [String: JSONValue]
    ) async throws -> (handle: String?, dropped: String?) {
        guard let raw = input["desk_item"], raw != .null else { return (nil, nil) }
        guard case .string(let value) = raw else {
            throw AutonomyGateError.toolDenied(reason: "delegation: desk_item must be a string")
        }
        let reference = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty and sentinel values omit the Desk binding.
        let noItem: Set<String> = ["", "none", "null", "nil", "no", "n/a", "na", "-"]
        if noItem.contains(reference.lowercased()) { return (nil, nil) }
        let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
        guard let item = state.items.first(where: {
            $0.handle == reference || $0.alias == reference
        }) else {
            return (nil, value)
        }
        return (item.handle, nil)
    }
    /// Bound recent prompt/reply audits; session pointers are not audits.
    /// Remove a last-message sidecar only with its matching evicted audit.
    static let agentBridgeAuditRetention = 100
    private static let agentBridgeAuditLock = NSLock()

    static func trimAgentBridgeAudits(in directory: URL) {
        agentBridgeAuditLock.lock()
        defer { agentBridgeAuditLock.unlock() }
        let fm = FileManager.default
        let audits = ((try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { file in
            file.pathExtension == "json"
                && SubprocessWork.retained(at: file.path) == nil
                && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }
        guard audits.count > agentBridgeAuditRetention else { return }
        for file in audits.prefix(audits.count - agentBridgeAuditRetention) {
            try? fm.removeItem(at: file)
            guard !fm.fileExists(atPath: file.path) else { continue }
            let runID = file.deletingPathExtension().lastPathComponent
            let lastMessage = directory.appendingPathComponent("\(runID)-last-message.txt")
            try? fm.removeItem(at: lastMessage)
        }
    }
    /// A relative folder belongs to the contact's workspace, never the app's process cwd.
    static func builderInvokeWorkingDirectory(input: [String: JSONValue], dataRoot: URL) throws -> String {
        let contact = try AgentPeerStore(dataRoot: dataRoot).list().first {
            ["codex", "codex-cli"].contains(AgentPeerStore.hostRowID($0.endpoint) ?? "")
        }
        let root = contact.flatMap { $0.acpWorkingDirectory ?? $0.hostWorkspace }.map { URL(fileURLWithPath: $0) }
            ?? builderSourceRepoRoot(dataRoot: dataRoot) ?? builderWorkspaceRoot(dataRoot: dataRoot)
        let raw: String
        if let value = input["cwd"], value != .null {
            guard case .string(let value) = value else {
                throw ToolRegistryError.invalidRequest("Pass cwd as an existing folder. Codex's workspace root is \(root.path).")
            }
            raw = NativeAgentWorkspaceRoot.fileSpelling(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { raw = "" }
        let folder = (raw.isEmpty ? root : raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw))
            .standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else {
            throw ToolRegistryError.invalidRequest("Codex's working folder does not exist: \(folder.path). Use its workspace root \(root.path) or an existing folder inside it.")
        }
        return folder.path
    }

    static func stringField(_ name: String, in value: JSONValue) -> String? {
        guard case .object(let object) = value, case .string(let string)? = object[name] else { return nil }
        return string
    }

    struct BridgeArgumentRefusal: Error {
        let value: JSONValue
    }

    static func pairReviewerRequested(
        in input: [String: JSONValue]
    ) -> Result<Bool, BridgeArgumentRefusal> {
        guard let value = input["pair_reviewer"], value != .null else { return .success(false) }
        guard case .bool(let requested) = value else {
            return .failure(BridgeArgumentRefusal(value: .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("invalid_pair_reviewer"),
                "fix": .string("pair_reviewer must be true or false."),
            ])))
        }
        return .success(requested)
    }

    /// Admit only bare owner/name GitHub slugs, never filesystem or traversal syntax.
    static func isWellFormedRepositorySlug(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 140 else { return false }
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("..") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._"
        )
        for part in parts {
            guard !part.isEmpty, part.count <= 100 else { return false }
            guard part.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return true
    }

    /// Working-directory admission supplies an optional path or an explicit refusal.
    enum AgentBridgeWorkingDirectoryResolution {
        case success(String?)
        case failure(JSONValue)
    }

    /// Admit canonical workspace/source roots at the shell tools' effect-time Trust boundary.
    /// External directories require Full Mac file authority and explicit outside-workspace allow.
    func resolveAgentBridgeWorkingDirectory(
        input: [String: JSONValue],
        surface: String
    ) async -> AgentBridgeWorkingDirectoryResolution {
        guard let value = input["working_directory"], value != .null else {
            return .success(nil)
        }
        guard case .string(let raw) = value else {
            return .failure(.object(["status": .string("failed"), "effects": .string("none"),
                "reason": .string("invalid_working_directory"),
                "detail": .string("working_directory must be an existing absolute project directory.")]))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty cwd requests no path; a non-empty invalid path still fails closed.
        guard !trimmed.isEmpty else { return .success(nil) }
        let directory = Self.builderNormalizeCwd(trimmed, dataRoot: dataRoot)
        guard let rejection = directory.rejection else { return .success(directory.path) }
        var fields: [String: JSONValue] = [
            "status": .string("failed"), "reason": .string(rejection),
            "workingDirectory": .string(directory.path), "detail": .string(directory.detail!),
        ]
        if rejection == "working_directory_outside_workspace_denied" {
            let access: FullMacToolAccess
            do { access = try await fullMacToolAccess(surface: surface) }
            catch { return .failure(ChatToolOutcome.failure(error: error)) }
            if access.fullMacActive, access.fileOpsAllowed,
               Self.builderYoloPermissionLevels.contains(access.permissionLevel),
               access.outsideWorkspaceDefault == "allow" { return .success(directory.path) }
            fields["workspaceRoot"] = .string(Self.builderWorkspaceRoot(dataRoot: dataRoot).path)
        }
        return .failure(.object(fields))
    }

    var builderWorktreeConfigRoot: URL {
        agentBridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot
    }

    static func builderWorktreeFailureEnvelope(
        reason: String,
        detail: String
    ) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string(reason),
            "detail": .string(detail),
            "fix": .string("Repair the selected Git checkout or its isolated worktree, then retry the builder message."),
        ])
    }

    static func bridgeConfigDirectory(named name: String, configRootOverride: URL? = nil) -> URL {
        (configRootOverride ?? InstallPaths.current.bridgeConfigRoot)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func returnBridgeUnavailableEnvelope(
        _ readiness: AgentBridgeRuntime.ReturnPathReadiness
    ) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string("return_bridge_unavailable"),
            "detail": .string(readiness.reason),
            "return_path_ready": .bool(false),
            "token_present": .bool(readiness.tokenPresent),
            "descriptor_present": .bool(readiness.descriptorPresent),
            "fix": .string("Keep NativeAgent open and retry. The authenticated local return bridge starts automatically; Developer Mode is not required."),
        ])
    }

    func postBuilderThreadWakeup(name: String, surface: String, payload: [String: JSONValue]) async -> JSONValue {
        let cli = name.lowercased()
        let disabledVariable = "NATIVE_AGENT_\(cli.uppercased())_WAKEUP_DISABLED"
        let disabled = ProcessInfo.processInfo.environment[disabledVariable]?.lowercased()
        if ["1", "true", "yes"].contains(disabled ?? "") {
            return .object([
                "status": .string("skipped"), "reason": .string("disabled_by_environment"),
                "env": .string(disabledVariable),
            ])
        }
        let helperName = "\(cli)_thread_wakeup.js"
        guard let helper = AgentBridgeRuntime.helperURL(named: helperName, dataRoot: dataRoot) else {
            return .object([
                "status": .string("skipped"), "reason": .string("helper_not_found"),
                "expected": .string(AgentBridgeRuntime.expectedHelperPath(named: helperName, dataRoot: dataRoot).path),
                "remedy": Self.builderFailureRemedy(owner: "NativeAgent app bundle / \(helperName)",
                    instruction: "The bundled \(name) wake helper is missing."),
            ])
        }
        let inputData: Data
        do {
            inputData = try JSONValue.object(payload).serializedData(pretty: false)
        } catch {
            return .object(Self.builderFailureFields(error,
                tool: "\(cli)_message", reason: "wakeup_payload_encode_failed", effects: .none,
                owner: "\(name) wake payload encoding",
                instruction: "Repair the reported payload encoding error. The inbox message is saved; this wake did not launch."))
        }
        var launch: DrivenAgentLaunch?
        var arguments: [String] = []
        if cli == "codex" {
            let decision = await Self.drivenAgentLaunch(surface: surface,
                contact: Self.drivenAgentContact(host: "codex", dataRoot: dataRoot), name: "Codex", dataRoot: dataRoot)
            switch decision {
            case .refused(let refusal): return refusal
            case .admitted(let program):
                launch = decision
                arguments = ["--sandbox", program.permission.codexSandbox, "--approval-policy", program.permission.codexApprovalPolicy]
            }
        }
        let cwd = Self.builderSourceRepoRoot(dataRoot: dataRoot) ?? NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
        return await runAgentWakeupHelper(helper: helper, inputData: inputData, cwd: cwd,
            cli: cli, variable: cli == "codex" ? "CODEX_BIN" : "NATIVE_AGENT_OMP_WAKE_BIN",
            timeout: cli == "codex" ? Self.codexWakeupHelperTimeoutSeconds() : 30,
            launch: launch, launchArguments: arguments)
    }

    /// One wake-helper lifecycle: concurrent pipe drain, off-path stdin, bounded output and tree cancellation/timeout.
    /// Callers supply deadlines and finished launch arguments/environment; Full Mac runs only the approved file.
    func runAgentWakeupHelper(helper: URL, inputData: Data, cwd: URL,
                              cli: String, variable: String, timeout: TimeInterval,
                              launch: DrivenAgentLaunch? = nil, launchArguments: [String] = [],
                              launchEnvironment: [String: String] = [:]) async -> JSONValue {
        var environment = AgentBridgeRuntime.processEnvironment()
        environment["NATIVE_AGENT_DATA_ROOT"] = dataRoot.path
        environment.merge(InstallPaths.current.bridgeEnvironment(configRoot: builderWorktreeConfigRoot)) { _, path in path }
        guard let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else {
            var failure: [String: JSONValue] = [
                "status": .string("failed"), "effects": .string("none"), "reason": .string("node_runtime_not_found"), "helper": .string(helper.path),
            ]
            failure["fix"] = .string("Install Node.js, then restart NativeAgent.")
            return .object(failure)
        }
        environment.merge(launchEnvironment) { _, finished in finished }
        if case .admitted(let program)? = launch { environment[variable] = program.executable }
        if environment[variable] == nil {
            environment[variable] = AgentBridgeRuntime.executableURL(named: cli, environment: environment)?.path
        }
        var receipt = await AgentBridgeRuntime.runBuilderWakeupHelper(node: node, helper: helper, inputData: inputData,
                                                       cwd: cwd, environment: environment, timeoutSeconds: timeout,
                                                       arguments: launchArguments)
        if let launch, case .object(var fields) = receipt {
            fields["launch"] = launch.receipt
            receipt = .object(fields)
        }
        return receipt
    }

}
