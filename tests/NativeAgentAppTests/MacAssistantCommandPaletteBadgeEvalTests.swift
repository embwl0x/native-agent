import Foundation
import CommandPalette
import MacAssistantStatus
import NativeAgentCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: core.maccontrol / macassistant.commandPaletteBadge
//
// The command palette must consume its Mac Assistant status from the same
// lightweight native producer as the watch panel. This covers the producer →
// context → palette-entry boundary, including honest unavailable/stale input.

private struct FixedMacAssistantStatusClient: MacAssistantStatusClient {
    let result: MacAssistantStatusResult

    func macAssistantStatus(lightweight: Bool) async throws -> MacAssistantStatusResult {
        result
    }
}

private struct UnavailableMacAssistantStatusClient: MacAssistantStatusClient {
    enum Failure: Error { case unavailable }

    func macAssistantStatus(lightweight: Bool) async throws -> MacAssistantStatusResult {
        throw Failure.unavailable
    }
}

private func macAssistantPaletteEntry(_ context: CommandPaletteContext) throws -> CommandPaletteEntry {
    try #require(commandPaletteEntries(context: context).first { $0.id == "mac-assistant-watch-setup" })
}

private func staleMacAssistantStatus(templateAttentionCount: Int) -> MacAssistantStatusResult {
    MacAssistantStatusResult(
        status: "stale",
        summary: "The last Mac assistant reading is stale.",
        access: [],
        watchTemplates: [],
        blockedAccessCount: 0,
        templateAttentionCount: templateAttentionCount,
        schedulerActions: [],
        createsJobs: false,
        lazyContract: .object([:]),
        createdAt: "2026-08-24T00:00:00+00:00"
    )
}

@Test("Mac Assistant palette badge is projected from its native producer and never defaults healthy")
func macAssistantCommandPaletteBadge_projectsNativeStatusAndHonestAdverseStates() async throws {
    let paletteBuilder = NativeClient(baseURL: "")

    // This is the real native producer, deliberately configured so its own
    // watch-template calculation produces attention and a non-zero badge.
    let attentionProducer = makeMacAssistantStatusClient(
        loadTrustPolicy: { [:] },
        proofs: StaticConnectorProofProvider(),
        push: StaticMobilePushStatusProvider(),
        dispatcherTools: StaticDispatcherToolAvailabilityProvider(),
        localPIM: StaticLocalPIMStatusProvider()
    )
    let expectedAttention = try await attentionProducer.macAssistantStatus(lightweight: true)
    #expect(expectedAttention.status == "attention")
    #expect(expectedAttention.templateAttentionCount > 0)
    let attentionContext = await paletteBuilder.makeCommandPaletteContext(
        macAssistantStatusClient: attentionProducer
    )
    let attentionEntry = try macAssistantPaletteEntry(attentionContext)
    #expect(attentionContext.macAssistantStatus == expectedAttention.status)
    #expect(attentionContext.macAssistantTemplateAttentionCount == expectedAttention.templateAttentionCount)
    #expect(attentionEntry.status == expectedAttention.status)
    #expect(attentionEntry.count == expectedAttention.templateAttentionCount)

    // A fully ready real producer has a genuine zero template-attention count;
    // the palette preserves it instead of treating every zero as unavailable.
    let readyProducer = makeMacAssistantStatusClient(
        loadTrustPolicy: {
            [
                "macControlPolicy": .object([
                    "enabled": .bool(true),
                    "notifications_allowed": .bool(true),
                ]),
            ]
        },
        proofs: StaticConnectorProofProvider(proofs: [
            "email": ["verified": .bool(true)],
            "calendar": ["verified": .bool(true)],
        ]),
        push: StaticMobilePushStatusProvider(value: ["status": .string("ready")]),
        dispatcherTools: StaticDispatcherToolAvailabilityProvider(),
        localPIM: StaticLocalPIMStatusProvider(statuses: [
            "local_mail": ["status": .string("ready")],
            "local_calendar": ["status": .string("ready")],
            "local_reminders": ["status": .string("ready")],
        ])
    )
    let expectedReady = try await readyProducer.macAssistantStatus(lightweight: true)
    #expect(expectedReady.status == "ready")
    #expect(expectedReady.templateAttentionCount == 0)
    let readyContext = await paletteBuilder.makeCommandPaletteContext(
        macAssistantStatusClient: readyProducer
    )
    let readyEntry = try macAssistantPaletteEntry(readyContext)
    #expect(readyEntry.status == "ready")
    #expect(readyEntry.count == 0)

    // Status vocabularies can add stale; the palette must carry that state
    // rather than overwriting it with the historical ready/zero literals.
    let staleResult = staleMacAssistantStatus(templateAttentionCount: 3)
    let staleContext = await paletteBuilder.makeCommandPaletteContext(
        macAssistantStatusClient: FixedMacAssistantStatusClient(result: staleResult)
    )
    let staleEntry = try macAssistantPaletteEntry(staleContext)
    #expect(staleEntry.status == "stale")
    #expect(staleEntry.count == 3)

    let unavailableContext = await paletteBuilder.makeCommandPaletteContext(
        macAssistantStatusClient: UnavailableMacAssistantStatusClient()
    )
    let unavailableEntry = try macAssistantPaletteEntry(unavailableContext)
    #expect(unavailableEntry.status == "unavailable")
    #expect(unavailableEntry.count == 0)
}
