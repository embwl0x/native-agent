import Foundation
import Testing
@testable import ApprovalInbox

private func effectSpendTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApprovalEffectSpendTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func approvedEffectSpendIsSingleUseAcrossInboxInstances() async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = SwiftNativeApprovalInbox(root: root)
    let second = SwiftNativeApprovalInbox(root: root)

    let won = await first.consumeApprovedEffect(
        id: "approval-1", digest: "digest-1", action: "shell", surface: "chat"
    )
    let replay = await second.consumeApprovedEffect(
        id: "approval-1", digest: "digest-1", action: "shell", surface: "chat"
    )

    #expect(won == .spent)
    #expect(replay == .alreadySpent)
}

@Test func approvedEffectSpendCorruptionFailsClosedAndPreservesBytes() async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let path = inbox.effectSpendPath
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let corrupt = Data("{not-json".utf8)
    try corrupt.write(to: path)

    let outcome = await inbox.consumeApprovedEffect(
        id: "approval-1", digest: "digest-1", action: "shell", surface: "chat"
    )

    #expect(outcome == .unavailable)
    #expect(try Data(contentsOf: path) == corrupt)
}

@Test func concurrentApprovedEffectSpendHasOneWinner() async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let outcomes = await withTaskGroup(of: ApprovalEffectSpendOutcome.self) { group in
        for _ in 0..<12 {
            group.addTask {
                await SwiftNativeApprovalInbox(root: root).consumeApprovedEffect(
                    id: "approval-race",
                    digest: "digest-race",
                    action: "file_write",
                    surface: "chat"
                )
            }
        }
        var values: [ApprovalEffectSpendOutcome] = []
        for await value in group { values.append(value) }
        return values
    }

    #expect(outcomes.filter { $0 == .spent }.count == 1)
    #expect(outcomes.filter { $0 == .alreadySpent }.count == 11)
}

// REPORTS-ONLY -> executable boundary checks (Wave 1):
// core.misc / approvals.effectSpend
@Test func effectSpendRejectsBlankAuthorityFieldsWithoutCreatingALedger() async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)

    let outcome = await inbox.consumeApprovedEffect(
        id: " approval ", digest: " ", action: "shell", surface: "chat"
    )
    #expect(outcome == .unavailable)
    let path = inbox.effectSpendPath
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func effectSpendPersistsTheExactFirstBoundaryIdentity() async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let inbox = SwiftNativeApprovalInbox(root: root, clock: { instant })

    #expect(await inbox.consumeApprovedEffect(
        id: " approval ", digest: " digest ", action: " shell ", surface: " chat "
    ) == .spent)
    let marker = try #require(await inbox.approvedEffectSpend(id: "approval"))
    guard case .object(let fields) = marker else {
        Issue.record("missing durable spend marker")
        return
    }
    #expect(fields["digest"] == .string("digest"))
    #expect(fields["action"] == .string("shell"))
    #expect(fields["surface"] == .string("chat"))
    #expect(fields["spentAt"] != nil)
    #expect(await inbox.consumeApprovedEffect(
        id: "approval", digest: "different", action: "other", surface: "bridge"
    ) == .alreadySpent)
}

// REPORTS-ONLY -> executable boundary check (Wave 1):
// core.misc / approvals.store.requests
@Test func approvalRequestCreationSurvivesARealStoreReloadWithItsFixedClock() async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let writer = SwiftNativeApprovalInbox(root: root, clock: { instant })
    let created = try await writer.create(.object([
        "title": .string("Approve fixture"),
        "action": .string("workflow_step"),
        "risk": .string("medium"),
        "reason": .string("real store round trip"),
    ]))
    let reader = SwiftNativeApprovalInbox(root: root, clock: { instant })
    let reloaded = try await reader.get(created.id)
    let path = await writer.approvalsPath
    #expect(reloaded.id == created.id)
    #expect(reloaded.status == "pending")
    #expect(reloaded.createdAt == created.createdAt)
    #expect(FileManager.default.fileExists(atPath: path.path))
}
