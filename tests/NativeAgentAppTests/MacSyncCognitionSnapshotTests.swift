import Foundation
import Testing
import NativeAgentShared
@testable import NativeAgentApp

@Test
func cognitionSnapshotEdgesAreMutationDrivenAndBounded() {
    func change(_ reason: String) -> NativeCognitionRuntimeChange {
        NativeCognitionRuntimeChange(revision: 1, occurredAt: Date(), reason: reason)
    }

    #expect(MacSyncEngine.shouldWriteSnapshot(for: change("configuration:subconscious_master")))
    #expect(MacSyncEngine.shouldWriteSnapshot(for: change("configuration:onboarding_transition")))
    #expect(MacSyncEngine.shouldWriteSnapshot(for: change("organism:settled")))
    #expect(MacSyncEngine.shouldWriteSnapshot(for: change("microcycle_settlement:finished")))
    #expect(MacSyncEngine.shouldWriteSnapshot(for: change("residual_repair:completed")))

    #expect(!MacSyncEngine.shouldWriteSnapshot(for: change("bootstrap")))
    #expect(!MacSyncEngine.shouldWriteSnapshot(for: change("event:userMessage")))
    #expect(!MacSyncEngine.shouldWriteSnapshot(for: change("maintenance:completed")))
}

@Test
func organismLivingStatusWriterReplacesIncompleteDeskReadsAndPreservesDisabledState() {
    func status(enabled: Bool, availability: OrganismLivingStatusAvailability) -> OrganismLivingStatusFile {
        OrganismLivingStatusFile(
            generatedAt: Date(timeIntervalSinceReferenceDate: 20_000),
            enabled: enabled,
            posture: enabled ? "steady" : "off",
            bodyLine: nil,
            behaviorLine: enabled ? "careful" : "off",
            needsUser: false,
            needsAttention: false,
            signalCount: 0,
            lastSignalAt: nil,
            body: OrganismLivingBodyFile(
                macAwake: true, iPhoneReachable: true, providersHealthy: true,
                memoryHealthy: true, dreamHealthy: true, toolHandsAvailable: true,
                approvalChannelsOpen: true, notificationPathHealthy: true,
                resourcePressure: "nominal"
            ),
            counters: OrganismLivingCountersFile(
                fieldNodes: 0, pendingPredictions: 0, dreamRepairs: 0,
                reflexCandidates: 0, reflexesNeedReview: 0,
                approvedReflexBiases: nil, standingViewProposals: nil
            ),
            reflexCandidates: [],
            standingViewProposals: [],
            availability: availability
        )
    }

    let complete = status(enabled: true, availability: .live)
    let unavailable = MacSyncEngine.organismLivingStatusAfterDeskRead(
        complete,
        deskReadSucceeded: false
    )
    #expect(unavailable.availabilityState == .unavailable)
    #expect(unavailable.unavailableReason == "desk_status_unavailable")
    #expect(unavailable.generatedAt == complete.generatedAt)

    let disabled = status(enabled: false, availability: .disabled)
    #expect(
        MacSyncEngine.organismLivingStatusAfterDeskRead(disabled, deskReadSucceeded: false)
            .availabilityState == .disabled
    )
    #expect(
        MacSyncEngine.organismLivingStatusAfterDeskRead(complete, deskReadSucceeded: true)
            .availabilityState == .live
    )
}
