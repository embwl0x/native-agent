// Sweep R4 C10 — the summary panel makes trust claims on the top of the Trust
// page, so the thing that must never regress is that every claim is DERIVED.
// Each test below hands `rows` a policy fixture and pins the exact row it must
// produce; a hardcoded sentence would fail the fixture that contradicts it.

import Foundation
import Testing

@testable import NativeAgentApp

@Suite
struct TrustGuardrailSummaryTests {

    // MARK: - Fixtures

    private func policy(
        permissionLevel: String = "balanced",
        autonomyDefault: String? = "supervised",
        requireBackupBeforeWrite: Bool? = true,
        outsideWorkspaceDefault: String? = "deny",
        sendExternalRequiresApproval: Bool? = true,
        macControl: TrustMacControlPolicy? = nil
    ) -> TrustPolicy {
        TrustPolicy(
            permissionLevel: permissionLevel,
            autonomyDefault: autonomyDefault,
            filePolicy: TrustFilePolicy(
                allowedWorkspaceIds: nil,
                requireBackupBeforeWrite: requireBackupBeforeWrite,
                allowDestructiveActions: nil,
                outsideWorkspaceDefault: outsideWorkspaceDefault
            ),
            connectorPolicy: TrustConnectorPolicy(
                defaultEnabled: nil,
                sendExternalMessagesRequiresApproval: sendExternalRequiresApproval
            ),
            macControlPolicy: macControl
        )
    }

    private func row(_ rows: [TrustGuardrailRow], _ id: String) -> TrustGuardrailRow {
        guard let found = rows.first(where: { $0.id == id }) else {
            Issue.record("no row with id \(id) in \(rows.map(\.id))")
            return TrustGuardrailRow(id: "", title: "", value: "", detail: "", systemImage: "", tone: .ok)
        }
        return found
    }

    // MARK: - Shape

    @Test
    func noPolicyYieldsNoRowsRatherThanGuesses() {
        // A summary that renders defaults before the policy loads is a lie for
        // however long the load takes. Empty means the panel shows "reading…".
        #expect(TrustGuardrailSummary.rows(policy: nil, accessMode: "auto").isEmpty)
    }

    @Test
    func producesTheFiveConceptRowsInReadingOrder() {
        let rows = TrustGuardrailSummary.rows(policy: policy(), accessMode: "auto")
        #expect(rows.map(\.id) == ["files", "autonomy", "backups", "mac_control", "external_send"])
    }

    // MARK: - Files

    @Test
    func safeDefaultsReadAsAllClear() {
        let rows = TrustGuardrailSummary.rows(policy: policy(), accessMode: "auto")
        #expect(rows.allSatisfy { $0.tone == .ok })
        #expect(row(rows, "files").value == "Reads freely, writes when asked")
        #expect(row(rows, "files").detail.contains("off limits"))
    }

    @Test
    func readOnlyModeSaysItCannotChangeAnything() {
        let rows = TrustGuardrailSummary.rows(policy: policy(permissionLevel: "strict"), accessMode: "read_only")
        #expect(row(rows, "files").value == "Reads only")
        #expect(row(rows, "files").tone == .ok)
    }

    @Test
    func fullMacFilesRowIsAlertAndNamesTheMacOSBoundary() {
        let rows = TrustGuardrailSummary.rows(
            policy: policy(permissionLevel: "full_mac_os", outsideWorkspaceDefault: "allow"),
            accessMode: "full"
        )
        let files = row(rows, "files")
        #expect(files.value == "Anywhere on this Mac")
        #expect(files.tone == .danger)
        // The one reassurance a user needs at this exact moment.
        #expect(files.detail.contains("macOS still asks separately"))
    }

