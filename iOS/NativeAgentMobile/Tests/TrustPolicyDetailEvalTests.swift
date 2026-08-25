import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.trustpolicy.detail`.
///
/// Older or partial policy snapshots omit optional settings. The detail screen
/// must not present an omitted value as an explicit disabled setting.
final class TrustPolicyDetailEvalTests: XCTestCase {
    // Coverage-ledger fence `ios.settings.trustPolicy.summary`.
    func test_missingPolicySummaryFieldsRenderAsUnknownInsteadOfAValue() throws {
        let missing = TrustPolicy(
            permissionLevel: nil,
            autonomyDefault: nil,
            requireBackups: nil,
            outsideDefault: nil,
            developerMode: nil,
            workshopPolicy: nil,
            toolPolicy: nil,
            filePolicy: nil,
            connectorPolicy: nil,
            providerPolicy: nil,
            trainingPolicy: nil,
            updatedAt: nil,
            macControlPolicy: nil
        )

        XCTAssertEqual(
            TrustPolicySummaryPresentation.textValue(missing.permissionLevel),
            TrustPolicySummaryPresentation.unknownValue
        )
        XCTAssertEqual(
            TrustPolicySummaryPresentation.textValue(missing.autonomyDefault),
            TrustPolicySummaryPresentation.unknownValue
        )
        XCTAssertEqual(
            TrustPolicySummaryPresentation.textValue(missing.effectiveOutsideDefault),
            TrustPolicySummaryPresentation.unknownValue
        )
        XCTAssertEqual(
            TrustPolicySummaryPresentation.textValue(" \n "),
            TrustPolicySummaryPresentation.unknownValue
        )
        XCTAssertEqual(TrustPolicySummaryPresentation.textValue("supervised"), "supervised")
    }

    func test_trustPolicySummaryAlwaysRendersEveryOptionalTextField() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        let summary = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "TrustPolicyView", keyword: "struct", in: source)
        )

        XCTAssertTrue(summary.contains("TrustPolicySummaryPresentation.textValue(policy.permissionLevel)"))
        XCTAssertTrue(summary.contains("TrustPolicySummaryPresentation.textValue(policy.autonomyDefault)"))
        XCTAssertTrue(summary.contains("TrustPolicySummaryPresentation.textValue(policy.effectiveOutsideDefault)"))
        XCTAssertFalse(summary.contains("if let outside = policy.effectiveOutsideDefault"))
    }

    func test_absentBooleanIsDistinctFromAnExplicitDisabledPolicy() {
        let unknown = TrustPolicyDetailPresentation.booleanValue(
            nil,
            enabled: "On",
            disabled: "Off"
        )

        XCTAssertEqual(unknown, "Not reported by the Mac")
        XCTAssertEqual(
            TrustPolicyDetailPresentation.booleanValue(false, enabled: "On", disabled: "Off"),
            "Off"
        )
        XCTAssertNotEqual(unknown, "Off")
    }

    func test_trustDetailMapsEveryOptionalBooleanThroughTriStatePresentation() {
        let policy = TrustPolicy(
            permissionLevel: nil,
            autonomyDefault: nil,
            requireBackups: false,
            outsideDefault: nil,
            developerMode: nil,
            workshopPolicy: TrustWorkshopPolicy(enabled: nil, showTimeline: false),
            toolPolicy: nil,
            filePolicy: nil,
            connectorPolicy: nil,
            providerPolicy: nil,
            trainingPolicy: TrustTrainingPolicy(autonomousTraining: true, dreamScheduler: nil),
            updatedAt: nil,
            macControlPolicy: nil
        )

        let settings = TrustPolicyDetailPresentation.booleanSettings(for: policy)
        XCTAssertEqual(settings.count, 6)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: settings.map { ($0.title, $0.value) }),
            [
                "Developer Mode": "Not reported by the Mac",
                "Require Backups": "No",
                "Workshop Enabled": "Not reported by the Mac",
                "Show Timeline": "No",
                "Autonomous Training": "On",
                "Dream Scheduler": "Not reported by the Mac",
            ]
        )
    }
}
