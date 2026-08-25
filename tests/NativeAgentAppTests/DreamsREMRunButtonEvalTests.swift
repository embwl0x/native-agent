import Foundation
import Testing
import DreamREMCycle
@testable import NativeAgentApp

private func remButtonTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dreams-rem-button-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Dreams REM run button — checked completion")
struct DreamsREMRunButtonEvalTests {
    @Test("the Run REM presentation and real invocation both honor the same disabled canonical gate")
    func runREMButtonFailsClosedBeforeTheNativeRunner() async throws {
        let root = try remButtonTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let policy = try await NativeClient.applyTrustPolicyPatch(
            body: ["trainingPolicy": ["rem_cycle_enabled": false]],
            dataRoot: root)
        #expect(policy.trainingPolicy?.rem_cycle_enabled == false)

        let availability = DreamsREMRunAvailability.resolve(
            policy: policy,
            policyLoadFailed: false
        )
        #expect(availability == .disabled)
        #expect(!availability.canRun,
                "the Run REM action must not be available against an explicit disabled REM gate")
        #expect(availability.help == "REM cycle is disabled. Enable the REM cycle toggle.")

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        do {
            _ = try await client.runRem()
            Issue.record("a disabled REM gate reached the native REM runner")
        } catch let error as DreamREMCycleError {
            guard case .cycleDisabled(let code, _) = error else {
                Issue.record("unexpected REM refusal: \(error.localizedDescription)")
                return
            }
            #expect(code == "rem_cycle_disabled")
        }
    }

    @Test("a corrupt authority store is not converted into an enabled manual REM run")
    func runREMExposesUnreadableAuthorityInsteadOfUsingACompatibilityDefault() async throws {
        let root = try remButtonTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trustDirectory = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
        let policyURL = trustDirectory.appendingPathComponent("policy.json")
        let damaged = Data("{ this is not trust policy JSON".utf8)
        try damaged.write(to: policyURL)

        do {
            _ = try await NativeClient(baseURL: "http://unused", dataRootOverride: root).runRem()
            Issue.record("unreadable authority must not start REM")
        } catch {
            #expect(try Data(contentsOf: policyURL) == damaged,
                    "a failed REM gate read must preserve the damaged authority bytes")
        }
    }

    @Test("the exact native REM completion wire is rendered as completion, not a launch claim")
    func remCompletionFeedbackRequiresBoundedCounters() {
        #expect(
            DreamsREMActionFeedback.resolve(response: [
                "ok": true,
                "proposalsGenerated": 0,
                "archivedEntries": 2,
            ]) == .completed(proposals: 0, archivedEntries: 2))
        #expect(
            DreamsREMActionFeedback.resolve(response: [
                "ok": true,
                "proposalsGenerated": 1,
            ]).isSuccess == false,
            "a partial completion record must remain an adverse state")
    }
}