    @Test
    func outsideWorkspaceDefaultChangesTheWorkspaceSentence() {
        let deny = TrustGuardrailSummary.rows(policy: policy(), accessMode: "workspace")
        let ask = TrustGuardrailSummary.rows(policy: policy(outsideWorkspaceDefault: "ask"), accessMode: "workspace")
        let allow = TrustGuardrailSummary.rows(policy: policy(outsideWorkspaceDefault: "allow"), accessMode: "workspace")
        #expect(row(deny, "files").detail.contains("off limits"))
        #expect(row(ask, "files").detail.contains("only when you say yes"))
        #expect(row(allow, "files").detail.contains("without asking"))
    }

    // MARK: - Autonomy

    @Test
    func autonomyRowTracksEachAutonomyDefault() {
        let supervised = TrustGuardrailSummary.rows(policy: policy(), accessMode: "auto")
        #expect(row(supervised, "autonomy").value == "Asks you first")
        #expect(row(supervised, "autonomy").tone == .ok)

        let appData = TrustGuardrailSummary.rows(
            policy: policy(autonomyDefault: "app_data_autonomous"), accessMode: "auto")
        #expect(row(appData, "autonomy").value == "Acts alone on its own data")
        #expect(row(appData, "autonomy").tone == .caution)

        let workspace = TrustGuardrailSummary.rows(
            policy: policy(autonomyDefault: "workspace_autonomous"), accessMode: "workspace")
        #expect(row(workspace, "autonomy").value == "Acts alone in your workspaces")
        #expect(row(workspace, "autonomy").tone == .danger)
    }

    @Test
    func missingAutonomyDefaultReadsAsSupervised() {
        let rows = TrustGuardrailSummary.rows(policy: policy(autonomyDefault: nil), accessMode: "auto")
        #expect(row(rows, "autonomy").value == "Asks you first")
    }

    // MARK: - Backups (the C4 defect this row exists to surface)

    @Test
    func backupsOffIsAnAlertRowNamingTheToggleThatRestoresIt() {
        let rows = TrustGuardrailSummary.rows(
            policy: policy(requireBackupBeforeWrite: false), accessMode: "workspace")
        let backups = row(rows, "backups")
        #expect(backups.value == "No backup taken")
        #expect(backups.tone == .danger)
        #expect(backups.detail.contains("Backup before workspace writes"))
    }

    @Test
    func absentBackupKeyReadsAsOnMatchingThePagesOwnFallback() {
        // TrustCenterView applies `?? true` to the same field; if these two
        // disagreed the summary would contradict the toggle beside it.
        let rows = TrustGuardrailSummary.rows(
            policy: policy(requireBackupBeforeWrite: nil), accessMode: "auto")
        #expect(row(rows, "backups").value == "Backup taken first")
    }

    // MARK: - Mac control

    @Test
    func macControlOffSaysSoPlainly() {
        let rows = TrustGuardrailSummary.rows(policy: policy(), accessMode: "auto")
        #expect(row(rows, "mac_control").value == "Off")
        #expect(row(rows, "mac_control").tone == .ok)
    }

    @Test
    func macControlDisabledMasterHidesGrantedCategories() {
        // A category flag left true under a disabled master must not be
        // reported as something the agent can do.
        let mac = TrustMacControlPolicy(enabled: false, shellAllowed: true)
        let rows = TrustGuardrailSummary.rows(policy: policy(macControl: mac), accessMode: "auto")
        #expect(row(rows, "mac_control").value == "Off")
    }

    @Test
    func macControlListsOnlyTheGrantedCategories() {
        let mac = TrustMacControlPolicy(
            enabled: true,
            applesScriptAllowed: true,
            shortcutsAllowed: true,
            notificationsAllowed: true,
            spotlightAllowed: false
        )
        let rows = TrustGuardrailSummary.rows(policy: policy(macControl: mac), accessMode: "workspace")
        let control = row(rows, "mac_control")
        #expect(control.value == "Notifications, Shortcuts, App automation")
        #expect(control.tone == .caution)
    }

    @Test
    func shellGrantEscalatesTheMacControlRowToAlert() {
        let mac = TrustMacControlPolicy(
            enabled: true,
            shortcutsAllowed: false,
            shellAllowed: true,
            notificationsAllowed: false,
            spotlightAllowed: false
        )
        let rows = TrustGuardrailSummary.rows(policy: policy(macControl: mac), accessMode: "full")
        let control = row(rows, "mac_control")
        #expect(control.value == "Terminal commands")
        #expect(control.tone == .danger)
    }

