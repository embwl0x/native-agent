import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.presetButtons
@Suite("Trust Center preset buttons", .serialized)
struct TrustCenterPresetButtonsEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-preset-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("every documented preset writes its complete policy through the real authority writer")
    @MainActor
    func presetsPersistTheirDocumentedFields() async throws {
        for preset in TrustPolicyPreset.allCases {
            let root = try root("\(preset)")
            defer { try? FileManager.default.removeItem(at: root) }
            let plan = preset.plan
            let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
            let outcome = await TrustPolicyPresetAction.apply(
                preset,
                appModel: app,
                fullMacConfirmed: preset == .fullMac
            )
            guard case .applied(let policy) = outcome else {
                Issue.record("expected \(preset) to persist, got \(TrustPolicyPresetActionPresentation.statusText(for: outcome))")
                continue
            }

            #expect(policy.permissionLevel == plan.permissionLevel)
            #expect(policy.autonomyDefault == plan.autonomyDefault)
            #expect(policy.developerMode == plan.developerMode)
            #expect(policy.filePolicy?.requireBackupBeforeWrite == plan.requireBackups)
            #expect(policy.filePolicy?.outsideWorkspaceDefault == plan.outsideDefault)
            #expect(AppModel.agentAccessMode(from: policy) == plan.agentAccessMode)
        }
    }

    @Test("Full Mac has an explicit confirmation transition before any policy writer is invoked")
    @MainActor
    func fullMacRequiresConfirmationWhileOtherPresetsApplyImmediately() async throws {
        for preset in [TrustPolicyPreset.safe, .work, .builder] {
            #expect(TrustPolicyPresetTransition.request(preset) == .apply(preset.plan))
        }
        #expect(
            TrustPolicyPresetTransition.request(.fullMac)
                == .confirmationRequired(TrustPolicyPreset.fullMac.plan)
        )
        let root = try root("full-mac-confirmation")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let outcome = await TrustPolicyPresetAction.apply(.fullMac, appModel: app)
        guard case .confirmationRequired = outcome else {
            Issue.record("Full Mac must not write before confirmation")
            return
        }
        #expect(TrustPolicyPresetActionPresentation.statusText(for: outcome)
            == "Full Mac access needs confirmation.")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("trust/policy.json").path
        ))
    }

    @Test("a malformed existing authority file is rejected without being overwritten by a preset")
    @MainActor
    func damagedAuthorityStaysBytePreserved() async throws {
        let root = try root("malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("trust/policy.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("{broken".utf8)
        try malformed.write(to: path)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let outcome = await TrustPolicyPresetAction.apply(.safe, appModel: app)
        guard case .failed(let detail) = outcome else {
            Issue.record("the preset action must refuse malformed authority state")
            return
        }
        #expect(!detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(TrustPolicyPresetActionPresentation.statusText(for: outcome) == detail)
        #expect(try Data(contentsOf: path) == malformed)
    }
}
