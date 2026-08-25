import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.chat.adoptSurfaceModelPreferenceFromSync
final class ChatSurfaceModelPreferenceAdoptionEvalTests: XCTestCase {
    func testStaleSnapshotCannotRevertAnyFreshLocalRuntimeControl() {
        let freshLocal = ChatSurfaceModelPreferenceAdoption.Selection(
            providerID: "openai",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            fastMode: true
        )
        let staleRemote = SurfaceModelPref(
            model: "gpt-5.4",
            reasoningEffort: "low",
            serviceTier: "default",
            providerId: "anthropic"
        )

        let resolution = ChatSurfaceModelPreferenceAdoption.resolve(
            current: freshLocal,
            preference: staleRemote,
            awaitingAcknowledgement: true,
            selectableProviderIDs: ["openai", "anthropic"]
        )

        XCTAssertEqual(resolution.selection, freshLocal)
        XCTAssertTrue(resolution.awaitingAcknowledgement)
    }

    func testMatchingSnapshotAcknowledgesFreshLocalRuntimeControlWithoutChangingIt() {
        let freshLocal = ChatSurfaceModelPreferenceAdoption.Selection(
            providerID: "openai",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            fastMode: true
        )

        let resolution = ChatSurfaceModelPreferenceAdoption.resolve(
            current: freshLocal,
            preference: .init(
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                serviceTier: "priority",
                providerId: "openai"
            ),
            awaitingAcknowledgement: true,
            selectableProviderIDs: ["openai"]
        )

        XCTAssertEqual(resolution.selection, freshLocal)
        XCTAssertFalse(resolution.awaitingAcknowledgement)
    }

    func testSettledSnapshotAdoptsEveryPublishedRuntimeControl() {
        let resolution = ChatSurfaceModelPreferenceAdoption.resolve(
            current: .init(
                providerID: "openai",
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                fastMode: true
            ),
            preference: .init(
                model: "claude-fable-5",
                reasoningEffort: "medium",
                serviceTier: "default",
                providerId: "anthropic"
            ),
            awaitingAcknowledgement: false,
            selectableProviderIDs: ["openai", "anthropic"]
        )

        XCTAssertEqual(
            resolution.selection,
            .init(
                providerID: "anthropic",
                model: "claude-fable-5",
                reasoningEffort: "medium",
                fastMode: false
            )
        )
        XCTAssertFalse(resolution.awaitingAcknowledgement)
    }
}
