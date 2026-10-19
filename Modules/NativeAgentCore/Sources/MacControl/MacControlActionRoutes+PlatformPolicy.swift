import Foundation
import PersistenceCore
import TrustCenter

public struct TrustCenterMacControlPolicyProvider: MacControlPolicyProvider {
    let dataRoot: URL
    // Supplied only by the local workbench call site, never decoded from a
    // remote request body. Raw HTTP/iOS callers leave this nil.
    let operatorOrigin: SecurityOriginContext?

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot(), operatorOrigin: SecurityOriginContext? = nil) {
        self.dataRoot = dataRoot
        self.operatorOrigin = operatorOrigin
    }

    public func currentPolicy() async -> MacControlPolicy? {
        guard let snapshot = try? await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked() else { return nil }
        let policy = MacControlPolicy.fromTrustPolicyObject(snapshot.policy)
        guard let operatorOrigin else { return policy }
        let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
            tool: "mac_control", origin: operatorOrigin
        )
        return MacControlGate.policyForAdmittedFullMac(policy, admitted: authority.admitted)
    }

    /// Raw doors (the phone remote, a bridge) meet the permission law
    /// here. The person's own Mac workbench is his decision.
    public func authorize(tool: String, input: [String: JSONValue]) async -> (level: String, reason: String, remedy: JSONValue?)? {
        guard operatorOrigin == nil else { return nil }
        do {
            let snapshot = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            let answer = PermissionLaw.answer(tool: tool, input: input, policy: snapshot.policy, dataRoot: dataRoot)
            return (answer.level, answer.reason, answer.remedy)
        } catch {
            return ("blocked", "trust/policy.json could not be read, so \(tool) cannot be judged: \(error.localizedDescription)", nil)
        }
    }

}

extension SystemProcessAdapter {
    /// One process run bounded by `timeout`; a timeout reads as exit 124
    /// with its stderr (or a line naming the command that timed out).
    public static func runBounded(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try await SystemProcessAdapter().run(
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
