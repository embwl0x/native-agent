import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - SwiftNative — SystemRebuild

public final class SwiftNativeSystemRebuildClient: SystemRebuildClient {
    private let repoRoot: URL
    private let runner: any SubprocessRunner
    private let daemonAutonomy: Bool
    private let policyProvider: @Sendable () async -> AutonomyTrustPolicyView
    private let rebuildLock: RebuildLock

    /// - Parameters:
    ///   - repoRoot:        Local NativeAgent checkout root (contains
    ///                      `script/install_app.sh`).
    ///   - runner:          Test-injectable subprocess runner.
    ///   - daemonAutonomy:  Static daemon-startup `enable_autonomy` flag.
    ///                      Defaults to `false` (closed-fail). Production
    ///                      callers MUST seed this from the daemon boot
    ///                      configuration; tests can pass `true` + a stub
    ///                      policy provider.
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
        policyProvider: (@Sendable () async -> AutonomyTrustPolicyView)? = nil,
        rebuildLock: RebuildLock? = nil
    ) {
        let resolvedRoot = repoRoot ?? Self.locateRepoRoot()
        self.repoRoot = resolvedRoot
        self.runner = runner
        self.daemonAutonomy = daemonAutonomy
        self.policyProvider = policyProvider ?? { await readAutonomyTrustPolicy() }
        self.rebuildLock = rebuildLock ?? RebuildLock()
    }

    public func systemRebuild() async throws -> SystemRebuildOpResult {
        // Wave-8 gate: BOTH the daemon-startup master switch AND the
        // user-set Trust Center toggle must be on; additionally the
        // per-action `systemRebuild.enabled` flag must be true (default
        // false). Mirrors Python L45110-L45125.
        let policy = await policyProvider()
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

        // Cross-process rebuild lock. The Python lock at L45168 is
        // intentionally never released after Popen succeeds (the daemon
        // dies in install_app.sh). The Swift mirror is the same: on the
        // happy path we leak the fd so the kernel auto-releases on
        // process exit; on the error path (script missing OR Popen
        // throws) we release explicitly so a retry can proceed.
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
                detached: true
            )
        } catch {
            await rebuildLock.release()
            throw error
        }
        // Note: lock intentionally NOT released here — the app process is
        // about to die mid-install.
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
