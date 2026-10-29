import Combine
import Foundation
import NativeAgentShared
import SwiftUI
import CloudKit
// Blueprint: | `MemoryStore.swift` | Memory refresh, deletion and proposal decision state |

@MainActor
final class MemoryStore: ObservableObject {
    var memories: [MemoryRecord] { iCloudSyncEngine.shared.memories }
    var memoryProposals: [MemoryProposalRecord] { iCloudSyncEngine.shared.memoryProposals }
    @Published var decidingMemoryProposalIDs: Set<String> = []
    @Published var deletingMemoryIDs: Set<String> = []
    @Published var isLoading = false
    @Published var error: String?

    func refresh(preservingActionError: Bool = false) async {
        isLoading = true
        if !preservingActionError { error = nil }
        await iCloudSyncEngine.shared.refreshMemorySnapshot()
        if !preservingActionError || error == nil {
            error = MemoryErrorLinePresentation.visibleMessage(iCloudSyncEngine.shared.syncError)
        }
        isLoading = false
    }

    func dismissError() {
        error = nil
    }

    func approveMemoryProposal(_ proposal: MemoryProposalRecord) {
        decideMemoryProposal(proposal, approve: true)
    }

    func rejectMemoryProposal(_ proposal: MemoryProposalRecord) {
        decideMemoryProposal(proposal, approve: false)
    }

    private func decideMemoryProposal(_ proposal: MemoryProposalRecord, approve: Bool) {
        Task { @MainActor in
            await performMemoryProposalDecision(proposal, approve: approve)
            if error != nil { await refresh(preservingActionError: true) }
        }
    }

    /// The sync owner adopts the Mac's confirmed memory and proposal readback.
    @discardableResult
    func performMemoryProposalDecision(
        _ proposal: MemoryProposalRecord,
        approve: Bool
    ) async -> Result<Void, Error>? {
        guard !decidingMemoryProposalIDs.contains(proposal.id) else { return nil }
        error = nil
        decidingMemoryProposalIDs.insert(proposal.id)
        defer { decidingMemoryProposalIDs.remove(proposal.id) }

        do {
            if approve {
                _ = try await iCloudSyncEngine.shared.approveMemoryProposal(proposalId: proposal.id)
            } else {
                _ = try await iCloudSyncEngine.shared.rejectMemoryProposal(proposalId: proposal.id)
            }
            return .success(())
        } catch {
            if case SyncError.responseUnconfirmed = error {
                self.error = "Decision sent; waiting for Mac/iCloud to publish the result."
            } else {
                self.error = error.localizedDescription
            }
            return .failure(error)
        }
    }

    func deleteMemory(_ memory: MemoryRecord) {
        guard !deletingMemoryIDs.contains(memory.id) else { return }
        error = nil
        deletingMemoryIDs.insert(memory.id)

        Task {
            do {
                try await iCloudSyncEngine.shared.deleteMemory(id: memory.id)
            } catch {
                self.error = error.localizedDescription
                await refresh(preservingActionError: true)
            }
            self.deletingMemoryIDs.remove(memory.id)
        }
    }
}
