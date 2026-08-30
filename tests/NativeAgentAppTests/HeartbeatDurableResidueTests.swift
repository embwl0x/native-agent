import Foundation
import Testing
import NativeAgentCore
import NotificationInbox
import PersistenceCore
@testable import NativeAgentApp

private func durableResidueRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("heartbeat-residue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeWorkflowState(
    root: URL,
    id: String,
    status: String,
    updatedAt: String
) throws {
    let directory = root.appendingPathComponent("workflows/run_state", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let row: JSONValue = .object([
        "id": .string(id),
        "status": .string(status),
        "updatedAt": .string(updatedAt),
    ])
    try Data(try row.serialize(pretty: false).utf8)
        .write(to: directory.appendingPathComponent("\(id).json"))
}

private func appendOldDeskItem(root: URL, title: String, timestamp: String) throws {
    let store = SwiftNativeDeskStore(dataRoot: root)
    try FileManager.default.createDirectory(
        at: store.opsPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let op = DeskOp(
        ts: timestamp,
        handle: "desk_old-review-item",
        body: .createItem(
            alias: "1",
            kind: .plan,
            project: "NativeAgent",
            title: title,
            parent: nil,
            summary: nil,
            assignee: nil,
            laneOf: nil,
            origin: .owner,
            pursuit: nil
        )
    )
    try Data((try op.toJSON().serialize(pretty: false) + "\n").utf8).write(to: store.opsPath)
}

private func inboxObject(id: String, root: URL) async throws -> [String: JSONValue]? {
    let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: root))
    for row in try await inbox.rows() {
        guard case .object(let object) = row,
              object["id"] == .string(id) else { continue }
        return object
    }
    return nil
}

@Test("heartbeat projects durable residue as review-only bounded counts")
func heartbeatProjectsDurableResidueWithoutMutatingIt() async throws {
    let root = try durableResidueRoot()
    let config = try durableResidueRoot()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: config)
    }
    try writeWorkflowState(
        root: root,
        id: "old-waiting",
        status: "waiting_approval",
        updatedAt: "2026-05-06T17:03:15Z"
    )
    try writeWorkflowState(
        root: root,
        id: "old-complete",
        status: "succeeded",
        updatedAt: "2026-05-06T17:03:15Z"
    )
    try appendOldDeskItem(
        root: root,
        title: "Review an old open item",
        timestamp: "2026-06-01T00:00:00Z"
    )
    let undelivered = config
        .appendingPathComponent("codex-nativeagent-bridge/reply-jobs/undelivered", isDirectory: true)
    try FileManager.default.createDirectory(at: undelivered, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: undelivered.appendingPathComponent("one.json"))
    try Data("{}".utf8).write(to: undelivered.appendingPathComponent("two.json"))
    try Data("ignore".utf8).write(to: undelivered.appendingPathComponent("note.txt"))
    let bridge = config.appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
    let inbox = bridge.appendingPathComponent("codex-inbox.jsonl")
    let deliveries = bridge.appendingPathComponent("reply-deliveries.jsonl")
    try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
    try Data([
        #"{"id":"dead-1","createdAt":"2026-08-27T12:00:00Z","topic":"failed handoff","read":false,"deliveryStatus":"dead_letter","deliveryFailureReason":"terminal_result"}"#,
        #"{"id":"stale-1","createdAt":"2026-08-27T12:00:00Z","topic":"abandoned handoff","read":false}"#,
        #"{"id":"legacy-delivered","createdAt":"2026-08-27T12:00:00Z","topic":"old but delivered","read":false}"#,
    ].joined(separator: "\n").appending("\n").utf8).write(to: inbox)
    try Data(#"{"messageIds":["legacy-delivered"]}"#.appending("\n").utf8)
        .write(to: deliveries)

    let summary = await BackgroundLoopsAssembly.heartbeatDurableResidueSummary(
        dataRoot: root,
        bridgeConfigRoot: config,
        now: try #require(ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z"))
    )

    #expect(summary.staleWorkflowRunIDs == ["old-waiting"])
    #expect(summary.preservedCodexReplyCount == 2)
    #expect(summary.terminalBridgeMessages == ["failed handoff (terminal_result)"])
    #expect(summary.staleBridgeMessages == ["abandoned handoff"])
    #expect(summary.veryOldDeskItems == ["1: Review an old open item"])
    #expect(summary.signalLine.contains("automatic replay inactive by design"))
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("workflows/run_state/old-waiting.json").path
    ))
    #expect((try FileManager.default.contentsOfDirectory(atPath: undelivered.path)).count == 3)
}

