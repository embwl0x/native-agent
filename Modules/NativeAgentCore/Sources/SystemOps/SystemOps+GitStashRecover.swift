import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - SwiftNative — GitStashRecover

public final class SwiftNativeGitStashRecoverClient: GitStashRecoverClient {
    private let repoRoot: URL
    private let runner: any SubprocessRunner
    private let gitExecutable: String
    private let daemonAutonomy: Bool
    private let policyProvider: @Sendable () async -> AutonomyTrustPolicyView

    /// - Parameters:
    ///   - repoRoot:        Local NativeAgent checkout root.
    ///   - runner:          Test-injectable subprocess runner.
    ///   - gitExecutable:   `/usr/bin/git` by default.
    ///   - daemonAutonomy:  Static daemon-startup `enable_autonomy` flag.
    ///                      Defaults to `false` (closed-fail). Production
    ///                      callers MUST seed this from the daemon boot
    ///                      configuration; tests can pass `true` + a stub
    ///                      policy provider.
    ///   - policyProvider:  Async closure returning the current trust-policy
    ///                      view. Defaults to `readAutonomyTrustPolicy()`.
    public init(
        repoRoot: URL? = nil,
        runner: any SubprocessRunner = SystemSubprocessRunner(),
        gitExecutable: String = "/usr/bin/git",
        daemonAutonomy: Bool = false,
        policyProvider: (@Sendable () async -> AutonomyTrustPolicyView)? = nil
    ) {
        self.repoRoot = repoRoot ?? PersistenceCore.defaultDataRoot().deletingLastPathComponent()
        self.runner = runner
        self.gitExecutable = gitExecutable
        self.daemonAutonomy = daemonAutonomy
        self.policyProvider = policyProvider ?? { await readAutonomyTrustPolicy() }
    }

    public func gitStashRecover(label: String) async throws -> GitStashRecoverOpResult {
        // Wave-8 gate: enforce the global autonomy + per-action enabled
        // flag before invoking git. Mirrors Python L45254-L45257 (which
        // currently has only the two global checks; the per-action
        // `gitStashRecover.enabled` flag is the Swift hardening added in
        // wave 8 + matches the daemon's growing per-action enabled
        // convention started by `systemRebuild.enabled` at L45120).
        let policy = await policyProvider()
        switch try await autonomyApprovalGate(
            action: .gitStashRecover,
            daemonAutonomy: daemonAutonomy,
            policy: policy
        ) {
        case .allowed:
            break
        case .denied(let reason):
            throw SystemOpsError.autonomyDenied(reason)
        }

        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SystemOpsError.missingLabel }

        let list = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", repoRoot.path, "stash", "list"],
            cwd: nil,
            timeout: 10,
            detached: false
        )
        var target: String? = nil
        for line in list.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.contains(trimmed) {
                if let colon = line.firstIndex(of: ":") {
                    target = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                } else {
                    target = String(line).trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }
        guard let ref = target, !ref.isEmpty else {
            throw SystemOpsError.stashNotFound(trimmed)
        }

        let pop = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", repoRoot.path, "stash", "pop", ref],
            cwd: nil,
            timeout: 30,
            detached: false
        )
        if pop.exitCode != 0 {
            let msg = (pop.stdout + pop.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemOpsError.stashPopFailed(msg.isEmpty ? "git stash pop failed" : msg)
        }
        return GitStashRecoverOpResult(
            ok: true,
            stashRef: ref,
            output: pop.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            error: nil
        )
    }
}
