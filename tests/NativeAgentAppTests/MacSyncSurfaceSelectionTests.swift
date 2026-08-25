import Testing
import ProviderRouting

@testable import NativeAgentApp

@Suite("MacSync surface selection")
struct MacSyncSurfaceSelectionTests {
    @Test
    func unpinChatSessionAcceptsOnlySafeExactSessionIdentity() {
        #expect(MacSyncActionRouter.unpinChatSessionID(from: ["sessionId": " chat-123 "]) == "chat-123")
        #expect(MacSyncActionRouter.unpinChatSessionID(from: ["session_id": "telegram:42"]) == "telegram:42")
        #expect(MacSyncActionRouter.unpinChatSessionID(from: [:]) == nil)
        #expect(MacSyncActionRouter.unpinChatSessionID(from: ["sessionId": "../escape"]) == nil)
        #expect(MacSyncActionRouter.unpinChatSessionID(from: ["sessionId": "folder/chat"]) == nil)
    }

    @Test
    func acceptsACompleteCanonicalExecutionTuple() throws {
        let request = try #require(MacSyncActionRouter.surfaceSelection(from: [
            "surface": " iOS ",
            "provider_id": "anthropic_oauth_direct",
            "model": "claude-opus-4-8",
            "reasoning_effort": " HIGH ",
            "service_tier": " PRIORITY ",
        ]))

        #expect(request.surface == "ios")
        #expect(request.providerID == "anthropic_oauth_direct")
        #expect(request.model == "claude-opus-4-8")
        #expect(request.reasoningEffort == "high")
        #expect(request.serviceTier == "priority")
    }

    @Test(arguments: [
        ["surface": "unknown", "provider_id": "codex", "model": "gpt-5.6-sol", "reasoning_effort": "high"],
        ["surface": "ios", "provider_id": "", "model": "gpt-5.6-sol", "reasoning_effort": "high"],
        ["surface": "ios", "provider_id": "codex", "model": "", "reasoning_effort": "high"],
        ["surface": "ios", "provider_id": "codex", "model": "gpt-5.6-sol", "reasoning_effort": "invalid"],
        ["surface": "ios", "provider_id": "codex", "model": "gpt-5.6-sol", "reasoning_effort": "high", "service_tier": "turbo"],
    ])
    func rejectsUnknownOrIncompleteTuples(payload: [String: String]) {
        #expect(MacSyncActionRouter.surfaceSelection(from: payload) == nil)
    }

    @Test
    func responseUsesRecoveredCanonicalValuesInsteadOfOptimisticRequest() {
        let response = MacSyncActionRouter.canonicalSurfaceSelectionResponse(
            surface: "chat",
            providerID: "openai_oauth_direct",
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            serviceTier: "default"
        )

        #expect(response["surface"] == "chat")
        #expect(response["provider_id"] == "openai_oauth_direct")
        #expect(response["model"] == "gpt-5.6-sol")
        #expect(response["reasoning_effort"] == "medium")
        #expect(response["service_tier"] == "default")
    }

    @Test
    func surfaceModelResponseFailsClosedUntilTheCanonicalOwnerReadsItBack() {
        let missing = MacSyncActionRouter.canonicalSurfaceModelResponse(
            surface: "ios",
            requestedModel: "gpt-5.6-sol",
            recoveredPreference: nil
        )
        #expect(missing["ok"] == "false")
        #expect(missing["applied"] == "false")

        let stale = MacSyncActionRouter.canonicalSurfaceModelResponse(
            surface: "ios",
            requestedModel: "gpt-5.6-sol",
            recoveredPreference: SurfacePreference(
                surface: "ios",
                model: "gpt-5.4",
                reasoningEffort: "medium"
            )
        )
        #expect(stale["status"] == "error")
        #expect(stale["applied"] == "false")

        let applied = MacSyncActionRouter.canonicalSurfaceModelResponse(
            surface: "ios",
            requestedModel: "gpt-5.6-sol",
            recoveredPreference: SurfacePreference(
                surface: "ios",
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                serviceTier: "priority"
            )
        )
        #expect(applied["ok"] == "true")
        #expect(applied["applied"] == "true")
        #expect(applied["model"] == "gpt-5.6-sol")
        #expect(applied["reasoning_effort"] == "high")
        #expect(applied["service_tier"] == "priority")
    }

    @Test
    func macIntegrationPermissionAcceptsOnlyKnownIDsAndExactBooleans() throws {
        let request = try #require(MacSyncActionRouter.macIntegrationPermissionRequest(from: [
            "id": "calendar",
            "read": "true",
            "write": "false",
        ]))
        #expect(request.id == "calendar")
        #expect(request.read)
        #expect(!request.write)

        #expect(MacSyncActionRouter.macIntegrationPermissionRequest(from: [
            "id": "unknown", "read": "true", "write": "false",
        ]) == nil)
        #expect(MacSyncActionRouter.macIntegrationPermissionRequest(from: [
            "id": "calendar", "read": "1", "write": "false",
        ]) == nil)
        #expect(MacSyncActionRouter.macIntegrationPermissionRequest(from: [
            "id": "calendar", "read": "true",
        ]) == nil)
    }
}
