import Testing
import Foundation
@testable import ApprovalInbox
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApprovalInboxTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func seedRecord(
    id: String,
    action: String = "improvement.promote",
    status: String = "pending",
    createdAt: String,
    resolvedAt: String? = nil,
    decision: String? = nil
) -> ApprovalRecord {
    ApprovalRecord(
        id: id,
        title: "Title for \(id)",
        action: action,
        risk: "medium",
        reason: "reason for \(id)",
        status: status,
        payload: .object(["runId": .string("r-\(id)")]),
        payloadPreview: "{\"runId\":\"r-\(id)\"}",
        createdAt: createdAt,
        resolvedAt: resolvedAt,
        decision: decision,
        remoteResolvable: false,
        localOnly: true
    )
}

private func writeSeed(
    _ records: [ApprovalRecord],
    to inbox: SwiftNativeApprovalInbox,
    pretty: Bool = true
) async throws {
    let path = await inbox.approvalsPath
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let arr: JSONValue = .array(records.map { $0.toJSON() })
    let data = try arr.serializedData(pretty: pretty)
    try data.write(to: path)
}

// MARK: - Factory

@Test func factoryReturnsSwiftNative() async throws {
    let impl = makeApprovalInbox()
    #expect(impl is SwiftNativeApprovalInbox)
}

// MARK: - SwiftNative read

@Test func listReturnsEmptyWhenFileMissing() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let records = try await inbox.list(filter: .all)
    #expect(records.isEmpty)
}

@Test func listSortsByCreatedAtDescending() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "a", createdAt: "2026-05-30T05:00:00+00:00"),
        seedRecord(id: "b", createdAt: "2026-05-30T07:00:00+00:00"),
        seedRecord(id: "c", createdAt: "2026-05-30T06:00:00+00:00"),
    ], to: inbox)
    let records = try await inbox.list(filter: .all)
    #expect(records.map(\.id) == ["b", "c", "a"])
}

@Test func filterByStatusPending() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "p1", status: "pending", createdAt: "2026-05-30T01:00:00+00:00"),
        seedRecord(id: "r1", status: "resolved", createdAt: "2026-05-30T02:00:00+00:00"),
        seedRecord(id: "p2", status: "pending", createdAt: "2026-05-30T03:00:00+00:00"),
    ], to: inbox)
    let pending = try await inbox.list(filter: .pending)
    #expect(pending.map(\.id) == ["p2", "p1"])
    let resolved = try await inbox.list(filter: .resolved)
    #expect(resolved.map(\.id) == ["r1"])
}

@Test func getReturnsRecordById() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "x1", createdAt: "2026-05-30T01:00:00+00:00"),
        seedRecord(id: "x2", createdAt: "2026-05-30T02:00:00+00:00"),
    ], to: inbox)
    let r = try await inbox.get("x1")
    #expect(r.id == "x1")
}

@Test func getThrowsNotFound() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "only", createdAt: "2026-05-30T01:00:00+00:00"),
    ], to: inbox)
    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.get("missing")
    }
}

// MARK: - Create

@Test func createPersistsPendingApprovalAndDefaultsRemoteResolvable() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let created = try await inbox.create(.object([
        "title": .string("Approve workflow step"),
        "action": .string("workflow_step"),
        "risk": .string("medium"),
        "reason": .string("Workflow is waiting."),
        "payload": .object(["workflowRunId": .string("run-1")]),
    ]))
    #expect(created.status == "pending")
    #expect(created.title == "Approve workflow step")
    #expect(created.action == "workflow_step")
    #expect(created.remoteResolvable)
    #expect(!created.localOnly)
    #expect(created.payloadPreview.contains("workflowRunId"))

    let listed = try await inbox.list(filter: .pending)
    #expect(listed.count == 1)
    #expect(listed[0].id == created.id)
}

@Test func createMarksLocalOnlyForLocalOnlyActions() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let created = try await inbox.create(.object([
        "title": .string("Delete memory"),
        "action": .string("memory.delete"),
        "payload": .object(["memoryId": .string("m1")]),
    ]))
    #expect(!created.remoteResolvable)
    #expect(created.localOnly)
}

// MARK: - Resolve

