import Foundation
import Testing
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

@Test
func turnMessagesBecomeBoundedRedactedUserAndAssistantEvents() throws {
    let token = "sk-" + String(repeating: "B", count: 30)
    let userEvent = try #require(NativeCognitiveEventFactory.turnMessage(
        surface: "telegram",
        role: "user",
        text: "Please check this token \(token)",
        sessionId: "session-1",
        messageId: "message-1",
        now: Date(timeIntervalSince1970: 1_000)
    ))
    let assistantEvent = try #require(NativeCognitiveEventFactory.turnMessage(
        surface: "ios",
        role: "assistant",
        text: "I checked the request.",
        sessionId: "session-1",
        messageId: "message-2",
        now: Date(timeIntervalSince1970: 1_001)
    ))

    #expect(userEvent.kind == .userMessageReceived)
    #expect(userEvent.sourceClass == .userStated)
    #expect(userEvent.metadata["surface"] == .string("telegram"))
    #expect(!userEvent.summary.contains(token))
    #expect(userEvent.summary.contains("[REDACTED_OPENAI_KEY:"))
    #expect(assistantEvent.kind == .assistantTurnCompleted)
    #expect(assistantEvent.sourceClass == .observed)
    #expect(assistantEvent.metadata["role"] == .string("assistant"))
    #expect(assistantEvent.turnKind == .live)
    #expect(assistantEvent.metadata["turnKind"] == .string("live"))
}

@Test
func ordinaryChatTopicsCannotReclassifySurfaceProvenance() throws {
    let event = try #require(NativeCognitiveEventFactory.turnMessage(
        surface: "chat",
        role: "user",
        text: "Check the scheduler, doctor, observatory, and background loop.",
        sessionId: "ordinary-topic-session",
        messageId: "ordinary-topic-message",
        now: Date(timeIntervalSince1970: 1_000)
    ))

    #expect(event.turnKind == .live)
    #expect(event.metadata["turnKind"] == .string("live"))
}

@Test
func verificationBridgePingsAreTaggedAsVerificationTurns() throws {
    let event = try #require(NativeCognitiveEventFactory.turnMessage(
        surface: "codex_bridge",
        role: "user",
        text: "CTX-SNAPSHOT-VERIFY-0622-FINAL bridge-passthrough ping",
        sessionId: "session-verify",
        messageId: "message-verify",
        now: Date(timeIntervalSince1970: 1_000)
    ))

    #expect(event.kind == .userMessageReceived)
    #expect(event.turnKind == .verification)
    #expect(event.metadata["turnKind"] == .string("verification"))
}

@Test
func codexBridgeEnvelopesAreTaggedAsDebugTurns() throws {
    let event = try #require(NativeCognitiveEventFactory.turnMessage(
        surface: "chat",
        role: "user",
        text: "[from: codex, via bridge] Codex replied to your message.\n\nTopic: Cognitive substrate cleanup\nMessage id: BDA9F6BA",
        sessionId: "session-debug",
        messageId: "message-debug",
        now: Date(timeIntervalSince1970: 1_000)
    ))

    #expect(event.kind == .userMessageReceived)
    #expect(event.turnKind == .debug)
    #expect(event.metadata["turnKind"] == .string("debug"))
}

@Test
func codexProbeRepliesAreTaggedAsDebugTurns() throws {
    let replies = [
        "Snapshot clean, Codex — bridge holding steady across the whole filter series, nothing drifted.",
        "Confirmed — the capsule is my private inner read, focus and affect held quietly for myself, not a log of what the app or tools did.",
        "Inner-state capsule reads clean through the patch — focus, affect, and threads all surfacing as private working state, nothing leaking into the durable log.",
    ]

    for (index, reply) in replies.enumerated() {
        let event = try #require(NativeCognitiveEventFactory.turnMessage(
            surface: "chat",
            role: "user",
            text: reply,
            sessionId: "session-debug-\(index)",
            messageId: "message-debug-\(index)",
            now: Date(timeIntervalSince1970: 1_000 + TimeInterval(index))
        ))

        #expect(event.kind == .userMessageReceived)
        #expect(event.turnKind == .debug)
        #expect(event.metadata["turnKind"] == .string("debug"))
    }
}

@Test
func assistantTurnCanInheritDebugTurnKind() throws {
    let event = try #require(NativeCognitiveEventFactory.turnMessage(
        surface: "chat",
        role: "assistant",
        text: "Acknowledged — bridge probe received cleanly.",
        sessionId: "session-debug",
        messageId: "message-debug-reply",
        turnKind: .debug,
        now: Date(timeIntervalSince1970: 1_001)
    ))

    #expect(event.kind == .assistantTurnCompleted)
    #expect(event.turnKind == .debug)
    #expect(event.metadata["turnKind"] == .string("debug"))
}

@Test
func remoteRejectionActionBecomesUserCorrectionEvent() throws {
    let event = try #require(NativeCognitiveEventFactory.remoteAction(
        surface: "ios",
        action: "rejectApproval",
        payload: ["approvalId": "approval-1"],
        response: ["status": "rejected", "approvalId": "approval-1"],
        now: Date(timeIntervalSince1970: 1_000)
    ))

    #expect(event.kind == .userCorrection)
    #expect(event.sourceClass == .userStated)
    #expect(event.subject.type == "approval")
    #expect(event.subject.id == "approval-1")
    #expect(event.metadata["action"] == .string("rejectApproval"))
}