@Test("heartbeat bridge review honors the versioned historical acknowledgment horizon")
func heartbeatBridgeReviewUsesAcknowledgmentHorizon() async throws {
    let project = try durableResidueRoot()
    let root = project.appendingPathComponent("data", isDirectory: true)
    let config = try durableResidueRoot()
    defer {
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: config)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let docs = project.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data(#"{"acknowledgments":[{"detector":"bridge.undelivered","horizon":"2026-08-21T19:00:00Z"}]}"#.utf8)
        .write(to: docs.appendingPathComponent("eval_acknowledgments.json"))
    let bridge = config.appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
    try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
    try Data([
        #"{"id":"reviewed-era","createdAt":"2026-08-20T12:00:00Z","read":false}"#,
        #"{"id":"current-era","createdAt":"2026-08-27T12:00:00Z","read":false}"#,
        #"{"id":"old-dead-letter","createdAt":"2026-08-20T12:00:00Z","read":false,"deliveryStatus":"dead_letter"}"#,
    ].joined(separator: "\n").appending("\n").utf8)
        .write(to: bridge.appendingPathComponent("codex-inbox.jsonl"))

    let summary = await BackgroundLoopsAssembly.heartbeatDurableResidueSummary(
        dataRoot: root,
        bridgeConfigRoot: config,
        now: try #require(ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z"))
    )

    #expect(summary.staleBridgeMessages == ["current-era"])
    #expect(summary.terminalBridgeMessages == ["old-dead-letter (terminal failure)"])
}

@Test("durable residue uses one sticky card and archives it only when clear")
func durableResidueCardIsStickyAndBounded() async throws {
    let root = try durableResidueRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cardID = "system-health:durable-residue-review"
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z"))
    let initial = BackgroundLoopsAssembly.DurableResidueSummary(
        staleWorkflowRunCount: 1,
        staleWorkflowRunIDs: ["workflow-a"],
        preservedCodexReplyCount: 2,
        terminalBridgeMessageCount: 1,
        terminalBridgeMessages: ["failed handoff (terminal_result)"],
        staleBridgeMessageCount: 1,
        staleBridgeMessages: ["abandoned handoff"],
        veryOldDeskItemCount: 1,
        veryOldDeskItems: ["1: Old item"],
        membershipDigest: "initial"
    )

    await BackgroundLoopsAssembly.reconcileDurableResidueCard(
        dataRoot: root, summary: initial, now: now
    )
    let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: root))
    #expect(try await inbox.updateStatus(id: cardID, status: "read", readAt: "reviewed"))

    await BackgroundLoopsAssembly.reconcileDurableResidueCard(
        dataRoot: root, summary: initial, now: now.addingTimeInterval(60)
    )
    #expect(try #require(try await inboxObject(id: cardID, root: root))["status"] == .string("read"))
    #expect(try await inbox.rows().count == 1)

    let changed = BackgroundLoopsAssembly.DurableResidueSummary(
        staleWorkflowRunCount: 2,
        staleWorkflowRunIDs: ["workflow-a", "workflow-b"],
        preservedCodexReplyCount: 2,
        terminalBridgeMessageCount: 1,
        terminalBridgeMessages: ["failed handoff (terminal_result)"],
        staleBridgeMessageCount: 1,
        staleBridgeMessages: ["abandoned handoff"],
        veryOldDeskItemCount: 1,
        veryOldDeskItems: ["1: Old item"],
        membershipDigest: "changed"
    )
    await BackgroundLoopsAssembly.reconcileDurableResidueCard(
        dataRoot: root, summary: changed, now: now.addingTimeInterval(120)
    )
    #expect(try #require(try await inboxObject(id: cardID, root: root))["status"] == .string("unread"))
    #expect(try await inbox.rows().count == 1)

    await BackgroundLoopsAssembly.reconcileDurableResidueCard(
        dataRoot: root,
        summary: .init(
            staleWorkflowRunCount: 0,
            staleWorkflowRunIDs: [],
            preservedCodexReplyCount: 0,
            terminalBridgeMessageCount: 0,
            terminalBridgeMessages: [],
            staleBridgeMessageCount: 0,
            staleBridgeMessages: [],
            veryOldDeskItemCount: 0,
            veryOldDeskItems: [],
            membershipDigest: "empty"
        ),
        now: now.addingTimeInterval(180)
    )
    #expect(try #require(try await inboxObject(id: cardID, root: root))["status"] == .string("archived"))
}
