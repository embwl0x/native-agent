import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.providers.surfaceProviderPicker`.
final class SurfaceProviderPickerEvalTests: XCTestCase {
    func test_switchEmitsAValidProviderModelPairAndFailureRestoresTheProvider() {
        let alpha = provider(id: "alpha", models: ["alpha-model"])
        let beta = provider(id: "beta", models: ["beta-model", "beta-second"])
        let providers = [alpha, beta]

        let switched = SurfaceProviderPickerPresentation.selection(
            providerID: "beta",
            currentModelID: "alpha-model",
            providers: providers
        )
        XCTAssertEqual(switched, .init(providerID: "beta", modelID: "beta-model"))
        XCTAssertTrue(beta.models.contains(where: { $0.id == switched?.modelID ?? "" }))

        let retained = SurfaceProviderPickerPresentation.selection(
            providerID: "beta",
            currentModelID: "beta-second",
            providers: providers
        )
        XCTAssertEqual(retained, .init(providerID: "beta", modelID: "beta-second"))

        XCTAssertEqual(
            SurfaceProviderPickerPresentation.rollbackProviderID(previousProviderID: "alpha"),
            "alpha"
        )
        XCTAssertNil(
            SurfaceProviderPickerPresentation.selection(
                providerID: "empty", currentModelID: nil,
                providers: providers + [provider(id: "empty", models: [])]
            )
        )
    }

    private func provider(id: String, models: [String]) -> ProviderInfo {
        ProviderInfo(
            provider_id: id,
            display_name: id.capitalized,
            auth_modes: [],
            auth_status: ProviderAuthStatus(
                provider_id: id, state: "ready", detail: "ready",
                user_info: nil, last_checked_at: nil
            ),
            models: models.map { modelID in
                ProviderModelInfo(
                    id: modelID,
                    name: modelID,
                    context_length: 128_000,
                    supports_streaming: true,
                    supports_vision: false,
                    supports_tools: true,
                    supports_json_mode: true,
                    cost_per_1k_in: nil,
                    cost_per_1k_out: nil
                )
            }
        )
    }
}
