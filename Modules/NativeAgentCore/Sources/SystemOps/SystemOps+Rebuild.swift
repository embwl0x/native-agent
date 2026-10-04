import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - SwiftNative — SystemRebuild

public final class SwiftNativeSystemRebuildClient: SystemRebuildClient {
    private let repoRoot: URL
    private let runner: any SubprocessRunner
    private let daemonAutonomy: Bool
    private let policyProvider: @Sendable () async throws -> AutonomyTrustPolicyView
    private let rebuildLock: RebuildLock

    /// - Parameters:
    ///   - repoRoot:        Local NativeAgent checkout root (contains
    ///                      `script/install_app.sh`).
    ///   - runner:          Test-injectable subprocess runner.
    ///   - daemonAutonomy:  Runtime availability gate. Defaults to `false`
    ///                      for direct construction; the production factory
    ///                      enables the unconditional in-process runtime.
    ///   - policyProvider:  Async closure returning the current trust-policy
    ///                      view. Defaults to `readAutonomyTrustPolicy()`
    ///                      which reads `<dataRoot>/trust/policy.json` via
    ///                      PersistenceCore.
    ///   - rebuildLock:     Cross-process flock mutex. Defaults to a
    ///                      `<dataRoot>/.rebuild.lock` lock; tests can
    ///                      inject a lock pointed at a tmp dir.
    public init(
        repoRoot: URL? = nil,
        runner: any SubprocessRunner = SystemSubprocessRunner(),
        daemonAutonomy: Bool = false,
        policyProvider: (@Sendable () async throws -> AutonomyTrustPolicyView)? = nil,
        rebuildLock: RebuildLock? = nil
    ) {
        let resolvedRoot = repoRoot ?? Self.locateRepoRoot()
        self.repoRoot = resolvedRoot
        self.runner = runner
        self.daemonAutonomy = daemonAutonomy
        self.policyProvider = policyProvider ?? { try await readAutonomyTrustPolicy() }
        self.rebuildLock = rebuildLock ?? RebuildLock()
    }

    public func systemRebuild() async throws -> SystemRebuildOpResult {
        // Runtime availability, current Trust autonomy and the per-action
        // rebuild authorization must all allow execution.
        let policy = try await policyProvider()
        switch try await autonomyApprovalGate(
            action: .systemRebuild,
            daemonAutonomy: daemonAutonomy,
            policy: policy
        ) {
        case .allowed:
            break
        case .denied(let reason):
            throw SystemOpsError.autonomyDenied(reason)
        }

        // Hold the cross-process lock until installation ends or the app exits.
        // An installer that exits before restarting the app must allow a retry.
        if await !rebuildLock.acquire() {
            throw SystemOpsError.rebuildInProgress
        }

        let script = repoRoot.appendingPathComponent("script").appendingPathComponent("install_app.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            await rebuildLock.release()
            throw SystemOpsError.scriptMissing(script.path)
        }
        // Detached: don't wait. Mirrors Python's start_new_session=True.
        do {
            _ = try await runner.run(
                executable: "/bin/bash",
                arguments: [script.path],
                cwd: repoRoot,
                timeout: 5,
                detached: true,
                onTermination: { [rebuildLock] _ in
                    Task { await rebuildLock.release() }
                }
            )
        } catch {
            await rebuildLock.release()
            throw error
        }
        return SystemRebuildOpResult(
            ok: true,
            message: "Rebuild started — the app will reinstall and restart in ~10–60s",
            error: nil
        )
    }

    /// Walk up from `PersistenceCore.defaultDataRoot()` until we find a
    /// `script/install_app.sh`. Falls back to the data-root parent if no
    /// such marker is found (callers can pass an explicit override).
    private static func locateRepoRoot() -> URL {
        var dir = PersistenceCore.defaultDataRoot()
        for _ in 0..<8 {
            let marker = dir.appendingPathComponent("script").appendingPathComponent("install_app.sh")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return PersistenceCore.defaultDataRoot().deletingLastPathComponent()
    }
}
