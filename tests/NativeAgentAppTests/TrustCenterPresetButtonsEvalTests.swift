import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.presetButtons
@Suite("Trust Center preset buttons", .serialized)
struct TrustCenterPresetButtonsEvalTests {
    @Test("four presets and the rendered Custom fixture distinguish unavailable, approval, and autonomous actions")
    @MainActor
    func summaryBadgesAndSentencesMatchEffectivePresetPoliciesAndCustom() async throws {
        let root = try root("summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        for preset in TrustPolicyPreset.allCases.map(Optional.some) + [nil] {
            guard case .applied(var policy) = await TrustPolicyPresetAction.apply(
                preset ?? .work, appModel: app, fullMacConfirmed: preset == .fullMac
            ) else {
                Issue.record("Fixture policy did not save")
                continue
            }
            // Same legacy Custom combination as renderTrustFourCards.
            if preset == nil { policy.autonomyDefault = "app_data_autonomous" }
            let rows = TrustGuardrailSummary.rows(policy: policy, accessMode: AppModel.agentAccessMode(from: policy))
            let files = try #require(rows.first { $0.id == "files" })
            let autonomy = try #require(rows.first { $0.id == "autonomy" })
            let mac = try #require(rows.first { $0.id == "mac_control" })
            let fileBadge: String
            let autonomyBadge: String
            switch preset {
            case .safe: (fileBadge, autonomyBadge) = ("Reads only", "Not available")
            case .work, .builder: (fileBadge, autonomyBadge) = ("Your workspace folders", "Acts alone in your workspaces")
            case .fullMac: (fileBadge, autonomyBadge) = ("Anywhere on this Mac", "Full Mac autonomy active")
            case nil: (fileBadge, autonomyBadge) = ("Your workspace folders", "Automatic memory and notes")
            }
            let expected: String
            switch preset {
            case .safe: expected = "Files are read only; file changes and deletions are not available."
            case .work: expected = "Edits inside your workspaces run on their own; writes outside are not available."
            case .builder: expected = "Edits inside your workspaces run on their own; writes outside ask first."
            case .fullMac: expected = "Edits inside your workspaces run on their own; writes outside run without asking."
            case nil: expected = "Edits inside your workspaces ask first; writes outside are not available."
            }
            #expect([files.value, files.detail] == [fileBadge, expected + (preset == .fullMac ? " macOS still asks separately for access to protected folders." : "")])
            let extra = preset == .fullMac
                ? " Enabled routine actions run without asking on this Mac and trusted remote surfaces; external sends still wait for approval. Explicit tool blocks and protected system actions keep their own checks."
                : preset == nil ? " NativeAgent's own memory and notes update without asking." : ""
            #expect([autonomy.value, autonomy.detail] == [autonomyBadge, expected + extra])
            switch preset {
            case .safe:
                #expect([mac.value, mac.detail] == ["Off", "Mac control is off: app automation, terminal commands, and clicking are not available."])
            case .fullMac:
                #expect([mac.value, mac.detail] == ["Notifications, Spotlight search, Shortcuts, App automation, Clicking and typing, Mac-controlled files, System settings, Terminal commands", "Run without asking: Terminal commands, Reading, listing, writing, moving, and trashing files through Mac control, AppleScript app automation, JavaScript app automation, Clicking and typing, System settings, Shortcuts, Notifications, Spotlight search.\nFile access limits and protected-action checks still apply."])
            default:
                #expect([mac.value, mac.detail] == ["Notifications, Spotlight search, Shortcuts, Mac-controlled files", "Not available: Terminal commands, AppleScript app automation, JavaScript app automation, Clicking and typing, System settings.\nAsk first: Reading, listing, writing, moving, and trashing files through Mac control.\nRun without asking: Shortcuts, Notifications, Spotlight search.\nFile access limits, risk checks, and tool permissions still apply."])
            }
            let backups = try #require(rows.first { $0.id == "backups" })
            let send = try #require(rows.first { $0.id == "external_send" })
            #expect([backups.value, backups.detail] == ["Backup required before changes", "Before an allowed file write, a backup is required so you can restore the previous version."])
            #expect([send.value, send.detail] == ["Asks before sending", "Email, messages, and posts wait for your approval before they leave this Mac."])
        }
    }

    @Test("effective access stays saved until a card applies or confirmation completes")
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
            #expect(pending == "Custom · Workspace access · Saved")
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

    @Test("cards replace a legacy custom policy completely")
    @MainActor
    func cardsReplaceLegacyPolicy() async throws {
        let root = try root("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        for preset in TrustPolicyPreset.allCases {
            #expect(await app.saveTrustPolicy(
                permissionLevel: "balanced", autonomyDefault: "app_data_autonomous",
                requireBackups: false, outsideDefault: "ask", developerMode: true
            ))
            guard case .applied(let policy) = await TrustPolicyPresetAction.apply(
                preset, appModel: app, fullMacConfirmed: preset == .fullMac
            ) else {
                Issue.record("Card failed to replace legacy policy")
                continue
            }
            #expect(TrustCenterPolicyStatusPresentation.preset(
                policy: policy, accessMode: AppModel.agentAccessMode(from: policy)
            ) == preset)
            #expect(policy.filePolicy?.requireBackupBeforeWrite == true)
            #expect(policy.filePolicy?.allowDestructiveActions == (preset == .fullMac))
            #expect(policy.macControlPolicy?.shellAllowed == (preset == .fullMac))
            #expect(policy.macControlPolicy?.systemControlAllowed == (preset == .fullMac))
        }
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
            #expect(policy.filePolicy?.requireBackupBeforeWrite == true)
            #expect(policy.filePolicy?.outsideWorkspaceDefault == plan.outsideDefault)
            #expect(AppModel.agentAccessMode(from: policy) == plan.agentAccessMode)
            #expect(TrustCenterPolicyStatusPresentation.preset(policy: policy, accessMode: plan.agentAccessMode) == preset)
            #expect(TrustCenterPolicyStatusPresentation.line(
                policy: policy, accessMode: plan.agentAccessMode,
                permissionLevel: plan.permissionLevel, autonomyDefault: plan.autonomyDefault,
                requireBackups: plan.requireBackups, outsideDefault: plan.outsideDefault
            ) == "\(preset.title) · Saved")
            var custom = policy
            custom.developerMode.toggle()
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
        var confirmationPresented = true
        TrustPolicyPresetTransition.cancelConfirmation(isPresented: &confirmationPresented)
        #expect(!confirmationPresented)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("trust/policy.json").path))

        guard case .applied = await TrustPolicyPresetAction.apply(.work, appModel: app) else {
            Issue.record("Work fixture must save")
            return
        }
        let path = root.appendingPathComponent("trust/policy.json")
        let saved = try Data(contentsOf: path)
        let savedPolicy = app.trustPolicy
        guard case .confirmationRequired = await TrustPolicyPresetAction.apply(.fullMac, appModel: app) else {
            Issue.record("Full Mac must await confirmation over an existing policy")
            return
        }
        confirmationPresented = true
        TrustPolicyPresetTransition.cancelConfirmation(isPresented: &confirmationPresented)
        #expect(!confirmationPresented)
        #expect(try Data(contentsOf: path) == saved)
        #expect(app.trustPolicy == savedPolicy)
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
