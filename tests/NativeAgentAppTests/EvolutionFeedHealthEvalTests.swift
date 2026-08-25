import Foundation
import Testing
import SelfImprovement
@testable import NativeAgentApp

private func evolutionFeedHealthRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EvolutionFeedHealth-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("EVOLUTION FEED: a failed candidate cannot age out of heartbeat visibility")
func evolutionFeedNamesStalledCandidateFailure() async throws {
    let root = evolutionFeedHealthRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let failedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let store = EvolutionProposalStore(dataRoot: root, now: { failedAt })
    let proposal = try await store.propose(
        source: .weekly,
        title: "Candidate went red",
        evidence: "The weekly review found a reproducible failure.",
        diffText: "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n"
    )
    #expect((try await store.transition(id: proposal.id, to: .building)).applied)
    #expect((try await store.transition(id: proposal.id, to: .candidateFailed)).applied)

    let assessment = await BackgroundLoopsAssembly.gatherHeartbeatAssessment(
        dataRoot: root,
        now: failedAt.addingTimeInterval(7 * 60 * 60)
    )
    #expect(!assessment.deterministicOK)
    #expect(assessment.conditionId == "evolution-candidate-failed")
    #expect(assessment.signals.contains("candidate_failed: Candidate went red"))
    #expect(assessment.fallbackAlert.contains("Candidate build/test failures have remained unresolved"))
    #expect(assessment.fallbackAlert.contains("Candidate went red"))
}
