import AgentWorkspace
import ChatToolParsing
import NativeAgentShared
import Darwin
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import TurnTrace
// Blueprint: | `SwiftToolDispatcher+BuilderTools.swift` | `SwiftToolDispatcher`: `builderSourceRepoRoot`, `builderWorkspaceRoot`, `builderAllowedRoots`; workspace-default shell cwd and explicit pre-launch/executed receipts; certified shell reads use the Git reader's fixed argv/environment/sandbox; `builderLaunch`, the one way a command line starts (sandbox, starting folder, SwiftPM shim) for the shell tools and a part's program; builder and detached installer terminal audits run in SubprocessWork settlement |
extension SwiftToolDispatcher {
    /// Preserve the owner's failure contract; add operation evidence only for errors that have not supplied a cause or recovery lever themselves.
    static func builderFailureFields(
        _ error: any Error, tool: String, reason: String, effects: ToolFailureError.Effects,
        owner: String, instruction: String
    ) -> [String: JSONValue] {
        let result = ChatToolOutcome.failure(error: error, tool: tool, effects: effects)
        var fields = result.objectValue!
        fields["tool"] = .string(tool)
        if fields["reason"] == .string("dispatch_error") {
            fields["reason"] = .string(reason)
            fields["failure_code"] = .string(reason)
            if !(error is ToolFailureError) {
                let cause = error as NSError
                fields["cause"] = .object(["domain": .string(cause.domain), "code": .int(Int64(cause.code))])
                fields["detail"] = .string(ChatToolOutcome.errorMessage(
                    ToolFailureError(error.localizedDescription, effects: effects)))
            }
        }
        if fields["remedy"] == nil {
            fields["remedy"] = builderFailureRemedy(owner: owner, instruction: instruction)
        }
        return fields
    }
    /// Report the owning failure directly; routing builder repair through another coding-agent call is circular.
    static func builderFailureRemedy(owner: String, instruction: String) -> JSONValue {
        Repair.remedy(owner: owner, nextCall: nil, tap: instruction, instruction: "Tell the person: \(owner). \(instruction)")
    }
    /// Conventional source checkout retained only as one validated candidate. Public installs do not need this path in order to execute ordinary work.
    static let nativeAgentRepoRoot: String =
        NSString(string: "~/Projects/NativeAgent").expandingTildeInPath
    package static func builderSourceRepoRoot(dataRoot: URL) -> URL? {
        if let injected = resolveSandboxRepoRoot(dataRoot: dataRoot) {
            return injected.standardizedFileURL.resolvingSymlinksInPath()
        }
        let conventional = URL(fileURLWithPath: nativeAgentRepoRoot)
            .standardizedFileURL
        return resolveSandboxRepoRoot(
            dataRoot: conventional.appendingPathComponent("data", isDirectory: true)
        )?.resolvingSymlinksInPath()
    }
    static func builderWorkspaceRoot(dataRoot: URL) -> URL {
        AgentHostConnection.builderWorkspaceRoot(dataRoot: dataRoot)
    }
    static func builderAllowedRoots(dataRoot: URL) -> [URL] {
        var roots = [builderWorkspaceRoot(dataRoot: dataRoot)]
        if let source = builderSourceRepoRoot(dataRoot: dataRoot),
           !roots.contains(where: { $0.path == source.path }) {
            roots.append(source)
        }
        return roots
    }
    // Resolve cwd validity and confinement; callers decide external-directory authority.
    static func builderNormalizeCwd(
        _ raw: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        allowOutsideWorkspace: Bool = false
    ) -> (path: String, rejection: String?, detail: String?) {
        let url = URL(fileURLWithPath: NativeAgentWorkspaceRoot.fileSpelling(raw))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolved = url.path
        var isDir: ObjCBool = false
        guard resolved.hasPrefix("/"), FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir),
              isDir.boolValue else {
            return (resolved, "working_directory_invalid", "working_directory must resolve to an existing absolute directory.")
        }
        for root in builderAllowedRoots(dataRoot: dataRoot) {
            if NativeAgentWorkspaceRoot.relativePath(resolved, under: root.path) != nil {
                return (resolved, nil, nil)
            }
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: resolved)
            ?? MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolved) {
            return (resolved, "working_directory_sensitive_path_denied", reason)
        }
        return allowOutsideWorkspace ? (resolved, nil, nil)
            : (resolved, "working_directory_outside_workspace_denied", """
                An external coding directory requires active Full Mac YOLO with outside-workspace access set to allow.
                """)
    }
    static func builderSourceCheckoutRequiredEnvelope(tool: String, dataRoot: URL) -> JSONValue {
        let runId = UUID().uuidString
        let now = NativeTimestampFormat.plainZulu(Date())
        let auditEntry: [String: Any] = [
            "toolName": tool,
            "runId": runId,
            "createdAt": now,
            "completedAt": now,
            "status": "failed_pre_spawn",
            "reason": "source_checkout_required",
            "workspace_root": builderWorkspaceRoot(dataRoot: dataRoot).path,
        ]
        let (auditURL, auditError) = builderWriteAudit(
            runId: runId,
            entry: auditEntry,
            dataRoot: dataRoot
        )
        var envelope: [String: JSONValue] = [
            "status": .string("failed"),
            "effects": .string("none"),
            "tool": .string(tool),
            "reason": .string("source_checkout_required"),
            "workspace_root": .string(builderWorkspaceRoot(dataRoot: dataRoot).path),
            "runId": .string(runId),
            "audit_path": .string(auditURL.path),
            "detail": .string(
                """
                    This NativeAgent self-maintenance operation requires a verified source checkout. Ordinary shell, bash, git, patch, and project \
                    work remain available inside the canonical workspace.
                    """
            ),
        ]
        if let auditError { envelope["audit_error"] = .string(auditError) }
        return .object(envelope)
    }
    static func builderFullMacRequiredEnvelope(tool: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "effects": .string("none"),
            "reason": .string("trust_center_full_mac_required"),
            "execution": .string("not_run"),
            "effect": .string("none"),
            "tool": .string(tool),
            "detail": .string(
                "Trust Center Full Mac file_ops_allowed must be active to run shell-class actions. Toggle Full Mac in the Trust Center."
            ),
        ])
    }
    /// macOS developer-tool shims open an interactive installer when tools are missing; readiness probes must not trigger UI. An absent DEVELOPER_DIR makes
    /// Apple shims fail immediately without affecting non-Apple tools; preserve explicit overrides and valid selected directories.
    static func builderEnvironmentSuppressingDeveloperToolsPrompt(
        environment: [String: String],
        selectedDeveloperDirectory: String?
    ) -> (environment: [String: String], suppressed: Bool) {
        if let explicit = environment["DEVELOPER_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return (environment, false)
        }
        if let selected = selectedDeveloperDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            return (environment, false)
        }
        var guarded = environment
        guarded["DEVELOPER_DIR"] = "/.nativeagent-no-developer-tools"
        return (guarded, true)
    }
    /// Use xcode-select --print-path for readiness because failure does not open Apple's installer.
    static func builderSelectedDeveloperDirectory(
        environment: [String: String]
    ) async -> String? {
        if let explicit = environment["DEVELOPER_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        guard let result = try? await ProcessExecution().run(
            executable: "/usr/bin/xcode-select", arguments: ["--print-path"],
            currentDirectory: nil, environment: environment, standardInput: nil, timeoutSeconds: nil
        ), result.exitCode == 0 else { return nil }
        let selected = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }
    /// Detect xcodebuild broadly by each token's last path component: a false positive is actionable, while a miss fails inside its non-nestable package
    /// sandbox.
    static func builderCommandInvokesXcodebuild(_ cmd: String) -> Bool {
        let separators: Set<Character> = [" ", "\t", "\n", "\r", ";", "|", "&", "(", ")", "`", "<", ">"]
        for token in cmd.split(whereSeparator: { separators.contains($0) }) {
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if (bare as NSString).lastPathComponent == "xcodebuild" { return true }
        }
        return false
    }
    /// Confined postures refuse xcodebuild because its package-resolution sandbox cannot nest.
    static func builderXcodebuildRefusalEnvelope(tool: String, cmd: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "effects": .string("none"),
            "tool": .string(tool),
            "reason": .string("xcodebuild_requires_full_mac_posture"),
            "execution": .string("not_run"),
            "effect": .string("none"),
            "sandboxed": .bool(true),
            "cmd": .string(cmd),
            "detail": .string(
                "xcodebuild resolves packages in its own sandbox; macOS blocks nested profiles "
                + "('sandbox_apply: Operation not permitted', exit 74), regardless of flags. "
                + "It has no sandbox exception: project build scripts can run arbitrary shell. "
                + "SwiftPM (`swift build`, `swift test`, `swift run`; swift.build / swift.test) remains available."
            ),
            "remedy": Repair.why(owner: "Trust posture", tap: "Trust Center → Full Mac",
                instruction: "The owner can select Full Mac in Trust Center to allow xcodebuild."),
        ])
    }
    /// The watchdog and its receipts share the same actual timeout bound.
    static func builderEffectiveTimeoutSeconds(_ requested: Int) -> Int {
        max(1, min(3600, requested))
    }
    private static func builderDefaultCwd(dataRoot: URL) -> String {
        builderSourceRepoRoot(dataRoot: dataRoot)?.path
            ?? builderWorkspaceRoot(dataRoot: dataRoot).path
    }
    static func builderResolveCwd(
        _ input: [String: JSONValue],
        dataRoot: URL,
        workspaceDefault: Bool = false
    ) -> String {
        if case .string(let raw)? = input["cwd"] {
            let cwd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty {
                if cwd.hasPrefix("/") || cwd.hasPrefix("~") { return cwd }
                let workspace = builderWorkspaceRoot(dataRoot: dataRoot)
                let workspaceAlias = NativeAgentWorkspaceRoot.normalizeWorkspaceAlias(cwd, workspaceRoot: workspace)
                if workspaceAlias != cwd { return workspaceAlias }
                if !workspaceDefault, let source = builderSourceRepoRoot(dataRoot: dataRoot) {
                    let sourceCandidate = source.appendingPathComponent(cwd).standardizedFileURL
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(
                        atPath: sourceCandidate.path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue {
                        return sourceCandidate.path
                    }
                }
                return workspace.appendingPathComponent(cwd).standardizedFileURL.path
            }
        }
        return workspaceDefault ? builderWorkspaceRoot(dataRoot: dataRoot).path : builderDefaultCwd(dataRoot: dataRoot)
    }
    static func builderResolveTimeout(
        _ input: [String: JSONValue], defaultSeconds: Int, maxSeconds: Int
    ) -> Int {
        if case .int(let i)? = input["timeout_seconds"] {
            return max(1, min(maxSeconds, Int(i)))
        }
        return defaultSeconds
    }
    static func builderResolveString(
        _ input: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if case .string(let raw)? = input[key] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
    static func builderResolveBool(
        _ input: [String: JSONValue],
        keys: [String],
        default defaultValue: Bool
    ) -> Bool {
        for key in keys {
            if case .bool(let value)? = input[key] {
                return value
            }
        }
        return defaultValue
    }
    private static func builderResolveJobs(_ input: [String: JSONValue]) -> Int? {
        guard case .int(let raw)? = input["jobs"] else { return nil }
        return max(1, min(64, Int(raw)))
    }
    private static func swiftPMResolvedConfiguration(
        _ input: [String: JSONValue],
        tool: String
    ) -> (configuration: String?, failure: JSONValue?) {
        let raw = builderResolveString(input, keys: ["configuration"]) ?? "debug"
        let normalized = raw.lowercased()
        switch normalized {
        case "debug", "release":
            return (normalized, nil)
        default:
            return (nil, .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string(tool),
                "reason": .string("invalid_configuration"),
                "detail": .string("configuration must be debug or release."),
                "configuration": .string(raw),
                "expected": .string("debug or release"),
            ]))
        }
    }
    private static func swiftPMResolvedPackagePath(
        _ input: [String: JSONValue],
        dataRoot: URL
    ) -> String {
        builderResolveString(input, keys: ["package_path"])
            ?? builderDefaultCwd(dataRoot: dataRoot)
    }
    static func impl_shell(turn: Turn, input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot(),
                           executable: String = "/bin/sh", toolName: String = "shell") async -> JSONValue {
        guard case .string(let cmd)? = input["cmd"], !cmd.isEmpty else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string(toolName),
                "reason": .string("missing_cmd"),
                "execution": .string("not_run"),
                "detail": .string("Pass the command to run as cmd, a non-empty string."),
            ])
        }
        let cwd = builderResolveCwd(input, dataRoot: dataRoot, workspaceDefault: true)
        let timeout = builderResolveTimeout(input, defaultSeconds: 120, maxSeconds: 600)
        // Refuse xcodebuild inside confinement because its package sandbox cannot nest; the caller needs the owning refusal.
        if builderCommandInvokesXcodebuild(cmd) {
            do {
                if try await builderShellSandboxMode(dataRoot: dataRoot) != .off {
                    return builderXcodebuildRefusalEnvelope(tool: toolName, cmd: cmd)
                }
            } catch { return ChatToolOutcome.failure(error: error, tool: toolName, effects: ToolFailureError.Effects.none) }
        }
        return await runShellLikeProcess(
            turn: turn,
            toolName: toolName,
            executable: executable,
            args: ["-c", cmd],
            cwd: cwd,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: cmd,
            dataRoot: dataRoot,
            exitIsAnswer: true
        )
    }
    static func impl_git(turn: Turn, input: [String: JSONValue], dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let parsedArgs: [String]
        switch input["args"] {
        case .array(let rawArgs)?:
            var args: [String] = []
            for v in rawArgs {
                if case .string(let s) = v { args.append(s) }
                else {
                    return .object([
                        "status": .string("failed"),
                        "effects": .string("none"),
                        "tool": .string("git"),
                        "reason": .string("args_must_be_string_array"),
                        "fix": .string("Pass args as [\"status\", \"--short\"]."),
                    ])
                }
            }
            parsedArgs = args
        default:
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string("git"),
                "reason": .string("args_must_be_string_array"),
                "fix": .string("Pass args as [\"status\", \"--short\"]."),
            ])
        }
        if parsedArgs.isEmpty {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string("git"),
                "reason": .string("empty_args"),
                "fix": .string("Pass at least one git subcommand, e.g. [\"status\", \"--short\"]."),
            ])
        }
        let cwd = builderResolveCwd(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: 60, maxSeconds: 600)
        return await runShellLikeProcess(
            turn: turn,
            toolName: "git",
            executable: "/usr/bin/env",
            args: ["git"] + parsedArgs,
            cwd: cwd,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: parsedArgs.joined(separator: " "),
            dataRoot: dataRoot
        )
    }
    static func impl_swift_package(turn: Turn, command: String, input: [String: JSONValue],
        dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let tool = "swift_\(command)"
        let packagePath = swiftPMResolvedPackagePath(input, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input, defaultSeconds: command == "build" ? 600 : 900, maxSeconds: 3600)
        let resolvedConfiguration = swiftPMResolvedConfiguration(input, tool: tool)
        if let failure = resolvedConfiguration.failure {
            return failure
        }
        let configuration = resolvedConfiguration.configuration ?? "debug"
        var selectors: [String] = []
        if command == "build" {
            let product = builderResolveString(input, keys: ["product"])
            let target = builderResolveString(input, keys: ["target"])
            if product != nil && target != nil {
                return .object([
                    "status": .string("failed"),
                    "effects": .string("none"),
                    "tool": .string(tool),
                    "reason": .string("product_and_target_are_mutually_exclusive"),
                    "detail": .string("Pass product or target, not both."),
                ])
            }
            if let product { selectors += ["--product", product] }
            if let target { selectors += ["--target", target] }
        } else if let filter = builderResolveString(input, keys: ["filter"]) {
            selectors += ["--filter", filter]
        }
        var args = ["swift", command]
        if builderResolveBool(input, keys: ["disable_swiftpm_sandbox"], default: true) {
            args.append("--disable-sandbox")
        }
        args += ["--package-path", packagePath, "--configuration", configuration]
        if let jobs = builderResolveJobs(input) {
            args += ["--jobs", "\(jobs)"]
        }
        args += selectors
        return await runShellLikeProcess(
            turn: turn,
            toolName: tool,
            executable: "/usr/bin/env",
            args: args,
            cwd: packagePath,
            timeoutSeconds: timeout,
            sourcePayloadForAudit: args.joined(separator: " "),
            dataRoot: dataRoot
        )
    }
}