    @Test
    func emptyApprovalListIsReportedAsNothingAsksFirst() {
        let mac = TrustMacControlPolicy(
            enabled: true,
            shellAllowed: true,
            approvalRequiredFor: []
        )
        let rows = TrustGuardrailSummary.rows(policy: policy(macControl: mac), accessMode: "full")
        #expect(row(rows, "mac_control").detail.contains("none stop to ask you first"))
    }

    @Test
    func partialApprovalListNamesExactlyTheCategoriesThatAsk() {
        let mac = TrustMacControlPolicy(
            enabled: true,
            fileOpsAllowed: true,
            shellAllowed: true,
            approvalRequiredFor: ["shell"]
        )
        let rows = TrustGuardrailSummary.rows(policy: policy(macControl: mac), accessMode: "full")
        let detail = row(rows, "mac_control").detail
        #expect(detail.contains("Running terminal commands"))
        #expect(!detail.contains("Creating, changing, or deleting files"))
    }

    @Test
    func grantedCategoryNamesNeverLeakRawPolicyKeys() {
        let mac = TrustMacControlPolicy(
            enabled: true,
            applesScriptAllowed: true,
            jxaAllowed: true,
            accessibilityAllowed: true,
            systemControlAllowed: true,
            fileOpsAllowed: true,
            shellAllowed: true
        )
        let names = TrustGuardrailSummary.grantedMacCategories(mac)
        let rawKeys = ["shell", "file_ops", "applescript", "jxa", "accessibility", "system_control"]
        for name in names {
            #expect(!rawKeys.contains(name.lowercased()))
        }
        // AppleScript + JXA are one idea to a user, so they collapse to one row.
        #expect(names.filter { $0 == "App automation" }.count == 1)
    }

    // MARK: - External send

    @Test
    func externalSendWithoutApprovalIsAnAlert() {
        let rows = TrustGuardrailSummary.rows(
            policy: policy(sendExternalRequiresApproval: false), accessMode: "auto")
        let send = row(rows, "external_send")
        #expect(send.value == "Mostly asks first")
        #expect(send.tone == .caution)
    }

    @Test
    func absentConnectorPolicyReadsAsAsksFirst() {
        var p = policy()
        p.connectorPolicy = nil
        let rows = TrustGuardrailSummary.rows(policy: p, accessMode: "auto")
        #expect(row(rows, "external_send").value == "Asks before sending")
    }

    // MARK: - Copy fence (C9 lives next door; the summary must not reintroduce it)

    @Test
    func noRowLeaksInternalVocabulary() {
        let mac = TrustMacControlPolicy(
            enabled: true,
            applesScriptAllowed: true,
            jxaAllowed: true,
            accessibilityAllowed: true,
            fileOpsAllowed: true,
            shellAllowed: true
        )
        let fixtures: [TrustPolicy] = [
            policy(),
            policy(permissionLevel: "strict"),
            policy(
                permissionLevel: "full_mac_os",
                autonomyDefault: "workspace_autonomous",
                requireBackupBeforeWrite: false,
                outsideWorkspaceDefault: "allow",
                sendExternalRequiresApproval: false,
                macControl: mac
            ),
        ]
        let banned = ["/v1/", "tier a", "tier b", "harness", "drill", "promotion engine", "seatbelt", "yolo", "autonomy tier", "file_ops", "jxa"]
        for fixture in fixtures {
            for mode in ["auto", "read_only", "workspace", "full"] {
                for r in TrustGuardrailSummary.rows(policy: fixture, accessMode: mode) {
                    let text = "\(r.title) \(r.value) \(r.detail)".lowercased()
                    for term in banned {
                        #expect(!text.contains(term), "row \(r.id) leaked \"\(term)\"")
                    }
                }
            }
        }
    }
}
