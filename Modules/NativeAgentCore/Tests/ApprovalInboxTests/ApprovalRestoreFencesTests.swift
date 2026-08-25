import Foundation
import Testing
import PersistenceCore
@testable import ApprovalInbox

// Ledger row: approvals.restoreFences.merge
//
// Silent-failure class: SECURITY + IRREVERSIBLE. `mergeRestoreFences` runs
// during a BACKUP RESTORE (NativeClient+TrustBackupOps.swift), before
// ApprovalInbox exists, and it rewrites the three authority stores directly.
// If the monotonic forward-merge is dropped, every effect/injection spend
// marker and every terminal decision in the restored tree is silently
// UN-SPENT — previously-executed approvals become replayable — and nobody sees
// it until an action fires twice.
//
// The fixtures below are built by the REAL producers (`create`, `resolve`,
// `annotateExecution`, `consumeApprovedEffect`, `consumeInjectionApproval`),
// not hand-written JSON, so the merge is exercised against the byte shapes the
// app actually writes. Reads back through the real strict loaders.

private struct RestoreFixture {
    let safetyRoot: URL
    let destinationRoot: URL
    /// Approved + executed + spent in safety; pending in destination.
    let executedID: String
    /// Denied in safety; pending in destination.
    let deniedID: String
    /// Pending on both sides.
    let untouchedID: String
    /// Resolved, and present ONLY in safety (created after the backup).
    let afterBackupID: String
}

private func restoreTestRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApprovalRestoreFences-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func approvalsDir(_ root: URL) -> URL {
    root.appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
}

private func requestsPath(_ root: URL) -> URL {
    approvalsDir(root).appendingPathComponent("requests.json")
}

private func effectSpendsPath(_ root: URL) -> URL {
    approvalsDir(root).appendingPathComponent("effect_spends.json")
}

private func injectionSpendsPath(_ root: URL) -> URL {
    approvalsDir(root).appendingPathComponent("injection_spends.json")
}

private func approvalBody(title: String) -> JSONValue {
    .object([
        "title": .string(title),
        "action": .string("shell"),
        "risk": .string("high"),
        "reason": .string("restore fence fixture"),
        "payload": .object(["command": .string("echo \(title)")]),
        "payloadPreview": .string("echo \(title)"),
        "remoteResolvable": .bool(false),
        "localOnly": .bool(true),
    ])
}

private func rows(_ path: URL) throws -> [String: [String: JSONValue]] {
    let parsed = try JSONValue.parse(try Data(contentsOf: path))
    guard case .array(let items) = parsed else { return [:] }
    var out: [String: [String: JSONValue]] = [:]
    for item in items {
        guard case .object(let object) = item,
              case .string(let id)? = object["id"] else { continue }
        out[id] = object
    }
    return out
}

private func rowOrder(_ path: URL) throws -> [String] {
    let parsed = try JSONValue.parse(try Data(contentsOf: path))
    guard case .array(let items) = parsed else { return [] }
    return items.compactMap {
        guard case .object(let object) = $0, case .string(let id)? = object["id"] else { return nil }
        return id
    }
}

/// Live tree → snapshot it as the older backup (the destination) → advance the
/// live tree with terminal decisions and spend markers (the safety root).
private func makeRestoreFixture() async throws -> RestoreFixture {
    let safetyRoot = try restoreTestRoot("safety")
    let destinationRoot = try restoreTestRoot("destination")
    let live = SwiftNativeApprovalInbox(root: safetyRoot)

    let executed = try await live.create(approvalBody(title: "executed"))
    let denied = try await live.create(approvalBody(title: "denied"))
    let untouched = try await live.create(approvalBody(title: "untouched"))

    // The backup: the three approvals as they stood, all pending, no spends.
    try FileManager.default.createDirectory(
        at: approvalsDir(destinationRoot), withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: requestsPath(safetyRoot), to: requestsPath(destinationRoot)
    )

    // Time passes on the live tree.
    _ = try await live.resolve(
        executed.id, decision: .approved, provenance: .local(decidedBy: "user")
    )
    _ = try await live.annotateExecution(
        executed.id,
        executedAction: .object(["ok": .bool(true), "exitCode": .int(0)]),
        detail: "ran once"
    )
    #expect(
        await live.consumeApprovedEffect(
            id: executed.id, digest: "digest-executed", action: "shell", surface: "chat"
        ) == .spent
    )
    #expect(
        await live.consumeInjectionApproval(
            id: executed.id, digest: "digest-executed", tool: "mac_inject", surface: "chat"
        ) == .spent
    )
    _ = try await live.resolve(
        denied.id, decision: .denied, provenance: .local(decidedBy: "user")
    )
    let afterBackup = try await live.create(approvalBody(title: "after-backup"))
    _ = try await live.resolve(
        afterBackup.id, decision: .approved, provenance: .local(decidedBy: "user")
    )

    return RestoreFixture(
        safetyRoot: safetyRoot,
        destinationRoot: destinationRoot,
        executedID: executed.id,
        deniedID: denied.id,
        untouchedID: untouched.id,
        afterBackupID: afterBackup.id
    )
}

