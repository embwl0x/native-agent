import MacNerves
import NativeAgentShared
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import MindCore
import ProviderRouting
import SenseCore
// Blueprint: | `FileActions+BuilderTools.swift` | `SwiftToolDispatcher`: `builderSourceRepoRoot`, `builderWorkspaceRoot`, `builderAllowedRoots`; workspace-default shell cwd and explicit pre-launch/executed receipts; certified shell reads use the Git reader's fixed argv/environment/sandbox; `builderLaunch`, the one way a command line starts (sandbox, starting folder, SwiftPM shim) for the shell tools and a part's program; builder and detached installer terminal audits run in SubprocessWork settlement |
protocol ShellCommandArgs: DoorArgs {
    var cmd: String { get }
    var cwd: String? { get }
    var timeoutSeconds: Int? { get }
}

protocol SwiftPackageArgs: DoorArgs {
    var packagePath: String? { get }
    var configuration: String? { get }
    var timeoutSeconds: Int? { get }
    var disableSwiftpmSandbox: Bool? { get }
    var jobs: Int? { get }
    var product: String? { get }
    var target: String? { get }
    var filter: String? { get }
}

extension SwiftPackageArgs {
    var product: String? { nil }
    var target: String? { nil }
    var filter: String? { nil }
}

struct ShellArgs: ShellCommandArgs {
    static let cmdField = DoorFieldDescriptor.string("cmd", "Required. The shell command line. Passed as -c argument to /bin/sh.", required: true)
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Existing directory; defaults to your workspace and resolves relative paths there. Use explicit cwd for the source \
        checkout. Active Full Mac may select an ordinary absolute external project; sensitive authority and protected \
        system paths remain denied.
        """)
    static let timeoutSecondsField = DoorFieldDescriptor.int("timeout_seconds", "Optional. Default 120, max 600. Subprocess group gets SIGTERM then SIGKILL after 2s.")
    static let doorFields = [cmdField, cwdField, timeoutSecondsField]
    let cmd: String
    let cwd: String?
    let timeoutSeconds: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        cmd = try door.requiredString(Self.cmdField)
        cwd = try door.string(Self.cwdField)
        timeoutSeconds = try door.numberLiteral(Self.timeoutSecondsField)?.wire.exactIntegerValue
    }
}

struct BashArgs: ShellCommandArgs {
    static let cmdField = DoorFieldDescriptor.string("cmd", "Required. The bash command line. Passed as -c argument to /bin/bash.", required: true)
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Existing directory; defaults to your workspace and resolves relative paths there. Use explicit cwd for the source \
        checkout. Active Full Mac may select an ordinary absolute external project; sensitive authority and protected \
        system paths remain denied.
        """)
    static let timeoutSecondsField = DoorFieldDescriptor.int("timeout_seconds", "Optional. Default 120, max 600.")
    static let doorFields = [cmdField, cwdField, timeoutSecondsField]
    let cmd: String
    let cwd: String?
    let timeoutSeconds: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        cmd = try door.requiredString(Self.cmdField)
        cwd = try door.string(Self.cwdField)
        timeoutSeconds = try door.numberLiteral(Self.timeoutSecondsField)?.wire.exactIntegerValue
    }
}

