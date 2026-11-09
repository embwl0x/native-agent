import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `MacControlActionRoutes+PlatformPolicy.swift` | checked Trust policy provider and bounded process-result interpretation |

public struct TrustCenterMacControlPolicyProvider: MacControlPolicyProvider {
    let dataRoot: URL
    private let admittedPolicy: MacControlPolicy?
    // Supplied only by the local workbench call site, never decoded from a remote request body. Raw HTTP/iOS callers leave this nil.
    let operatorOrigin: SecurityOriginContext?

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot(), operatorOrigin: SecurityOriginContext? = nil) {
        self.dataRoot = dataRoot
        self.operatorOrigin = operatorOrigin
        self.admittedPolicy = nil
    }

    /// An evaluated tool call retains the generation that admitted it; raw routes read live authority below.
    public init(admittedPolicy: MacControlPolicy, dataRoot: URL) {
        self.dataRoot = dataRoot
        self.operatorOrigin = nil
        self.admittedPolicy = admittedPolicy
    }

    public func currentPolicy(turn: Turn) async throws -> MacControlPolicy {
        if let admittedPolicy { return admittedPolicy }
        let snapshot = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
        let policy = MacControlPolicy.fromTrustPolicyObject(snapshot.policy, dataRoot: dataRoot)
        guard let operatorOrigin else { return policy }
        let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
            origin: operatorOrigin, snapshot: snapshot, turn: turn
        )
        guard authority.state != .unavailable else { throw SwiftNativeTrustCenter.policyUnavailable(authority.reason) }
        return MacControlGate.policyForAdmittedFullMac(policy, admitted: authority.admitted)
    }

    /// Remote actions obey Pause everything and declared-class command authority. App scripts retain per-event target checks; command text grants no authority.
    /// The local workbench carries the person's own decision.
    public func authorize(tool: String, input: [String: JSONValue], turn: Turn) async -> (level: String, reason: String, remedy: JSONValue?)? {
        guard admittedPolicy == nil, operatorOrigin == nil else { return nil }
        do {
            let snapshot = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            if let paused = SwiftNativeSecurityCenter.killSwitchRefusal(policy: snapshot.policy) {
                return ("blocked", paused.reason, paused.remedy)
            }
            guard tool == "shell" || tool == "applescript" else { return nil }
            let answer = try PermissionLaw.answer(tool: "shell", input: tool == "shell" ? input : nil,
                                              policy: snapshot.policy, dataRoot: dataRoot, turn: turn)
            return (answer.level, answer.reason, answer.remedy)
        } catch {
            return ("blocked", "trust/policy.json could not be read, so \(tool) cannot be judged: \(error.localizedDescription)", nil)
        }
    }

}

extension ProcessExecution {
    /// One process run bounded by `timeout`; a timeout reads as exit 124 with its stderr (or a line naming the command that timed out).
    public static func runBounded(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try await ProcessExecution().run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: timeout
        )
        if result.timedOut {
            let stderr = result.stderr.isEmpty
                ? "\(URL(fileURLWithPath: executable).lastPathComponent) command timed out"
                : result.stderr
            return (124, result.stdout, stderr)
        }
        return (result.exitCode, result.stdout, result.stderr)
    }
}