@Test func resolveSetsStatusAndDecision() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixed = Date(timeIntervalSince1970: 1_780_000_000) // 2026-05-29T12:26:40+00:00
    let inbox = SwiftNativeApprovalInbox(root: root, clock: { fixed })
    try await writeSeed([
        seedRecord(id: "to-resolve", status: "pending", createdAt: "2026-05-30T01:00:00+00:00"),
    ], to: inbox)
    let resolved = try await inbox.resolve("to-resolve", decision: .approved, decidedBy: "user")
    #expect(resolved.status == "resolved")
    #expect(resolved.decision == "approved")
    #expect(resolved.resolvedAt != nil)
    // Round-trip the file and confirm the mutation landed.
    let again = try await inbox.get("to-resolve")
    #expect(again.status == "resolved")
    #expect(again.decision == "approved")
}

@Test func resolveRejectsAlreadyTerminal() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(
            id: "done", status: "resolved",
            createdAt: "2026-05-30T01:00:00+00:00",
            resolvedAt: "2026-05-30T01:05:00+00:00",
            decision: "approved"
        ),
    ], to: inbox)
    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.resolve("done", decision: .approved, decidedBy: "user")
    }
}

@Test func resolveDeniedAndCanceledShapesMatch() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "d1", status: "pending", createdAt: "2026-05-30T01:00:00+00:00"),
        seedRecord(id: "c1", status: "pending", createdAt: "2026-05-30T02:00:00+00:00"),
    ], to: inbox)
    let r1 = try await inbox.resolve("d1", decision: .denied, decidedBy: "user")
    #expect(r1.status == "resolved")  // Python mirror: status stays "resolved", decision carries the verb
    #expect(r1.decision == "denied")
    let r2 = try await inbox.resolve("c1", decision: .canceled, decidedBy: "user")
    #expect(r2.decision == "canceled")
}

// MARK: - Archive

@Test func archiveDropsTerminalRecordsOlderThanCutoff() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "old-resolved", status: "resolved",
                   createdAt: "2026-01-01T00:00:00+00:00",
                   resolvedAt: "2026-01-01T00:01:00+00:00",
                   decision: "approved"),
        seedRecord(id: "fresh-resolved", status: "resolved",
                   createdAt: "2026-05-30T00:00:00+00:00",
                   resolvedAt: "2026-05-30T00:01:00+00:00",
                   decision: "approved"),
        seedRecord(id: "pending-old", status: "pending",
                   createdAt: "2026-01-01T00:00:00+00:00"),
    ], to: inbox)
    let cutoff = ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")!
    let dropped = try await inbox.archive(olderThan: cutoff)
    #expect(dropped == 1)
    let remaining = try await inbox.list(filter: .all)
    let ids = Set(remaining.map(\.id))
    #expect(ids.contains("fresh-resolved"))
    #expect(ids.contains("pending-old"))  // pending never archived
    #expect(!ids.contains("old-resolved"))
}

// MARK: - Canonical JSON shape

@Test func writeIsReadableAsCanonicalJSON() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "py-check", createdAt: "2026-05-30T08:00:00+00:00"),
    ], to: inbox)
    let approvalsPath = await inbox.approvalsPath
    let parsed = try JSONValue.parse(Data(contentsOf: approvalsPath))
    guard case .array(let arr) = parsed, let first = arr.first,
          case .object(let obj) = first,
          case .string(let id) = obj["id"] ?? .null else {
        Issue.record("approval JSON had unexpected shape")
        return
    }
    #expect(id == "py-check")
}

@Test func resolveProducesReadableJSONMutation() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let inbox = SwiftNativeApprovalInbox(root: root, clock: { fixed })
    try await writeSeed([
        seedRecord(id: "mut", status: "pending", createdAt: "2026-05-30T01:00:00+00:00"),
    ], to: inbox)
    _ = try await inbox.resolve("mut", decision: .approved, decidedBy: "user")
    let approvalsPath = await inbox.approvalsPath
    let parsed = try JSONValue.parse(Data(contentsOf: approvalsPath))
    guard case .array(let rows) = parsed,
          let hit = rows.compactMap({ row -> [String: JSONValue]? in
              guard case .object(let obj) = row,
                    case .string("mut") = obj["id"] ?? .null else { return nil }
              return obj
          }).first else {
        Issue.record("resolved approval row not found")
        return
    }
    if case .string(let s) = hit["status"] ?? .null {
        #expect(s == "resolved")
    } else {
        Issue.record("status field missing")
    }
    if case .string(let d) = hit["decision"] ?? .null {
        #expect(d == "approved")
    }
    #expect(hit["resolvedAt"] != nil)
}

