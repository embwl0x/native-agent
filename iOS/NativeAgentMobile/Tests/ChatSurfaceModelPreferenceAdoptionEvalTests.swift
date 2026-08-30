import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.chat.adoptSurfaceModelPreferenceFromSync
final class ChatSurfaceModelPreferenceAdoptionEvalTests: XCTestCase {
    private func receiptFields() -> [String: String] {
        [
            "status": "ok", "ok": "true", "surface": "ios",
            "provider_id": "openai_oauth_direct", "model": "gpt-5.6-terra",
            "reasoning_effort": "low", "service_tier": "default",
        ]
    }

    func testCanonicalReceiptCannotOverwriteANewerSelectionEvenAfterABA() throws {
        let suite = "NativeAgentMobileTests.canonical-receipt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let receipt = try MobileSurfaceSelectionReceipt(response: receiptFields(), expectedSurface: "ios")
        // Values may have returned to the first request's exact tuple; only
        // generation proves ownership of the current selection.
        let newer = ChatRuntimeControlPresentation.Selection(
            providerID: "openai_oauth_direct", model: "gpt-5.6-sol", reasoningEffort: "high", fastMode: true
        )
        ChatRuntimeControlPresentation.persist(newer, in: defaults)
        defaults.set(3, forKey: ChatRuntimeControlPresentation.generationDefaultsKey)
        XCTAssertNil(ChatRuntimeControlPresentation.acceptReceipt(receipt, defaults: defaults, requestGeneration: 1))
        XCTAssertEqual(defaults.string(forKey: ChatRuntimeControlPresentation.modelDefaultsKey), newer.model)
        XCTAssertEqual(defaults.string(forKey: ChatRuntimeControlPresentation.effortDefaultsKey), newer.reasoningEffort)
        XCTAssertTrue(defaults.bool(forKey: ChatRuntimeControlPresentation.fastDefaultsKey))
        XCTAssertNil(ProviderSelectionRollbackPresentation.acceptReceipt(receipt, currentGeneration: 3, requestGeneration: 1))
        XCTAssertEqual(
            ProviderSelectionRollbackPresentation.acceptReceipt(receipt, currentGeneration: 3, requestGeneration: 3),
            .init(providerID: "openai_oauth_direct", modelID: "gpt-5.6-terra")
        )
    }

    func testNormalizedCanonicalReceiptRemainsProtectedFromStaleSnapshotUntilExactEcho() throws {
        let receipt = try MobileSurfaceSelectionReceipt(response: receiptFields(), expectedSurface: "ios")
        let canonical = ChatSurfaceModelPreferenceAdoption.Selection(
            providerID: receipt.providerID, model: receipt.model,
            reasoningEffort: receipt.reasoningEffort, fastMode: receipt.serviceTier == "priority"
        )
        let stale = SurfaceModelPref(model: "gpt-5.6-sol", reasoningEffort: "high", serviceTier: "priority", providerId: "openai_oauth_direct")
        let held = ChatSurfaceModelPreferenceAdoption.resolve(
            current: canonical, preference: stale, awaitingAcknowledgement: true,
            selectableProviderIDs: ["openai_oauth_direct"]
        )
        XCTAssertEqual(held.selection, canonical)
        XCTAssertTrue(held.awaitingAcknowledgement)
        XCTAssertFalse(receipt.isAcknowledged(by: stale))
        let confirmed = SurfaceModelPref(model: receipt.model, reasoningEffort: receipt.reasoningEffort, serviceTier: receipt.serviceTier, providerId: receipt.providerID)
        XCTAssertTrue(receipt.isAcknowledged(by: confirmed))
        let settled = ChatSurfaceModelPreferenceAdoption.resolve(
            current: held.selection, preference: confirmed, awaitingAcknowledgement: held.awaitingAcknowledgement,
            selectableProviderIDs: ["openai_oauth_direct"]
        )
        XCTAssertFalse(settled.awaitingAcknowledgement)
        XCTAssertEqual(settled.selection, canonical)
    }

    func testReceiptRequiresEveryCanonicalFieldAndTheExactRequestedSurface() throws {
        for key in ["status", "ok", "surface", "provider_id", "model", "reasoning_effort", "service_tier"] {
            var partial = receiptFields()
            partial.removeValue(forKey: key)
            XCTAssertThrowsError(try MobileSurfaceSelectionReceipt(response: partial, expectedSurface: "ios"), key)
        }
        XCTAssertThrowsError(try MobileSurfaceSelectionReceipt(response: receiptFields(), expectedSurface: "chat"))
        var unsupportedTier = receiptFields()
        unsupportedTier["service_tier"] = "unrecognized"
        XCTAssertThrowsError(try MobileSurfaceSelectionReceipt(response: unsupportedTier, expectedSurface: "ios"))
        var legacy = receiptFields()
        legacy["surface"] = "workshop"
        XCTAssertEqual(try MobileSurfaceSelectionReceipt(response: legacy, expectedSurface: "missions").surface, "workshop")
    }

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