struct GitArgs: DoorArgs {
    static let argsField = DoorFieldDescriptor.strings("args", "Required exact argv, including empty arguments, e.g. ['status','--short'].", minItems: 1, required: true)
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. \
        Active Full Mac may select an ordinary absolute external project; sensitive authority and protected system paths \
        remain denied.
        """)
    static let timeoutSecondsField = DoorFieldDescriptor.int("timeout_seconds", "Optional. Default 60, max 600.")
    static let doorFields = [argsField, cwdField, timeoutSecondsField]
    let args: [String]
    let cwd: String?
    let timeoutSeconds: Int?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        args = try door.strings(Self.argsField)!
        cwd = try door.string(Self.cwdField)
        timeoutSeconds = try door.numberLiteral(Self.timeoutSecondsField)?.wire.exactIntegerValue
    }
}

struct SwiftBuildArgs: SwiftPackageArgs {
    static let packagePathField = DoorFieldDescriptor.string("package_path", """
        Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the \
        canonical workspace. Active Full Mac may select an ordinary external package directory.
        """)
    static let configurationField = DoorFieldDescriptor.choice("configuration", ["debug", "release"], "Optional. debug or release. Defaults to debug.")
    static let productField = DoorFieldDescriptor.string("product", "Optional product name to build. Mutually exclusive with target.")
    static let targetField = DoorFieldDescriptor.string("target", "Optional target name to build. Mutually exclusive with product.")
    static let jobsField = DoorFieldDescriptor.int("jobs", "Optional SwiftPM --jobs value, clamped 1...64.")
    static let timeoutSecondsField = DoorFieldDescriptor.int("timeout_seconds", "Optional. Default 600, max 3600.")
    static let disableSwiftpmSandboxField = DoorFieldDescriptor.bool("disable_swiftpm_sandbox", """
        Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot \
        nest). Leave it true; setting it false makes the build fail at manifest compile.
        """).nullable()
    static let doorFields = [packagePathField, configurationField, productField, targetField, jobsField, timeoutSecondsField, disableSwiftpmSandboxField]
    let packagePath: String?
    let configuration: String?
    let product: String?
    let target: String?
    let jobs: Int?
    let timeoutSeconds: Int?
    let disableSwiftpmSandbox: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        packagePath = try door.string(Self.packagePathField)
        configuration = try door.string(Self.configurationField)
        product = try door.string(Self.productField)
        target = try door.string(Self.targetField)
        jobs = try door.numberLiteral(Self.jobsField)?.wire.exactIntegerValue
        timeoutSeconds = try door.numberLiteral(Self.timeoutSecondsField)?.wire.exactIntegerValue
        disableSwiftpmSandbox = try door.bool(Self.disableSwiftpmSandboxField)
    }
}

struct SwiftTestArgs: SwiftPackageArgs {
    static let packagePathField = DoorFieldDescriptor.string("package_path", """
        Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the \
        canonical workspace. Active Full Mac may select an ordinary external package directory.
        """)
    static let configurationField = DoorFieldDescriptor.choice("configuration", ["debug", "release"], "Optional. debug or release. Defaults to debug.")
    static let filterField = DoorFieldDescriptor.string("filter", "Optional SwiftPM --filter regex/specifier.")
    static let jobsField = DoorFieldDescriptor.int("jobs", "Optional SwiftPM --jobs value, clamped 1...64.")
    static let timeoutSecondsField = DoorFieldDescriptor.int("timeout_seconds", "Optional. Default 900, max 3600.")
    static let disableSwiftpmSandboxField = DoorFieldDescriptor.bool("disable_swiftpm_sandbox", """
        Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot \
        nest). Leave it true; setting it false makes the build fail at manifest compile.
        """).nullable()
    static let doorFields = [packagePathField, configurationField, filterField, jobsField, timeoutSecondsField, disableSwiftpmSandboxField]
    let packagePath: String?
    let configuration: String?
    let filter: String?
    let jobs: Int?
    let timeoutSeconds: Int?
    let disableSwiftpmSandbox: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        packagePath = try door.string(Self.packagePathField)
        configuration = try door.string(Self.configurationField)
        filter = try door.string(Self.filterField)
        jobs = try door.numberLiteral(Self.jobsField)?.wire.exactIntegerValue
        timeoutSeconds = try door.numberLiteral(Self.timeoutSecondsField)?.wire.exactIntegerValue
        disableSwiftpmSandbox = try door.bool(Self.disableSwiftpmSandboxField)
    }
}

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
    static func builderResolveCwd(_ raw: String?, dataRoot: URL, workspaceDefault: Bool = false) -> String {
        if let raw {
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
    static func builderResolveTimeout(_ seconds: Int?, defaultSeconds: Int, maxSeconds: Int) -> Int {
        seconds.map { max(1, min(maxSeconds, $0)) } ?? defaultSeconds
    }
    private static func swiftPMResolvedConfiguration(
        _ configuration: String?,
        tool: String
    ) -> (configuration: String?, failure: JSONValue?) {
        let raw = configuration.flatMap { JSONValue.string($0).trimmedString } ?? "debug"
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
    static func impl_shell(turn: Turn, input: some ShellCommandArgs, dataRoot: URL = PersistenceCore.defaultDataRoot(),
                           executable: String = "/bin/sh", toolName: String = "shell") async -> JSONValue {
        let cmd = input.cmd
        guard !cmd.isEmpty else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string(toolName),
                "reason": .string("missing_cmd"),
                "execution": .string("not_run"),
                "detail": .string("Pass the command to run as cmd, a non-empty string."),
            ])
        }
        let cwd = builderResolveCwd(input.cwd, dataRoot: dataRoot, workspaceDefault: true)
        let timeout = builderResolveTimeout(input.timeoutSeconds, defaultSeconds: 120, maxSeconds: 600)
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
    static func impl_git(turn: Turn, input: GitArgs, dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let parsedArgs = input.args
        if parsedArgs.isEmpty {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "tool": .string("git"),
                "reason": .string("empty_args"),
                "fix": .string("Pass at least one git subcommand, e.g. [\"status\", \"--short\"]."),
            ])
        }
        let cwd = builderResolveCwd(input.cwd, dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input.timeoutSeconds, defaultSeconds: 60, maxSeconds: 600)
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
    static func impl_swift_package(turn: Turn, command: String, input: some SwiftPackageArgs,
        dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> JSONValue {
        let tool = "swift_\(command)"
        let packagePath = input.packagePath.flatMap { JSONValue.string($0).trimmedString } ?? builderDefaultCwd(dataRoot: dataRoot)
        let timeout = builderResolveTimeout(input.timeoutSeconds, defaultSeconds: command == "build" ? 600 : 900, maxSeconds: 3600)
        let resolvedConfiguration = swiftPMResolvedConfiguration(input.configuration, tool: tool)
        if let failure = resolvedConfiguration.failure {
            return failure
        }
        let configuration = resolvedConfiguration.configuration ?? "debug"
        var selectors: [String] = []
        if command == "build" {
            let product = input.product.flatMap { JSONValue.string($0).trimmedString }
            let target = input.target.flatMap { JSONValue.string($0).trimmedString }
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
        } else if let filter = input.filter.flatMap({ JSONValue.string($0).trimmedString }) {
            selectors += ["--filter", filter]
        }
        var args = ["swift", command]
        if input.disableSwiftpmSandbox ?? true {
            args.append("--disable-sandbox")
        }
        args += ["--package-path", packagePath, "--configuration", configuration]
        if let requested = input.jobs {
            let jobs = max(1, min(64, requested))
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
