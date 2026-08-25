import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.safetyBoundariesPanel

@Suite("Trust Center safety boundaries")
struct TrustSafetyBoundariesPanelEvalTests {
    @Test("a missing policy is visibly unconfirmed rather than rendered as safe defaults")
    func missingPolicyHasNoSafetyClaims() {
        let state = TrustSafetyBoundariesPresentation.state(policy: nil, accessMode: "auto")

        #expect(state.rows.isEmpty)
        #expect(state.unavailableMessage?.contains("not confirmed") == true)
    }

    @Test("the loaded policy drives every boundary row and safe receipts remain explicit")
    func safePolicyProducesPolicyBoundRows() {
        let state = TrustSafetyBoundariesPresentation.state(
            policy: policy(
                toolPolicy: .init(autoPromoteSafeTools: false, autoRunSafeTools: false, riskyToolApproval: "deny"),
                connectorPolicy: .init(defaultEnabled: nil, sendExternalMessagesRequiresApproval: true),
                workshopPolicy: .init(allowBackgroundExecutions: nil, requireReceipts: true, autoCreateWorkshopExecutionFromChat: nil, enabled: nil, showTimeline: nil),
                macControlPolicy: .init(enabled: false)
            ),
            accessMode: "read_only"
        )

        #expect(state.unavailableMessage == nil)
        #expect(state.rows.map(\.id) == ["files", "tools", "external_send", "mac_control", "receipts"])
        #expect(row(state, "files").detail.contains("cannot change or delete") == true)
        #expect(row(state, "tools").detail == "Automatic runs for safe tools are off.")
        #expect(row(state, "external_send").detail.contains("require approval") == true)
        #expect(row(state, "mac_control").detail == "Mac control is off.")
        #expect(row(state, "receipts").detail.contains("must leave receipts") == true)
        #expect(state.rows.allSatisfy { $0.tone == .neutral })
    }

    @Test("broad grants and disabled receipt requirements become adverse facts")
    func adversePolicyNeverLooksLikeAProtectedConfiguration() {
        let state = TrustSafetyBoundariesPresentation.state(
            policy: policy(
                toolPolicy: .init(autoPromoteSafeTools: true, autoRunSafeTools: true, riskyToolApproval: "allow"),
                connectorPolicy: .init(defaultEnabled: nil, sendExternalMessagesRequiresApproval: false),
                workshopPolicy: .init(allowBackgroundExecutions: nil, requireReceipts: false, autoCreateWorkshopExecutionFromChat: nil, enabled: nil, showTimeline: nil),
                macControlPolicy: .init(enabled: true, shellAllowed: true, approvalRequiredFor: [])
            ),
            accessMode: "full"
        )

        #expect(row(state, "files").tone == .danger)
        #expect(row(state, "tools").tone == .danger)
        #expect(row(state, "external_send").tone == .caution)
        #expect(row(state, "mac_control").tone == .danger)
        #expect(row(state, "mac_control").detail.contains("Running terminal commands") == true)
        #expect(row(state, "receipts").tone == .danger)
    }

    @Test("a partial policy names unknown boundaries instead of filling in defaults")
    func partialPolicyIsNotSilentlyCompleted() {
        let state = TrustSafetyBoundariesPresentation.state(
            policy: policy(),
            accessMode: "workspace"
        )

        #expect(row(state, "tools").tone == .unavailable)
        #expect(row(state, "external_send").tone == .unavailable)
        #expect(row(state, "mac_control").tone == .unavailable)
        #expect(row(state, "receipts").tone == .unavailable)
    }

    private func row(
        _ state: TrustSafetyBoundariesPresentation.State,
        _ id: String
    ) -> TrustSafetyBoundaryRow {
        guard let row = state.rows.first(where: { $0.id == id }) else {
            Issue.record("missing boundary row: \(id)")
            return .init(id: id, title: "", detail: "", systemImage: "", tone: .unavailable)
        }
        return row
    }

    private func policy(
        toolPolicy: TrustToolPolicy? = nil,
        connectorPolicy: TrustConnectorPolicy? = nil,
        workshopPolicy: TrustWorkshopPolicy? = nil,
        macControlPolicy: TrustMacControlPolicy? = nil
    ) -> TrustPolicy {
        TrustPolicy(
            permissionLevel: "balanced",
            workshopPolicy: workshopPolicy,
            toolPolicy: toolPolicy,
            connectorPolicy: connectorPolicy,
            macControlPolicy: macControlPolicy
        )
    }
}
