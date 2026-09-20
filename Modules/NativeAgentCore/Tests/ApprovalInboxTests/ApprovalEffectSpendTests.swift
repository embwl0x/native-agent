import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ApprovalInbox

@Test(arguments: [-1.0, 0.0, 599.0, 600.0, 601.0], [false, true])
func approvalContinuationHasOneRecentClaimAcrossSurfaces(age: TimeInterval, alreadyStarted: Bool) async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resolvedAt = Date(timeIntervalSince1970: 1_000_000)
    let mac = SwiftNativeApprovalInbox(root: root, clock: { resolvedAt })
    let row = try await mac.create(.object([
        "action": .string("tool_catalog"), "title": .string("Fixture"),
        "remoteResolvable": .bool(true), "localOnly": .bool(false),
        "payload": .object(["kind": .string("chat_tool_approval")]),
    ]))
    _ = try await mac.resolve(row.id, decision: .approved, provenance: .signedIOS(clientID: "fixture", decidedBy: "ios"))
    let telegram = SwiftNativeApprovalInbox(root: root, clock: { resolvedAt.addingTimeInterval(age) })
    #expect(try await telegram.get(row.id).decision == "approved")
    #expect(try await mac.list(filter: .pending).isEmpty)
    let eligible = (0...600).contains(age)
    #expect(try await telegram.queueChatContinuation(row.id, delivery: .object([:]), alreadyStarted: alreadyStarted) == eligible)
    async let first = telegram.annotateChatContinuation(row.id, done: false)
    let otherSurface = SwiftNativeApprovalInbox(root: root, clock: { resolvedAt.addingTimeInterval(age) })
    async let second = otherSurface.annotateChatContinuation(row.id, done: false)
    let claims = try await [first, second].filter { $0 }.count
    #expect(claims == (eligible && !alreadyStarted ? 1 : 0))
    #expect(try await otherSurface.annotateChatContinuation(row.id, done: false) == false)
    if eligible {
        _ = try await telegram.annotateChatContinuation(row.id, done: true)
        #expect(try await otherSurface.queueChatContinuation(row.id, delivery: .object([:])) == false)
    }
}

@Test func approvedReplayCannotDispatchAgainAfterRestart() async throws {
    let root = try effectSpendTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let payload: JSONValue = .object([
        "kind": .string("chat_tool_approval"), "toolName": .string("shell"),
        "surface": .string("telegram"), "input": .object([:]),
    ])
    let row = try await inbox.create(.object([
        "action": .string("shell"), "title": .string("Fixture"), "payload": payload,
    ]))
    _ = try await inbox.resolve(row.id, decision: .approved, decidedBy: "fixture")
    #expect(await inbox.consumeApprovedEffect(id: row.id,
        digest: ApprovalInboxApprovedReplayVerifier.effectDigest(payload), action: "shell", surface: "telegram") == .spent)
    let first = ApprovalInboxApprovedReplayVerifier(dataRoot: root)
    #expect(await first.verifyApprovedReplay(approvalID: row.id, tool: "shell", surface: "telegram", input: ["wrong": .bool(true)]) == .bodyMismatch)
    #expect(await first.verifyApprovedReplay(approvalID: row.id, tool: "shell", surface: "telegram", input: [:]) == .verified)
    let restarted = ApprovalInboxApprovedReplayVerifier(dataRoot: root)
    #expect(await restarted.verifyApprovedReplay(approvalID: row.id, tool: "shell", surface: "telegram", input: [:]) == .alreadyConsumed)
}

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
