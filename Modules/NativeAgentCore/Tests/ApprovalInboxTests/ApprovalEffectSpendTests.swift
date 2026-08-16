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
