import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.presetButtons
@Suite("Trust Center preset buttons", .serialized)
struct TrustCenterPresetButtonsEvalTests {
    @Test("effective access stays saved while custom policy edits wait for save or confirmation")
    func effectiveAccessAndPendingSave() {
        let policy = TrustPolicy(permissionLevel: "balanced", autonomyDefault: "supervised")
        func line(level: String = "balanced", autonomy: String = "supervised", backups: Bool = true,
                  outside: String = "deny", applying: Bool = false, confirmation: Bool = false,
                  failed: Bool = false) -> String {
            TrustCenterPolicyStatusPresentation.line(
                policy: policy, accessMode: "workspace", permissionLevel: level,
                autonomyDefault: autonomy, requireBackups: backups, outsideDefault: outside,
                isApplying: applying, needsConfirmation: confirmation, policyReadFailed: failed
            )
        }
        #expect(line() == "Custom · Workspace access · Saved")
        for pending in [line(level: "full_mac_os"), line(autonomy: "workspace_autonomous"),
                        line(backups: false), line(outside: "allow")] {
            #expect(pending == "Custom · Workspace access · Unsaved changes — Save policy to apply")
        }
        #expect(line(level: "full_mac_os", confirmation: true) == "Custom · Workspace access · Confirmation required")
        #expect(line(applying: true) == "Custom · Workspace access · Applying changes…")
        #expect(line(failed: true).hasPrefix("Effective access unavailable"))
        #expect(TrustCenterPolicyStatusPresentation.line(
            policy: nil, accessMode: "full", permissionLevel: "full_mac_os",
            autonomyDefault: "workspace_autonomous", requireBackups: false, outsideDefault: "allow"
        ).hasPrefix("Effective access unavailable"))
    }

    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-preset-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("immediate authority writes preserve all unsaved policy fields through repeated refreshes")
    @MainActor
    func immediateChangesPreserveDraft() async throws {
        let root = try root("draft")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        guard case .applied(let policy) = await TrustPolicyPresetAction.apply(.safe, appModel: app) else {
            Issue.record("Safe fixture failed to save")
            return
        }
        var baseline = TrustPolicyDraft(policy)
        var draft = baseline
        draft.permissionLevel = "balanced"
        draft.autonomyDefault = "app_data_autonomous"
        draft.requireBackups = false
        draft.outsideDefault = "ask"
        let edits = draft
        let developerSaved = try await app.client.saveDeveloperMode(true)
        app.applySavedTrustPolicy(developerSaved, status: "Saved")
        for saved in [developerSaved, developerSaved] {
            draft = draft.refreshed(from: baseline, to: TrustPolicyDraft(saved))
            baseline = TrustPolicyDraft(saved)
            #expect(draft == edits)
        }
        #expect(await app.saveAgentAccessMode("full", developerMode: true))
        let full = try #require(app.trustPolicy)
        draft = draft.refreshed(from: baseline, to: TrustPolicyDraft(full))
        #expect(draft == edits)
        #expect(await app.saveTrustPolicy(
            permissionLevel: draft.permissionLevel, autonomyDefault: draft.autonomyDefault,
            requireBackups: draft.requireBackups, outsideDefault: draft.outsideDefault,
            developerMode: full.developerMode
        ))
        #expect(TrustPolicyDraft(try #require(app.trustPolicy)) == edits)
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
            #expect(TrustCenterPolicyStatusPresentation.preset(policy: policy, accessMode: plan.agentAccessMode) == preset)
            #expect(TrustCenterPolicyStatusPresentation.line(
                policy: policy, accessMode: plan.agentAccessMode,
                permissionLevel: plan.permissionLevel, autonomyDefault: plan.autonomyDefault,
                requireBackups: plan.requireBackups, outsideDefault: plan.outsideDefault
            ) == "\(preset.title) · Saved")
            var custom = policy
            custom.developerMode = true
            #expect(TrustCenterPolicyStatusPresentation.preset(policy: custom, accessMode: plan.agentAccessMode) == nil)
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