@Test("restore merge never un-spends an effect or injection marker")
func restoreMergeCarriesSpendMarkersForward() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    // The restored backup has no spend files at all — the exact shape that
    // makes every prior approval replayable if the merge drops them.
    #expect(!FileManager.default.fileExists(atPath: effectSpendsPath(fixture.destinationRoot).path))
    #expect(!FileManager.default.fileExists(atPath: injectionSpendsPath(fixture.destinationRoot).path))

    try SwiftNativeApprovalInbox.mergeRestoreFences(
        safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
    )

    // Read back through the REAL strict loaders: schema + marker shape must
    // survive, or the running app fails closed on the next spend attempt.
    let effect = try SwiftNativeApprovalInbox.loadEffectSpends(
        at: effectSpendsPath(fixture.destinationRoot)
    )
    let injection = try SwiftNativeApprovalInbox.loadSpends(
        at: injectionSpendsPath(fixture.destinationRoot)
    )
    #expect(effect[fixture.executedID] != nil)
    #expect(injection[fixture.executedID] != nil)

    // And the restored tree now refuses to replay the spent effect.
    let restored = SwiftNativeApprovalInbox(root: fixture.destinationRoot)
    #expect(
        await restored.consumeApprovedEffect(
            id: fixture.executedID, digest: "digest-executed", action: "shell", surface: "chat"
        ) == .alreadySpent
    )
    #expect(
        await restored.consumeInjectionApproval(
            id: fixture.executedID, digest: "digest-executed", tool: "mac_inject", surface: "chat"
        ) == .alreadySpent
    )
}

@Test("destination-only spend markers survive the merge")
func restoreMergePreservesDestinationOnlyMarkers() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    // A marker that exists only in the restored tree (spent between the backup
    // and the restore) must not be dropped by the union.
    let destination = SwiftNativeApprovalInbox(root: fixture.destinationRoot)
    #expect(
        await destination.consumeApprovedEffect(
            id: fixture.untouchedID, digest: "digest-untouched", action: "shell", surface: "chat"
        ) == .spent
    )

    try SwiftNativeApprovalInbox.mergeRestoreFences(
        safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
    )

    let effect = try SwiftNativeApprovalInbox.loadEffectSpends(
        at: effectSpendsPath(fixture.destinationRoot)
    )
    #expect(effect[fixture.untouchedID] != nil, "destination-only marker was dropped")
    #expect(effect[fixture.executedID] != nil, "safety marker was dropped")
}

@Test("terminal decisions and execution facts move forward, pending rows are left alone")
func restoreMergeMovesResolutionFactsForwardOnly() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    let before = try rows(requestsPath(fixture.destinationRoot))
    #expect(before[fixture.executedID]?["status"] == .string("pending"))
    #expect(before[fixture.deniedID]?["status"] == .string("pending"))
    #expect(before[fixture.afterBackupID] == nil)

    try SwiftNativeApprovalInbox.mergeRestoreFences(
        safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
    )

    let after = try rows(requestsPath(fixture.destinationRoot))
    // Approved + executed carries status, decision, decidedBy, provenance and
    // the executedAction receipt.
    #expect(after[fixture.executedID]?["status"] == .string("resolved"))
    #expect(after[fixture.executedID]?["decision"] == .string("approved"))
    #expect(after[fixture.executedID]?["decidedBy"] == .string("user"))
    #expect(after[fixture.executedID]?["resolutionProvenance"] != nil)
    #expect(after[fixture.executedID]?["executedAction"] != nil)
    #expect(after[fixture.executedID]?["detail"] == .string("ran once"))
    if case .string(let resolvedAt)? = after[fixture.executedID]?["resolvedAt"] {
        #expect(!resolvedAt.isEmpty)
    } else {
        Issue.record("resolvedAt did not move forward")
    }
    // A denial is terminal too. NOTE the store's vocabulary: `status` is
    // "resolved" for every decided row and the verb lives in `decision` — the
    // merge's terminal set must keep matching THAT spelling, not the verb.
    #expect(after[fixture.deniedID]?["status"] == .string("resolved"))
    #expect(after[fixture.deniedID]?["decision"] == .string("denied"))
    // A row that is pending on BOTH sides stays pending — the merge never
    // invents a decision.
    #expect(after[fixture.untouchedID]?["status"] == .string("pending"))
    #expect(after[fixture.untouchedID]?["decision"] == .null)
    // A terminal row created after the backup is appended, not dropped.
    #expect(after[fixture.afterBackupID]?["status"] == .string("resolved"))
    #expect(try rowOrder(requestsPath(fixture.destinationRoot)).last == fixture.afterBackupID)

    // Descriptive bytes still come from the SELECTED backup, not from safety.
    #expect(after[fixture.executedID]?["title"] == before[fixture.executedID]?["title"])
    #expect(after[fixture.executedID]?["payload"] == before[fixture.executedID]?["payload"])

    // The merged store is still readable by the strict production loader, and
    // the restored inbox reports the same terminal state.
    let restored = SwiftNativeApprovalInbox(root: fixture.destinationRoot)
    let record = try await restored.get(fixture.executedID)
    #expect(record.status == "resolved")
    #expect(record.decision == "approved")
    #expect(record.executedAction != nil)
}

