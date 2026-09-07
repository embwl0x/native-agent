import Foundation
import NativeAgentShared
import PersistenceCore


extension NativeClient {
    func getTrainingRuns() async throws -> [TrainingRunSummary] {
        return try await swiftGetTrainingRuns()
    }

    func getTrainingProposals() async throws -> [TrainingProposalSummary] {
        return try await swiftGetTrainingProposals()
    }

    func approveTrainingProposal(id: String) async throws -> [String: Any] {
        return try await swiftApproveTrainingProposal(id: id)
    }

    func rejectTrainingProposal(id: String, reason: String) async throws -> [String: Any] {
        return try await swiftRejectTrainingProposal(id: id, reason: reason)
    }

    func getPromotionCandidates() async throws -> [PromotionCandidateSummary] {
        return try await swiftGetPromotionCandidates()
    }

    func getPromotionPending() async throws -> [PromotionCandidateSummary] {
        return try await swiftGetPromotionPending()
    }


    func approvePromotionPending(id: String) async throws -> [String: Any] {
        let raw = try await NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
            .approvePromotionStageLocal(candidateId: id)
        return try NativeClient._jsonValueToDictionary(raw)
    }

    func rejectPromotionPending(id: String, reason: String) async throws -> [String: Any] {
        let raw = try await NativeClient._trainingPromotionActor(dataRoot: dataRootOverride)
            .rejectPromotionStageLocal(candidateId: id, reason: reason)
        return try NativeClient._jsonValueToDictionary(raw)
    }
}