// MARK: - Replay-baseline parity

/// Validates that the Swift impl produces the SAME shape as the Phase-A
/// recorder when given the same on-disk state.
@Test func listMatchesRecorderShapeForCapturedBaseline() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    // Mirror the seed used in the Python recorder tests.
    try await writeSeed([
        seedRecord(id: "ap-1", status: "pending", createdAt: "2026-05-30T05:00:00+00:00"),
        seedRecord(id: "ap-2", action: "mcp", status: "pending",
                   createdAt: "2026-05-30T07:00:00+00:00"),
        seedRecord(id: "ap-3", action: "memory.update", status: "resolved",
                   createdAt: "2026-05-30T06:00:00+00:00",
                   resolvedAt: "2026-05-30T06:01:00+00:00",
                   decision: "approved"),
    ], to: inbox)
    let records = try await inbox.list(filter: .all)
    #expect(records.map(\.id) == ["ap-2", "ap-3", "ap-1"])
    // Required structural fields per the replay_rules contract.
    for r in records {
        #expect(!r.id.isEmpty)
        #expect(!r.action.isEmpty)
        #expect(!r.status.isEmpty)
    }
}

// MARK: - Fix 1: defaultDataRoot priority order

@Test func defaultDataRootHonorsEnvVar() async throws {
    let prior = ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA_ROOT"]
    setenv("NATIVE_AGENT_DATA_ROOT", "/tmp/test-root-abc", 1)
    defer {
        if let prior {
            setenv("NATIVE_AGENT_DATA_ROOT", prior, 1)
        } else {
            unsetenv("NATIVE_AGENT_DATA_ROOT")
        }
    }
    let root = SwiftNativeApprovalInbox.defaultDataRoot()
    #expect(root.path == "/tmp/test-root-abc")
}

@Test func libraryAppSupportFallbackHasNoDataSuffix() async throws {
    let url = libraryAppSupportFallback()
    #expect(url.lastPathComponent == "NativeAgent")
    #expect(url.lastPathComponent != "data")
}

// MARK: - Fix 2: actor serializes concurrent resolve

@Test func concurrentResolveDoesNotClobber() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "r0", status: "pending", createdAt: "2026-05-30T01:00:00+00:00"),
        seedRecord(id: "r1", status: "pending", createdAt: "2026-05-30T02:00:00+00:00"),
        seedRecord(id: "r2", status: "pending", createdAt: "2026-05-30T03:00:00+00:00"),
        seedRecord(id: "r3", status: "pending", createdAt: "2026-05-30T04:00:00+00:00"),
        seedRecord(id: "r4", status: "pending", createdAt: "2026-05-30T05:00:00+00:00"),
    ], to: inbox)
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<5 {
            group.addTask {
                _ = try? await inbox.resolve("r\(i)", decision: .approved, decidedBy: "user")
            }
        }
        await group.waitForAll()
    }
    let all = try await inbox.list(filter: .all)
    #expect(all.count == 5)
    for r in all {
        #expect(r.status == "resolved")
    }
}

// MARK: - Fix 4: executedAction + detail schema

@Test func resolveDoesNotInjectExecutedAction() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "ea-none", status: "pending", createdAt: "2026-05-30T01:00:00+00:00"),
    ], to: inbox)
    let resolved = try await inbox.resolve("ea-none", decision: .approved, decidedBy: "user")
    #expect(resolved.executedAction == nil)
    #expect(resolved.detail == nil)
}

