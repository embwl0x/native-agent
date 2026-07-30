import MemoryV2
import NativeAgentCore
import Testing
@testable import NativeAgentApp

@Suite("Memory proposal presentation quality")
struct MemoryProposalPresentationTests {
    @Test("quarantines legacy invalid rows and restores real session evidence")
    func quarantineAndEvidence() throws {
        let invalid = ProposalRecord(
            id: "invalid",
            content: "user wants whatever signature you want there dont worry",
            source: "adaptive-promoter:telegram-session",
            createdAt: "2026-07-09T21:13:53Z",
            metadata: .object(["kind": .string("goal")])
        )
        #expect(NativeClient.memoryProposalPresentationRecord(
            id: invalid.id,
            content: invalid.content,
            source: invalid.source,
            status: invalid.status,
            createdAt: invalid.createdAt,
            rejectionReason: invalid.rejectionReason,
            metadata: invalid.metadata
        ) == nil)

        let valid = ProposalRecord(
            id: "valid",
            content: "user wants Slack to be live like Telegram",
            source: "adaptive-promoter:telegram-session",
            createdAt: "2026-07-09T21:13:53Z",
            metadata: .object([
                "kind": .string("goal"),
                "recurrence_count": .int(1),
                "supporting_session_ids": .array([.string("telegram-session")]),
            ])
        )
        let presented = try #require(NativeClient.memoryProposalPresentationRecord(
            id: valid.id,
            content: valid.content,
            source: valid.source,
            status: valid.status,
            createdAt: valid.createdAt,
            rejectionReason: valid.rejectionReason,
            metadata: valid.metadata
        ))
        #expect(presented.supporting_session_ids == ["telegram-session"])
        #expect(presented.recurrence_count == 1)
        #expect(presented.evidenceSummary == "Observed 1x in 1 session")

        let legacyWithoutMetadataEvidence = ProposalRecord(
            id: "legacy",
            content: "user wants Slack to be live like Telegram",
            source: "adaptive-promoter:legacy-session",
            createdAt: "2026-07-09T21:13:53Z",
            metadata: .object(["kind": .string("goal")])
        )
        let legacyPresented = try #require(NativeClient.memoryProposalPresentationRecord(
            id: legacyWithoutMetadataEvidence.id,
            content: legacyWithoutMetadataEvidence.content,
            source: legacyWithoutMetadataEvidence.source,
            status: legacyWithoutMetadataEvidence.status,
            createdAt: legacyWithoutMetadataEvidence.createdAt,
            rejectionReason: legacyWithoutMetadataEvidence.rejectionReason,
            metadata: legacyWithoutMetadataEvidence.metadata
        ))
        #expect(legacyPresented.supporting_session_ids == ["legacy-session"])
        #expect(legacyPresented.evidenceSummary == "Observed 1x in 1 session")
    }
}
