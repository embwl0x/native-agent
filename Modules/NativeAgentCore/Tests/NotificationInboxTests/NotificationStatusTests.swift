import Testing
import Foundation
@testable import NotificationInbox
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

/// A temp dir laid out like the daemon data root for notification status:
///   <root>/native_power/notifications/receipts.jsonl
///   <root>/workflows/approvals/requests.json
private struct StatusFixture {
    let root: URL
    let receiptsPath: URL
    let approvalsPath: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif-status-tests-\(UUID().uuidString)", isDirectory: true)
        let notif = root
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("notifications", isDirectory: true)
        let approvalsDir = root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
        try FileManager.default.createDirectory(at: notif, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: approvalsDir, withIntermediateDirectories: true)
        receiptsPath = notif.appendingPathComponent("receipts.jsonl")
        approvalsPath = approvalsDir.appendingPathComponent("requests.json")
    }

    func client() -> SwiftNativeNotificationStatus {
        SwiftNativeNotificationStatus(receiptsPath: receiptsPath, approvalsPath: approvalsPath)
    }

    func writeReceiptsLines(_ lines: [[String: Any]]) throws {
        var text = ""
        for line in lines {
            let d = try JSONSerialization.data(withJSONObject: line, options: [])
            text += String(data: d, encoding: .utf8)! + "\n"
        }
        try text.write(to: receiptsPath, atomically: true, encoding: .utf8)
    }

    func writeApprovals(_ approvals: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: approvals, options: [])
        try data.write(to: approvalsPath)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func sval(_ env: JSONValue, _ key: String) -> String? {
    guard case .object(let o) = env, case .string(let s)? = o[key] else { return nil }
    return s
}

private func ival(_ env: JSONValue, _ key: String) -> Int64? {
    guard case .object(let o) = env, case .int(let n)? = o[key] else { return nil }
    return n
}

private func aval(_ env: JSONValue, _ key: String) -> [JSONValue]? {
    guard case .object(let o) = env, case .array(let a)? = o[key] else { return nil }
    return a
}

// MARK: - Envelope shape (mirrors notification_status())

@Test func notificationStatus_envelopeMirrorsDaemon() async throws {
    let fix = try StatusFixture()
    defer { fix.cleanup() }
    let env = try #require(await fix.client().notificationStatus())
    #expect(sval(env, "status") == "ready")
    #expect(sval(env, "authorization") == "app_requested")
    // No files on disk -> empty receipts, zero pending.
    #expect(ival(env, "receiptCount") == 0)
    #expect(ival(env, "pendingApprovals") == 0)
    guard case .object(let o) = env else { Issue.record("not object"); return }
    #expect(o["latestReceipt"] == JSONValue.null)
    // createdAt is now_iso()-shaped: "...+00:00" offset (NOT a trailing Z).
    let createdAt = try #require(sval(env, "createdAt"))
    #expect(createdAt.hasSuffix("+00:00"))
}

// The fixed actionCategories literal must match the daemon exactly:
//   approval (approve/deny, medium), doctor (open_doctor/repair_safe, low),
//   execution (open_mission, low).
@Test func notificationStatus_actionCategoriesAreFixedLiteral() async throws {
    let fix = try StatusFixture()
    defer { fix.cleanup() }
    let env = try #require(await fix.client().notificationStatus())
    let cats = try #require(aval(env, "actionCategories"))
    #expect(cats.count == 3)

    func cat(_ v: JSONValue) -> (id: String, actions: [String], risk: String)? {
        guard case .object(let o) = v,
              case .string(let id)? = o["id"],
              case .array(let acts)? = o["actions"],
              case .string(let risk)? = o["risk"] else { return nil }
        let actions = acts.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        return (id, actions, risk)
    }
    let parsed = cats.compactMap(cat)
    #expect(parsed.count == 3)
    #expect(parsed[0].id == "approval")
    #expect(parsed[0].actions == ["approve", "deny"])
    #expect(parsed[0].risk == "medium")
    #expect(parsed[1].id == "doctor")
    #expect(parsed[1].actions == ["open_doctor", "repair_safe"])
    #expect(parsed[1].risk == "low")
    #expect(parsed[2].id == "mission")
    #expect(parsed[2].actions == ["open_mission"])
    #expect(parsed[2].risk == "low")
}

// MARK: - receipts: last 20, newest-first (matches reversed(tail_jsonl(.., 20)))

@Test func notificationStatus_receiptsNewestFirstCappedAt20() async throws {
    let fix = try StatusFixture()
    defer { fix.cleanup() }
    var lines: [[String: Any]] = []
    for i in 0..<25 { lines.append(["id": "rcpt-\(i)", "actionId": "notification.dry_run", "status": "succeeded"]) }
    try fix.writeReceiptsLines(lines)
    let env = try #require(await fix.client().notificationStatus())
    #expect(ival(env, "receiptCount") == 20)
    // latestReceipt = newest = the LAST written line (rcpt-24) after reverse.
    guard case .object(let o) = env,
          case .object(let latest)? = o["latestReceipt"],
          case .string(let latestID)? = latest["id"] else {
        Issue.record("latestReceipt not an object with id")
        return
    }
    #expect(latestID == "rcpt-24")
}

@Test func notificationStatus_noReceiptsGivesNullLatestAndZeroCount() async throws {
    let fix = try StatusFixture()
    defer { fix.cleanup() }
    try fix.writeReceiptsLines([])
    let env = try #require(await fix.client().notificationStatus())
    #expect(ival(env, "receiptCount") == 0)
    guard case .object(let o) = env else { Issue.record("not object"); return }
    #expect(o["latestReceipt"] == JSONValue.null)
}

// MARK: - pendingApprovals: count only status=="pending"

@Test func notificationStatus_pendingApprovalsCountMatchesPython() async throws {
    let fix = try StatusFixture()
    defer { fix.cleanup() }
    try fix.writeApprovals([
        ["id": "a1", "status": "pending"],
        ["id": "a2", "status": "approved"],
        ["id": "a3", "status": "pending"],
        ["id": "a4", "status": "denied"],
        ["id": "a5"],                        // missing status -> not counted
        ["id": "a6", "status": "pending"],
    ])
    let env = try #require(await fix.client().notificationStatus())
    #expect(ival(env, "pendingApprovals") == 3)
}

@Test func notificationStatus_missingApprovalsFileGivesZeroPending() async throws {
    let fix = try StatusFixture()
    defer { fix.cleanup() }
    // No requests.json on disk -> read_json default [] -> zero pending.
    let env = try #require(await fix.client().notificationStatus())
    #expect(ival(env, "pendingApprovals") == 0)
}

@Test func notificationStatus_nonListApprovalsFileGivesZeroPending() async throws {
    let fix = try StatusFixture()
    defer { fix.cleanup() }
    // A torn / non-list approvals file: read_json(.., []) returns the default []
    // in the daemon (and list_approval_requests guards `isinstance(.., list)`).
    let data = try JSONSerialization.data(withJSONObject: ["not": "a list"], options: [])
    try data.write(to: fix.approvalsPath)
    let env = try #require(await fix.client().notificationStatus())
    #expect(ival(env, "pendingApprovals") == 0)
}

// MARK: - Factory gate

@Test func makeNotificationStatus_returnsSwiftNative() {
    let client = makeNotificationStatus()
    #expect(client is SwiftNativeNotificationStatus)
}
