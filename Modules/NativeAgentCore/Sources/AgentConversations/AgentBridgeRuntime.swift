import Foundation
import CryptoKit
import PersistenceCore
import MacControl
import Darwin
import NativeAgentShared
// Blueprint: | `AgentBridgeRuntime.swift` | `AgentBridgeRuntime` enum; helper discovery and shared execution; wake-runner process identity; OMP reply-job recovery |

/// Discovery and helper execution for the external coding organs NativeAgent
/// may invoke. This owner does not authenticate, install software, grant
/// authority, or infer that a subprocess result is verified work.
public enum AgentBridgeRuntime {
    /// The same identity the wake runners record for themselves:
    /// sha256 hex of `ps -p <pid> -o lstart=,command=`, trimmed.
    public static func processStartIdentity(_ pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func startOMPReplyJobRecovery() async {
        let dataRoot = PersistenceCore.defaultDataRoot()
        guard AgentConversationDelivery.lane(for: "omp", dataRoot: dataRoot) != nil else { return }
        var environment = AgentBridgeRuntime.processEnvironment()
        environment["NATIVE_AGENT_DATA_ROOT"] = dataRoot.path
        let configRoot = InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        environment.merge(InstallPaths.current.bridgeEnvironment(configRoot: configRoot)) { existing, _ in existing }
        let directory = environment["NATIVE_AGENT_OMP_BRIDGE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? configRoot.appendingPathComponent("omp-bridge")
        let jobs = directory.appendingPathComponent("wake-jobs")
        guard FileManager.default.fileExists(atPath: jobs.path) else { return }
        guard let helper = AgentBridgeRuntime.ompHelperURL(dataRoot: dataRoot),
              let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else {
            nativeLog("[ClaudeBridge] OMP reply recovery requires node and %@",
                AgentBridgeRuntime.expectedHelperPath(named: "omp_thread_wakeup.js", dataRoot: dataRoot).path)
            return
        }
        do {
            for path in try FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)
                where path.pathExtension == "json" {
                try Task.checkCancellation()
                do {
                    guard case .object(let job) = try JSONValue.parse(Data(contentsOf: path)),
                          job["state"] == .string("settled") || job["state"] == .string("delivering"),
                          case .string(let text)? = job["completionText"], !text.isEmpty,
                          case .object(let payload)? = job["payload"] else { continue }
                    guard case .string(let messageID)? = job["messageId"], !messageID.isEmpty,
                          payload["messageId"] == .string(messageID) else { throw CocoaError(.fileReadCorruptFile) }
                    // The helper's existing topic lock and delivery identity own replay.
                    let input = try JSONValue.object(payload).serializedData(pretty: false)
                    let receipt = await runBuilderWakeupHelper(node: node, helper: helper, inputData: input,
                        cwd: dataRoot.deletingLastPathComponent(), environment: environment, timeoutSeconds: nil)
                    if case .object(let fields) = receipt {
                        if case .int(let status)? = fields["exitCode"], status != 0 {
                            nativeLog("[ClaudeBridge] OMP reply recovery for %@ exited %d", path.lastPathComponent, Int(status))
                        } else if fields["status"] == .string("failed") {
                            nativeLog("[ClaudeBridge] could not recover OMP reply %@: %@", path.lastPathComponent,
                                try receipt.serialize(pretty: false))
                        }
                    }
                } catch let error where error is CancellationError || error is ProcessRunCancellation { throw CancellationError() }
                catch {
                    nativeLog("[ClaudeBridge] OMP reply recovery for %@ failed: %@", path.lastPathComponent, error.localizedDescription)
                }
            }
        } catch { nativeLog("[ClaudeBridge] OMP reply-job scan failed: %@", error.localizedDescription) }
    }

    public static func runBuilderWakeupHelper(
        node: URL,
        helper: URL,
        inputData: Data,
        cwd: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval?,
        arguments: [String] = []
    ) async -> JSONValue {
        // Helpers address the agent and user by their configured names.
        var environment = environment
        if environment["NATIVE_AGENT_AGENT_NAME"] == nil || environment["NATIVE_AGENT_USER_NAME"] == nil {
            let names = AgentBridgeRuntime.configuredNames(dataRoot: PersistenceCore.defaultDataRoot())
            environment["NATIVE_AGENT_AGENT_NAME"] = environment["NATIVE_AGENT_AGENT_NAME"] ?? names.agent
            environment["NATIVE_AGENT_USER_NAME"] = environment["NATIVE_AGENT_USER_NAME"] ?? names.user
        }
        var inspectionArgs: [String: JSONValue] = [:]
        if case .object(let payload) = try? JSONValue.parse(inputData), case .string(let id)? = payload["messageId"] {
            inspectionArgs["message_id"] = .string(id)
        }
        let inspection: JSONValue = .object(["tool": .string("app"), "input": .object([
            "action": .string("agent.jobs"), "args": .object(inspectionArgs)])])
        let result: ProcessRunResult
        do {
            result = try await ProcessExecution().run(
                executable: node.path,
                arguments: [helper.path] + arguments,
                currentDirectory: cwd,
                environment: environment,
                standardInput: inputData,
                timeoutSeconds: timeoutSeconds,
                outputByteLimit: 8 * 1024 * 1024
            )
        } catch let error where error is CancellationError || error is ProcessRunCancellation {
            // Stop after launch: the helper's drained output is evidence, not a failure.
            return .object([
                "status": .string("cancelled"),
                "reason": .string("helper_cancelled"),
                "helper": .string(helper.path),
                "admissionOutcome": .string("unknown"),
                "effects": .string("unknown"),
                "detail": .string("The helper was cancelled; work admission is unconfirmed."),
                "remedy": Repair.reconcile(instruction: "Inspect the original message's job before any resend.", nextCall: inspection),
            ])
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_process_failed"),
                "helper": .string(helper.path),
                "admissionOutcome": .string("unknown"), "effects": .string("unknown"),
                "error": .string(String(describing: error)),
                "detail": .string("The helper process failed; work admission is unconfirmed."),
                "remedy": Repair.reconcile(instruction: "Inspect the original message's job before any resend.", nextCall: inspection),
            ])
        }

