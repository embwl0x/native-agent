import Foundation
import Testing
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