@Test("a non-terminal safety row never overwrites a resolved destination row")
func restoreMergeIgnoresNonTerminalSafetyRows() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    // `untouchedID` is pending in the safety tree. Resolve it in the RESTORED
    // tree only; the merge must not walk it back to pending.
    let destination = SwiftNativeApprovalInbox(root: fixture.destinationRoot)
    _ = try await destination.resolve(
        fixture.untouchedID, decision: .denied, provenance: .local(decidedBy: "restored-user")
    )

    try SwiftNativeApprovalInbox.mergeRestoreFences(
        safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
    )

    let after = try rows(requestsPath(fixture.destinationRoot))
    #expect(after[fixture.untouchedID]?["status"] == .string("resolved"))
    #expect(after[fixture.untouchedID]?["decision"] == .string("denied"))
    #expect(after[fixture.untouchedID]?["decidedBy"] == .string("restored-user"))
}

@Test("a payload-mismatched id throws and leaves the destination bytes untouched")
func restoreMergeRejectsMismatchedPayload() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    // Same id, different payload — an id collision across two unrelated trees.
    // Merging those two rows would attach one tree's decision to the other
    // tree's action.
    let path = requestsPath(fixture.destinationRoot)
    guard case .array(var items) = try JSONValue.parse(try Data(contentsOf: path)) else {
        Issue.record("destination store is not an array")
        return
    }
    for (index, item) in items.enumerated() {
        guard case .object(var object) = item,
              object["id"] == .string(fixture.executedID) else { continue }
        object["payload"] = .object(["command": .string("rm -rf /")])
        items[index] = .object(object)
    }
    try JSONValue.array(items).serializedData(pretty: true).write(to: path)
    let before = try Data(contentsOf: path)

    #expect(throws: ApprovalInboxError.self) {
        try SwiftNativeApprovalInbox.mergeRestoreFences(
            safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
        )
    }
    #expect(try Data(contentsOf: path) == before, "destination approvals were rewritten on a throw")
}

@Test("malformed destination bytes throw and are never treated as an empty store")
func restoreMergeFailsClosedOnMalformedDestination() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    let path = requestsPath(fixture.destinationRoot)
    let corrupt = Data("{not-an-approval-array".utf8)
    try corrupt.write(to: path)

    #expect(throws: ApprovalInboxError.self) {
        try SwiftNativeApprovalInbox.mergeRestoreFences(
            safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
        )
    }
    #expect(try Data(contentsOf: path) == corrupt, "malformed destination bytes were overwritten")
}

@Test("a missing safety store is a no-op, not an erase")
func restoreMergeWithNoSafetyStoreIsANoOp() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    // Destination has real content; safety has nothing at all.
    let emptySafety = try restoreTestRoot("empty-safety")
    defer { try? FileManager.default.removeItem(at: emptySafety) }
    let destination = SwiftNativeApprovalInbox(root: fixture.destinationRoot)
    #expect(
        await destination.consumeApprovedEffect(
            id: fixture.untouchedID, digest: "d", action: "shell", surface: "chat"
        ) == .spent
    )
    let requestsBefore = try Data(contentsOf: requestsPath(fixture.destinationRoot))
    let spendsBefore = try Data(contentsOf: effectSpendsPath(fixture.destinationRoot))

    try SwiftNativeApprovalInbox.mergeRestoreFences(
        safetyRoot: emptySafety, destinationRoot: fixture.destinationRoot
    )

    #expect(try Data(contentsOf: requestsPath(fixture.destinationRoot)) == requestsBefore)
    #expect(try Data(contentsOf: effectSpendsPath(fixture.destinationRoot)) == spendsBefore)
}

@Test("merging is idempotent — a second restore pass changes nothing")
func restoreMergeIsIdempotent() async throws {
    let fixture = try await makeRestoreFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.safetyRoot)
        try? FileManager.default.removeItem(at: fixture.destinationRoot)
    }
    try SwiftNativeApprovalInbox.mergeRestoreFences(
        safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
    )
    let requests = try Data(contentsOf: requestsPath(fixture.destinationRoot))
    let effect = try Data(contentsOf: effectSpendsPath(fixture.destinationRoot))
    let injection = try Data(contentsOf: injectionSpendsPath(fixture.destinationRoot))

    try SwiftNativeApprovalInbox.mergeRestoreFences(
        safetyRoot: fixture.safetyRoot, destinationRoot: fixture.destinationRoot
    )

    #expect(try Data(contentsOf: requestsPath(fixture.destinationRoot)) == requests)
    #expect(try Data(contentsOf: effectSpendsPath(fixture.destinationRoot)) == effect)
    #expect(try Data(contentsOf: injectionSpendsPath(fixture.destinationRoot)) == injection)
}