        return builderWakeupHelperReceipt(result: result, helper: helper, inspection: inspection)
    }

    /// Pure interpretation of the shared process owner's evidence. A helper
    /// exit code is never a substitute for its structured admission receipt.
    private static func builderWakeupHelperReceipt(result: ProcessRunResult, helper: URL, inspection: JSONValue) -> JSONValue {
        let stderrText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        func unavailable(_ reason: String, _ detail: String) -> JSONValue {
            var envelope: [String: JSONValue] = [
                "status": .string("failed"),
                "reason": .string(reason),
                "helper": .string(helper.path),
                "exitCode": .int(Int64(result.exitCode)),
                "admissionOutcome": .string("unknown"),
                "effects": .string("unknown"), "detail": .string(detail + " Work admission is unconfirmed."),
                "remedy": Repair.reconcile(instruction: "Inspect the original message's job before any resend.", nextCall: inspection),
            ]
            if !stderrText.isEmpty {
                envelope["stderrPreview"] = .string(String(stderrText.prefix(500)))
            }
            return .object(envelope)
        }
        if result.timedOut { return unavailable("helper_timeout", "The helper exceeded its execution deadline.") }
        if result.stdoutTruncated { return unavailable("helper_output_truncated", "The helper's output exceeded its byte limit.") }

        let stdoutText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = stdoutText.split(separator: "\n").last.map(String.init) ?? ""
        let parsed = [stdoutText, lastLine]
            .lazy
            .filter { !$0.isEmpty }
            .compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONValue.parse($0) }
            .first
        guard let parsed else { return unavailable("helper_returned_no_json", "The helper returned no JSON receipt.") }
        guard case .object(var object) = parsed,
              case .string(let status)? = object["status"],
              !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable("helper_invalid_receipt", "The helper receipt has no nonempty status.")
        }
        if result.exitCode != 0 && !["failed", "skipped"].contains(status) {
            guard case .object(var failure) = unavailable("helper_exit_conflict", "The helper's exit code contradicts its receipt.") else {
                return unavailable("helper_exit_conflict", "The helper's exit code contradicts its receipt.")
            }
            failure["helperReportedReceipt"] = parsed
            return .object(failure)
        }
        object["helper"] = .string(helper.path)
        object["exitCode"] = .int(Int64(result.exitCode))
        if !stderrText.isEmpty {
            object["stderrPreview"] = .string(String(stderrText.prefix(500)))
        }
        return .object(object)
    }

    public struct Readiness: Sendable, Equatable {
        public let helper: URL?
        public let runtime: URL?
        public let cli: URL?
        public let returnPath: ReturnPathReadiness

        public var readyToAttempt: Bool {
            helper != nil && runtime != nil && cli != nil
        }

        public var readyForAsyncRoundTrip: Bool {
            readyToAttempt && returnPath.isReady
        }
    }

    public struct ReturnPathReadiness: Sendable, Equatable {
        public let isReady: Bool
        public let reason: String
        public let tokenPresent: Bool
        public let descriptorPresent: Bool
        public let endpoint: URL?

        public init(
            isReady: Bool,
            reason: String,
            tokenPresent: Bool,
            descriptorPresent: Bool,
            endpoint: URL?
        ) {
            self.isReady = isReady
            self.reason = reason
            self.tokenPresent = tokenPresent
            self.descriptorPresent = descriptorPresent
            self.endpoint = endpoint
        }
    }

    public static func codexHelperURL(override: URL? = nil, dataRoot: URL) -> URL? {
        helperURL(named: "codex_thread_wakeup.js", override: override, dataRoot: dataRoot)
    }

    public static func ompHelperURL(override: URL? = nil, dataRoot: URL) -> URL? {
        helperURL(named: "omp_thread_wakeup.js", override: override, dataRoot: dataRoot)
    }

    /// The expected helper when it is a readable regular file, else nil (the
    /// caller reports `expectedHelperPath` in its helper_not_found receipt).
    public static func helperURL(
        named name: String,
        override: URL? = nil,
        dataRoot: URL,
        bundleResourceRoot: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        let path = expectedHelperPath(
            named: name, override: override, dataRoot: dataRoot, bundleResourceRoot: bundleResourceRoot)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: path.path),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return nil
        }
        return path
    }

    /// Where a wake helper lives: one path per build kind, no search. When the
    /// data root sits in a NativeAgent checkout (the REPO_PATH dev install, or
    /// a run from the repo) the checkout's `script/` is the helper, so edits
    /// apply without a rebuild. Any other install runs the copy shipped in the
    /// app's resource bundle. `override` is the dispatcher's injection seam.
    public static func expectedHelperPath(
        named name: String,
        override: URL? = nil,
        dataRoot: URL,
        bundleResourceRoot: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
    ) -> URL {
        if let override { return override.standardizedFileURL }
        if let checkout = resolveSandboxRepoRoot(dataRoot: dataRoot) {
            return checkout.appendingPathComponent("script/\(name)").standardizedFileURL
        }
        return bundledHelper(named: name, resourceRoot: bundleResourceRoot).standardizedFileURL
    }

    /// The configured agent and user names from the persona profile, for the
    /// wake helpers' prompts and receipts. Nothing shipped names a specific
    /// agent; an install without a profile yet gets "the agent" / "the user".
    public static func configuredNames(dataRoot: URL) -> (agent: String, user: String) {
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        var agent = "the agent", user = "the user"
        if let data = try? Data(contentsOf: path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let n = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { agent = n }
            if let n = (object["userName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { user = n }
        }
        return (agent, user)
    }

    public static func executableURL(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let override: String? = switch name {
        case "codex": environment["NATIVE_AGENT_CODEX_BIN"] ?? environment["CODEX_BIN"]
        case "claude": environment["NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN"]
        case "omp": environment["NATIVE_AGENT_OMP_WAKE_BIN"] ?? environment["OMP_BIN"]
        case "node": environment["NATIVE_AGENT_BRIDGE_NODE_BIN"]
        default: nil
        }

        let directories = (processEnvironment(base: environment, homeDirectory: homeDirectory)["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        var candidates = override.map { [URL(fileURLWithPath: $0)] } ?? []
        if name == "codex" {
            candidates.append(homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex"))
            candidates.append(homeDirectory.appendingPathComponent("Desktop/Codex.app/Contents/Resources/codex"))
            candidates.append(URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"))
        }
        candidates.append(contentsOf: unique(directories).map { $0.appendingPathComponent(name) })

        if name == "node" {
            let nvmVersions = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
            let versionDirectories = ((try? fileManager.contentsOfDirectory(
                at: nvmVersions,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
            candidates.append(contentsOf: versionDirectories.map { $0.appendingPathComponent("bin/node") })
        }
        return firstExecutable(candidates, fileManager: fileManager)
    }

    public static func readiness(
        helper: URL?,
        cliName: String,
        bridgeConfigRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Readiness {
        Readiness(
            helper: helper,
            runtime: executableURL(
                named: "node",
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            cli: executableURL(
                named: cliName,
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            returnPath: returnPathReadiness(
                configRoot: bridgeConfigRoot,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        )
    }

    /// Verifies the private discovery pair published by NativeAgent's
    /// loopback coding-organ return listener. This never exposes the bearer or
    /// grants authority; it only proves that a helper has a live, internally
    /// consistent endpoint to return a completed Codex/Claude turn to.
    public static func returnPathReadiness(
        configRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> ReturnPathReadiness {
        let root = configRoot ?? InstallPaths(home: homeDirectory).bridgeConfigRoot
        let directory = root.appendingPathComponent("claude-bridge", isDirectory: true)
        let tokenURL = directory.appendingPathComponent("token")
        let descriptorURL = directory.appendingPathComponent("bridge.json")
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenPresent = !(token?.isEmpty ?? true)
        let descriptorData = try? Data(contentsOf: descriptorURL)
        let descriptorPresent = descriptorData != nil

        func unavailable(_ reason: String, endpoint: URL? = nil) -> ReturnPathReadiness {
            ReturnPathReadiness(
                isReady: false,
                reason: reason,
                tokenPresent: tokenPresent,
                descriptorPresent: descriptorPresent,
                endpoint: endpoint
            )
        }

        guard tokenPresent else { return unavailable("token_missing") }
        guard let descriptorData,
              let descriptor = (try? JSONSerialization.jsonObject(with: descriptorData)) as? [String: Any] else {
            return unavailable("descriptor_missing_or_invalid")
        }
        guard let descriptorToken = descriptor["token"] as? String,
              descriptorToken == token else {
            return unavailable("token_descriptor_mismatch")
        }
        guard let rawURL = descriptor["url"] as? String,
              let endpoint = URL(string: rawURL),
              endpoint.scheme?.lowercased() == "http",
              let host = endpoint.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = endpoint.port,
              (1...65_535).contains(port) else {
            return unavailable("endpoint_not_loopback_http")
        }
        if let descriptorHost = descriptor["host"] as? String,
           descriptorHost.lowercased() != host {
            return unavailable("descriptor_endpoint_mismatch", endpoint: endpoint)
        }
        if let descriptorPort = (descriptor["port"] as? NSNumber)?.intValue,
           descriptorPort != port {
            return unavailable("descriptor_endpoint_mismatch", endpoint: endpoint)
        }
        guard let number = descriptor["processIdentifier"] as? NSNumber else {
            return unavailable("publisher_pid_missing", endpoint: endpoint)
        }
        let pid = pid_t(number.int32Value)
        guard pid > 0 else { return unavailable("publisher_pid_invalid", endpoint: endpoint) }
        errno = 0
        guard Darwin.kill(pid, 0) == 0 || errno == EPERM else {
            return unavailable("publisher_not_running", endpoint: endpoint)
        }
        return ReturnPathReadiness(
            isReady: true,
            reason: "ready",
            tokenPresent: true,
            descriptorPresent: true,
            endpoint: endpoint
        )
    }

    public static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var result = base
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        let additions = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".claude/bin").path,
            homeDirectory.appendingPathComponent(".codex/bin").path,
            homeDirectory.appendingPathComponent(".volta/bin").path,
            homeDirectory.appendingPathComponent(".local/share/mise/shims").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        result["PATH"] = uniqueStrings(existing + additions).joined(separator: ":")
        // Wake helpers report working/partial/finished to the app's live
        // stream (`/<lane>/live`); off unless the app launched them.
        result["NATIVE_AGENT_WAKE_LIVE"] = base["NATIVE_AGENT_WAKE_LIVE"] ?? "1"
        return result
    }

    /// The helpers ship as SwiftPM resources of the app target, i.e. inside
    /// `Contents/Resources/NativeAgent_NativeAgentApp.bundle`, whose own
    /// resources live under its `Contents/Resources/` on macOS. Ask Bundle
    /// for that resource directory instead of hand-building the path.
    /// `Bundle.module` is not usable here: it belongs to the app target, and
    /// its synthesized accessor only checks the .app top level and the
    /// builder's `.build/` path (then traps).
    private static func bundledHelper(named name: String, resourceRoot: URL) -> URL {
        let nestedBundle = resourceRoot.appendingPathComponent(
            "NativeAgent_NativeAgentApp.bundle",
            isDirectory: true
        )
        guard let resources = Bundle(url: nestedBundle)?.resourceURL else {
            // No readable bundle there, so nothing under it can be read; report
            // where the packaged macOS layout puts the helper.
            return nestedBundle.appendingPathComponent("Contents/Resources/\(name)")
        }
        return resources.appendingPathComponent(name)
    }

    private static func firstExecutable(_ candidates: [URL], fileManager: FileManager) -> URL? {
        for candidate in unique(candidates).map(\.standardizedFileURL) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