@Test func executedActionRoundTripsFromFixture() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let path = await inbox.approvalsPath
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rec: JSONValue = .object([
        "id": .string("ea-1"),
        "title": .string("t"),
        "action": .string("memory.update"),
        "risk": .string("medium"),
        "reason": .string("r"),
        "status": .string("resolved"),
        "payload": .object([:]),
        "payloadPreview": .string(""),
        "createdAt": .string("2026-05-30T01:00:00+00:00"),
        "resolvedAt": .string("2026-05-30T01:01:00+00:00"),
        "decision": .string("approved"),
        "remoteResolvable": .bool(false),
        "localOnly": .bool(true),
        "executedAction": .object([
            "kind": .string("memory.update"),
            "result": .string("ok"),
        ]),
    ])
    let arr: JSONValue = .array([rec])
    try arr.serializedData(pretty: true).write(to: path)
    let records = try await inbox.list(filter: .all)
    #expect(records.count == 1)
    let r = records[0]
    guard case .object(let eaObj) = r.executedAction ?? .null else {
        Issue.record("executedAction not parsed as object")
        return
    }
    if case .string(let k) = eaObj["kind"] ?? .null {
        #expect(k == "memory.update")
    } else {
        Issue.record("missing kind")
    }
    // toJSON round-trip preserves the key
    guard case .object(let outObj) = r.toJSON() else {
        Issue.record("toJSON not object"); return
    }
    #expect(outObj["executedAction"] != nil)
}

@Test func pendingRecordToJSONOmitsExecutedAction() async throws {
    let rec = seedRecord(id: "p-omit", status: "pending", createdAt: "2026-05-30T01:00:00+00:00")
    guard case .object(let obj) = rec.toJSON() else {
        Issue.record("toJSON not object"); return
    }
    #expect(obj["executedAction"] == nil)
    #expect(obj["detail"] == nil)
    // resolvedAt and decision ARE present (as null) — that's the intentional asymmetry
    #expect(obj["resolvedAt"] != nil)
    #expect(obj["decision"] != nil)
}

// MARK: - Additional coverage

@Test func resolveImprovementRevert() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "rev", action: "improvement.revert", status: "pending",
                   createdAt: "2026-05-30T01:00:00+00:00"),
    ], to: inbox)
    let r = try await inbox.resolve("rev", decision: .approved, decidedBy: "user")
    #expect(r.action == "improvement.revert")
    #expect(r.status == "resolved")
    #expect(r.decision == "approved")
    let again = try await inbox.get("rev")
    #expect(again.action == "improvement.revert")
    #expect(again.status == "resolved")
}

@Test func resolveMCPApproval() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "mcp1", action: "mcp", status: "pending",
                   createdAt: "2026-05-30T01:00:00+00:00"),
    ], to: inbox)
    let r = try await inbox.resolve("mcp1", decision: .approved, decidedBy: "user")
    #expect(r.action == "mcp")
    #expect(r.status == "resolved")
    #expect(r.decision == "approved")
    let again = try await inbox.get("mcp1")
    #expect(again.action == "mcp")
}

@Test func corruptStoreFailsClosedAcrossReadAndMutationWithoutChangingBytes() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let path = await inbox.approvalsPath
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let corrupt = Data("not json at all !!! @@@".utf8)
    try corrupt.write(to: path)

    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.list(filter: .all)
    }
    #expect(try Data(contentsOf: path) == corrupt)

    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.create(.object([
            "title": .string("Must not replace the queue"),
            "action": .string("workflow_step"),
        ]))
    }
    #expect(try Data(contentsOf: path) == corrupt)

    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.resolve("missing", decision: .approved, decidedBy: "user")
    }
    #expect(try Data(contentsOf: path) == corrupt)

    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.archive(olderThan: Date())
    }
    #expect(try Data(contentsOf: path) == corrupt)
}

@Test func existingNonArrayAndMalformedRowsAreUnavailableNotEmpty() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let path = await inbox.approvalsPath
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

    let nonArray = try JSONValue.object(["pending": .array([])]).serializedData(pretty: true)
    try nonArray.write(to: path)
    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.list(filter: .all)
    }
    #expect(try Data(contentsOf: path) == nonArray)

    let malformedRow = try JSONValue.array([
        seedRecord(id: "valid", createdAt: "2026-05-30T01:00:00+00:00").toJSON(),
        .object(["status": .string("pending")]),
    ]).serializedData(pretty: true)
    try malformedRow.write(to: path)
    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.list(filter: .all)
    }
    #expect(try Data(contentsOf: path) == malformedRow)
}