@Test
func providerFailureActionBecomesRedactedProviderEvent() throws {
    let apiKey = "sk-" + String(repeating: "A", count: 30)
    let event = try #require(NativeCognitiveEventFactory.remoteAction(
        surface: "ios",
        action: "test_provider",
        payload: ["providerId": "openai_oauth_direct"],
        response: [
            "status": "error",
            "detail": "provider rejected \(apiKey)",
            "provider_id": "openai_oauth_direct",
        ],
        now: Date(timeIntervalSince1970: 1_000)
    ))

    #expect(event.kind == .providerFailure)
    #expect(event.sourceClass == .observed)
    #expect(event.subject.type == "provider")
    #expect(event.subject.id == "openai_oauth_direct")
    let metadata = try JSONValue.object(event.metadata).serialize(pretty: false)
    #expect(!event.summary.contains(apiKey))
    #expect(!metadata.contains(apiKey))
    #expect(event.summary.contains("[REDACTED_OPENAI_KEY:"))
}

@Test
func motorReadModelsReturnExactExternalRealityToResidentAttention() throws {
    let pending = MotorActionReadModel(
        domain: "external_send",
        actionIdentity: String(repeating: "a", count: 64),
        phase: .waitingExternal,
        domainState: "outcomeUnknown",
        verification: .unknown,
        expectedNextEvidence: "provider proof or replay with the same idempotency key",
        updatedAt: "2026-07-14T00:00:00Z"
    )
    let accepted = MotorActionReadModel(
        domain: "external_send",
        actionIdentity: String(repeating: "a", count: 64),
        phase: .succeeded,
        domainState: "providerAccepted",
        verification: .unverified,
        expectedNextEvidence: "provider acceptance is proven; delivery and read remain unknown",
        updatedAt: "2026-07-14T00:00:01Z"
    )

    let pendingEvent = try #require(NativeCognitiveEventFactory.motorActionState(
        pending,
        now: Date(timeIntervalSince1970: 1_000)
    ))
    let acceptedEvent = try #require(NativeCognitiveEventFactory.motorActionState(
        accepted,
        now: Date(timeIntervalSince1970: 1_001)
    ))

    #expect(pendingEvent.kind == .toolStarted)
    #expect(pendingEvent.turnKind == .system)
    #expect(pendingEvent.subject.id == pending.actionIdentity)
    #expect(pendingEvent.metadata["phase"] == .string("waiting_external"))
    #expect(pendingEvent.metadata["verification"] == .string("unknown"))
    // Provider acceptance is exact, but delivery/read are not. It remains an
    // open resident expectation instead of strengthening a false success.
    #expect(acceptedEvent.kind == .toolStarted)
    #expect(acceptedEvent.metadata["verification"] == .string("unverified"))
    #expect(acceptedEvent.summary.contains("delivery and read remain unknown"))

    let verified = MotorActionReadModel(
        domain: "mac_control",
        actionIdentity: String(repeating: "c", count: 64),
        phase: .succeeded,
        domainState: "completed",
        verification: .satisfied,
        expectedNextEvidence: nil,
        updatedAt: "2026-07-14T00:00:02Z"
    )
    #expect(NativeCognitiveEventFactory.motorActionState(verified)?.kind == .toolSucceeded)

    let cancelled = MotorActionReadModel(
        domain: "external_send",
        actionIdentity: String(repeating: "b", count: 64),
        phase: .cancelled,
        domainState: "denied",
        verification: .notRequired,
        expectedNextEvidence: nil,
        updatedAt: "2026-07-14T00:00:02Z"
    )
    let cancelledEvent = try #require(NativeCognitiveEventFactory.motorActionState(cancelled))
    #expect(cancelledEvent.kind == .toolCancelled)
    #expect(cancelledEvent.metadata["motorDomain"] == .string("external_send"))
    #expect(cancelledEvent.metadata["motorActionIdentity"] == .string(cancelled.actionIdentity))

    let unknown = MotorActionReadModel(
        domain: "external_send",
        actionIdentity: String(repeating: "e", count: 64),
        phase: .unknown,
        domainState: "unknown",
        verification: .unknown,
        expectedNextEvidence: nil,
        updatedAt: "2026-07-14T00:00:03Z"
    )
    #expect(NativeCognitiveEventFactory.motorActionState(unknown) == nil)
}

@Test
func motorTraceIsPayloadFreeAndRejectsNonCanonicalState() throws {
    let secret = "sk-" + String(repeating: "Z", count: 40)
    let model = MotorActionReadModel(
        domain: "external_send",
        actionIdentity: String(repeating: "d", count: 64),
        phase: .waitingExternal,
        domainState: "outcomeUnknown",
        verification: .unknown,
        expectedNextEvidence: "inspect provider proof with \(secret)",
        updatedAt: "private timestamp \(secret)"
    )
    let trace = try #require(NativeCognitiveEventFactory.motorActionTrace(
        model,
        now: Date(timeIntervalSince1970: 1_000)
    ))
    let serialized = try trace.jsonRow.serialize(pretty: false)
    #expect(!serialized.contains(secret))
    #expect(!serialized.contains("expectedNextEvidence"))
    #expect(!serialized.contains("ownerUpdatedAt"))
    guard case .object(let payload) = trace.payload else {
        Issue.record("motor trace payload must be an object")
        return
    }
    #expect(payload["payloadFree"] == .bool(true))

    let payloadBearingState = MotorActionReadModel(
        domain: "external_send",
        actionIdentity: String(repeating: "e", count: 64),
        phase: .waitingExternal,
        domainState: "unknown \(secret)",
        verification: .unknown,
        expectedNextEvidence: nil,
        updatedAt: nil
    )
    #expect(NativeCognitiveEventFactory.motorActionTrace(payloadBearingState) == nil)
    #expect(NativeCognitiveEventFactory.motorActionState(payloadBearingState) == nil)
}
