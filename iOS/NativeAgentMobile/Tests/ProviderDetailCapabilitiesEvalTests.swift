import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.providers.detail.capabilities
final class ProviderDetailCapabilitiesEvalTests: XCTestCase {
    func testEveryPublishedModelKeepsItsOwnNamedCapabilityProfile() {
        let rows = ProviderCapabilityPresentation.models(from: [
            model(id: "vision-model", name: "Vision Model", vision: true, tools: false),
            model(id: "tools-model", name: "Tools Model", vision: false, tools: true),
        ])

        XCTAssertEqual(rows.map(\.name), ["Vision Model", "Tools Model"])
        XCTAssertEqual(rows.map(\.supportsVision), [true, false])
        XCTAssertEqual(rows.map(\.supportsTools), [false, true])
        XCTAssertNotEqual(rows[0], rows[1])
    }

    func testNoModelsProducesNoFabricatedProviderWideCapabilityClaim() {
        XCTAssertTrue(ProviderCapabilityPresentation.models(from: []).isEmpty)
    }

    func testDetailSheetRendersTheNamedModelProfilesInsteadOfAnArbitraryFirstModel() throws {
        let source = try MobileEvalSources.mobileSource("ProviderSettingsView.swift")
        let detailSheet = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "ProviderDetailSheet", keyword: "struct", in: source)
        )

        XCTAssertTrue(detailSheet.contains("ProviderCapabilityPresentation.models(from: provider.models)"))
        XCTAssertTrue(detailSheet.contains("ForEach(capabilityModels)"))
        XCTAssertFalse(detailSheet.contains("provider.models.first"))
    }

    private func model(id: String, name: String, vision: Bool, tools: Bool) -> ProviderModelInfo {
        ProviderModelInfo(
            id: id,
            name: name,
            context_length: 128_000,
            supports_streaming: true,
            supports_vision: vision,
            supports_tools: tools,
            supports_json_mode: true,
            cost_per_1k_in: nil,
            cost_per_1k_out: nil
        )
    }
}