@Test func existingUnreadableStoreIsUnavailableAndNotReplaced() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let path = await inbox.approvalsPath
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.list(filter: .all)
    }
    await #expect(throws: ApprovalInboxError.self) {
        _ = try await inbox.create(.object([
            "title": .string("Must not replace unreadable state"),
            "action": .string("workflow_step"),
        ]))
    }
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func concurrentCreatePreservesEveryApproval() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask {
                _ = try? await inbox.create(.object([
                    "title": .string("Approval \(index)"),
                    "action": .string("workflow_step"),
                    "payload": .object(["index": .int(Int64(index))]),
                ]))
            }
        }
        await group.waitForAll()
    }

    let records = try await inbox.list(filter: .all)
    #expect(records.count == 20)
    let indexes = Set(records.compactMap { record -> Int? in
        guard case .object(let payload) = record.payload,
              case .int(let index)? = payload["index"] else { return nil }
        return Int(index)
    })
    #expect(indexes == Set(0..<20))
}

// 2026-07-03: caller-provided human preview must win over serialized payload
// (unconditional serialization rendered raw JSON + \uXXXX escapes on every
// rich approval card — the "garbled" REM growth card User flagged).
@Test func createHonorsCallerPayloadPreview() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    let created = try await inbox.create(.object([
        "title": .string("REM growth lesson"),
        "action": .string("rem.proposal"),
        "risk": .string("medium"),
        "reason": .string("Weekly REM drafted a lesson."),
        "payload": .object(["proposal": .object(["id": .string("p1")])]),
        "payloadPreview": .string("[GROWTH.md] Verify at the glass — human words."),
    ]))
    #expect(created.payloadPreview == "[GROWTH.md] Verify at the glass — human words.")

    // Absent/blank caller preview still falls back to serialized payload.
    let fallback = try await inbox.create(.object([
        "title": .string("No preview"),
        "action": .string("workflow_step"),
        "risk": .string("low"),
        "reason": .string("r"),
        "payload": .object(["k": .string("v")]),
        "payloadPreview": .string("   "),
    ]))
    #expect(fallback.payloadPreview.contains("\"k\""))
}

// MARK: - P2-4: the `mission.step` -> `execution.step` action seam
//
// approvals.jsonl is a historical record and is never rewritten, so a blocked
// step staged before the 0.3.8 upgrade keeps its `mission.step` action forever
// while the executor that resumes it now filters on `execution.step`. Both
// cases below pair a record in one vocabulary with a filter in the other; a
// same-spelling test cannot tell a working bridge from a missing one.

@Test func actionFilterMatchesALegacyRecordWithTheCanonicalFilter() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "old", action: "mission.step", createdAt: "2026-05-30T05:00:00+00:00"),
        seedRecord(id: "other", action: "rem.proposal", createdAt: "2026-05-30T06:00:00+00:00"),
    ], to: inbox)
    let matched = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: "execution.step")
    )
    #expect(matched.map(\.id) == ["old"])
}

@Test func actionFilterMatchesACanonicalRecordWithTheLegacyFilter() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "new", action: "execution.step", createdAt: "2026-05-30T05:00:00+00:00"),
        seedRecord(id: "other", action: "memory.repair", createdAt: "2026-05-30T06:00:00+00:00"),
    ], to: inbox)
    let matched = try await inbox.list(
        filter: ApprovalFilter(status: "pending", action: "mission.step")
    )
    #expect(matched.map(\.id) == ["new"])
}

@Test func actionFilterStillDiscriminatesUnrelatedActions() async throws {
    // The fold must not have turned the action filter into a pass-through.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    try await writeSeed([
        seedRecord(id: "step", action: "mission.step", createdAt: "2026-05-30T05:00:00+00:00"),
        seedRecord(id: "rem", action: "rem.proposal", createdAt: "2026-05-30T06:00:00+00:00"),
    ], to: inbox)
    let matched = try await inbox.list(filter: ApprovalFilter(action: "rem.proposal"))
    #expect(matched.map(\.id) == ["rem"])
}
