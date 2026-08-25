import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.policyMapDisclosure
@Suite("Trust Center policy map disclosure")
struct TrustPolicyMapDisclosureEvalTests {
    private func policy(developerMode: Bool, remoteFromIosAllowed: Bool) -> TrustPolicy {
        TrustPolicy(
            developerMode: developerMode,
            macControlPolicy: TrustMacControlPolicy(
                enabled: true,
                remoteFromIosAllowed: remoteFromIosAllowed
            )
        )
    }

    private func writerPolicy(
        mode: String,
        developerMode: Bool,
        remoteFromIosAllowed: Bool
    ) throws -> TrustMacControlPolicy {
        let wire = NativeClient.macControlPolicyForAccessMode(
            mode,
            remoteFromIosAllowed: remoteFromIosAllowed,
            developerMode: developerMode
        )
        let data = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        return try JSONDecoder().decode(TrustMacControlPolicy.self, from: data)
    }

    @Test("policy-map disclosure persists its expansion choice without inventing a policy")
    func disclosureExpansionRoundTripsAcrossFreshReaders() throws {
        let suite = "NativeAgent.TrustPolicyMapDisclosure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!TrustPolicyMapDisclosurePresentation.isExpanded(in: defaults))
        TrustPolicyMapDisclosurePresentation.setExpanded(true, in: defaults)
        let freshExpandedReader = try #require(UserDefaults(suiteName: suite))
        #expect(TrustPolicyMapDisclosurePresentation.isExpanded(in: freshExpandedReader))
        #expect(TrustPolicyMapPresentation.resolve(policy: nil, activeMode: "workspace") == .policyUnavailable)

        TrustPolicyMapDisclosurePresentation.setExpanded(false, in: freshExpandedReader)
        let freshCollapsedReader = try #require(UserDefaults(suiteName: suite))
        #expect(!TrustPolicyMapDisclosurePresentation.isExpanded(in: freshCollapsedReader))
    }

    @Test("map withholds claims while the actual policy is unavailable")
    func unavailablePolicyDoesNotRenderGuessedCapabilities() {
        #expect(
            TrustPolicyMapPresentation.resolve(policy: nil, activeMode: "workspace")
                == .policyUnavailable
        )
    }

    @Test("every rendered mode reflects the same capability template the mode writer persists")
    func renderedRowsTrackTheRealModeWriter() throws {
        let developerMode = true
        let remoteFromIosAllowed = true
        guard case let .rows(rows) = TrustPolicyMapPresentation.resolve(
            policy: policy(
                developerMode: developerMode,
                remoteFromIosAllowed: remoteFromIosAllowed
            ),
            activeMode: "workspace"
        ) else {
            Issue.record("available policy must render capability rows")
            return
        }

        #expect(rows.map(\.mode) == ["auto", "read_only", "workspace", "full"])
        #expect(rows.filter(\.isActive).map(\.mode) == ["workspace"])
        for row in rows {
            let writer = try writerPolicy(
                mode: row.mode,
                developerMode: developerMode,
                remoteFromIosAllowed: remoteFromIosAllowed
            )
            #expect(row.macControlPolicy == writer)
            #expect(row.macControlAllowed == (writer.enabled))
            #expect(row.shellAllowed == (writer.enabled && writer.shellAllowed))
            #expect(row.iosRemoteAllowed == (writer.enabled && writer.remoteFromIosAllowed))
        }
    }

    @Test("full mode keeps shell and system control unavailable without Developer Mode")
    func fullModeDoesNotOverclaimDeveloperOnlyCapabilities() {
        guard case let .rows(rows) = TrustPolicyMapPresentation.resolve(
            policy: policy(developerMode: false, remoteFromIosAllowed: true),
            activeMode: "full"
        ), let full = rows.first(where: { $0.mode == "full" }) else {
            Issue.record("full row must be present for an available policy")
            return
        }

        #expect(full.macControlAllowed)
        #expect(!full.shellAllowed)
        #expect(!full.macControlPolicy.systemControlAllowed)
        #expect(full.iosRemoteAllowed)
    }
}
