import Foundation
import Testing
@testable import NativeAgentApp
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import TriggerScheduler

private func deskInboxPolicyTestFireRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskInboxPolicyTestFire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func seedDeskInboxPolicyTestFireTrigger(root: URL) throws {
    let triggers = root.appendingPathComponent("triggers", isDirectory: true)
    try FileManager.default.createDirectory(at: triggers, withIntermediateDirectories: true)
    try JSONValue.array([
        .object([
            "name": .string("morning_brief"),
            "kind": .string("time"),
            "enabled": .bool(true),
            "config": .object(["notify": .bool(false)]),
        ]),
    ])
    .serializedData(pretty: false)
    .write(to: triggers.appendingPathComponent("trigger_config.json"))
}

@Suite("Desk inbox-policy Test row")
struct DeskInboxPolicyTestFireWritesRealRowEvalTests {
    // app.desk / desk.inboxPolicy.testFireWritesRealRow
    @Test("the Test action writes a real row that cannot match the release placeholder gate")
    func testFireWritesARealInboxRow() async throws {
        let root = try deskInboxPolicyTestFireRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDeskInboxPolicyTestFireTrigger(root: root)

        // This is the NativeClient action mounted by InboxSettingsView's Test
        // button, including its scheduler, real-inbox mirror, and receipt read.
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let receipt = try await client.inboxTriggerFireNow("morning_brief", stub: true)

        #expect(receipt.cardState == .created)
        #expect(!receipt.wasPlaceholder)
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: root))
        let rows = try await inbox.rows()
        let row = try #require(rows.first { candidate in
            guard case .object(let object) = candidate,
                  case .string(let id)? = object["id"] else { return false }
            return id == receipt.itemID
        })
        #expect(!InboxTriggerTestFireReceipt.isReleaseGatePlaceholder(row))
    }

    // app.desk / desk.inboxPolicy.testFireWritesRealRow
    @Test("a scheduler-shaped placeholder receipt is refused instead of shown as Test success")
    func placeholderRowFailsTheTestReceiptBoundary() async throws {
        let root = try deskInboxPolicyTestFireRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: root))
        let placeholder: JSONValue = .object([
            "id": .string("placeholder-row"),
            "source": .string("scheduled_proactive_scan"),
            "status": .string("unread"),
            "title": .string("Scheduled proactive scan"),
            "summary": .string("Reason: scheduled_proactive_scan test fixture"),
        ])
        try await inbox.appendUnique(placeholder, id: "placeholder-row")

        #expect(InboxTriggerTestFireReceipt.isReleaseGatePlaceholder(placeholder))
        let result = TriggerFireResult(
            status: "fired",
            name: "morning_brief",
            itemId: "placeholder-row",
            stub: true
        )
        await #expect(throws: (any Error).self) {
            try await InboxTriggerTestFireReceipt.confirm(result, in: inbox)
        }

        let placeholderStatus = InboxPolicyStatus(.triggerCardConfirmed(
            itemID: "placeholder-row",
            state: .created,
            wasPlaceholder: true
        ))
        #expect(placeholderStatus.tone == .failure)
        let failed = InboxPolicyStatus(.triggerFireFailed("placeholder row"))
        #expect(failed.tone == .failure)
    }
}
