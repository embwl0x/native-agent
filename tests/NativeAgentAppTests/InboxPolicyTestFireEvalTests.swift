import Foundation
import NotificationInbox
import PersistenceCore
import Testing
import TriggerScheduler
@testable import NativeAgentApp
import NativeAgentCore

private func inboxPolicyTestFireRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InboxPolicyTestFire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func seedInboxPolicyTriggers(_ rows: [JSONValue], root: URL) throws {
    let triggers = root.appendingPathComponent("triggers", isDirectory: true)
    try FileManager.default.createDirectory(at: triggers, withIntermediateDirectories: true)
    try JSONValue.array(rows)
        .serializedData(pretty: false)
        .write(to: triggers.appendingPathComponent("trigger_config.json"))
}

private func inboxTriggerRow(name: String, kind: String) -> JSONValue {
    .object([
        "name": .string(name),
        "kind": .string(kind),
        "enabled": .bool(true),
        // A manual test still proves the card path while an isolated eval never
        // borrows a paired-device notification effect from the live root.
        "config": .object(["notify": .bool(false)]),
    ])
}

@Suite("Inbox Policy test-fire receipts")
struct InboxPolicyTestFireEvalTests {
    // app.desk / desk.inboxPolicy.testFire
    @Test("a supported test fire confirms its exact card through the live inbox reader")
    func supportedFireCreatesAnObservableInboxCard() async throws {
        let root = try inboxPolicyTestFireRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInboxPolicyTriggers([inboxTriggerRow(name: "morning_brief", kind: "time")], root: root)

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let receipt = try await client.inboxTriggerFireNow("morning_brief", stub: true)

        #expect(receipt.cardState == .created)
        #expect(!receipt.itemID.isEmpty)
        #expect(!receipt.wasPlaceholder)
        let status = InboxPolicyStatus(.triggerCardConfirmed(
            itemID: receipt.itemID,
            state: receipt.cardState,
            wasPlaceholder: receipt.wasPlaceholder
        ))
        #expect(status.tone == .success)
        #expect(status.text.hasPrefix("Test card created"))

        // This is the same reader the Inbox History view uses, not a scheduler
        // response or a filesystem text search.
        let visible = try await client.getInboxItems()
        #expect(visible.contains(where: { $0.id == receipt.itemID }))
    }

    // app.desk / desk.inboxPolicy.testFire
    @Test("unsupported and unobservable tests fail rather than becoming green success")
    func refusalAndMissingLiveCardAreBothHonestFailures() async throws {
        let root = try inboxPolicyTestFireRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInboxPolicyTriggers([inboxTriggerRow(name: "file_watch", kind: "file_watch")], root: root)

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        await #expect(throws: (any Error).self) {
            try await client.inboxTriggerFireNow("file_watch", stub: true)
        }
        let liveInbox = LiveNotificationInbox(
            path: LiveNotificationInbox.livePath(dataRoot: root)
        )
        #expect(try await liveInbox.rows().isEmpty)

        // A response-shaped `fired` result is not enough: this exact production
        // receipt projection must reject it until the card is observable.
        let responseOnly = TriggerFireResult(
            status: "fired",
            name: "morning_brief",
            itemId: "missing-card",
            stub: false
        )
        await #expect(throws: (any Error).self) {
            try await InboxTriggerTestFireReceipt.confirm(responseOnly, in: liveInbox)
        }
        let failedStatus = InboxPolicyStatus(.triggerFireFailed("card not observable"))
        #expect(failedStatus.tone == .failure)
    }
}
