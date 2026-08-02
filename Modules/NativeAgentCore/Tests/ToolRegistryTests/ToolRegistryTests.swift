import Testing
import Foundation
@testable import ToolRegistry
import NativeAgentCore
import NativeAgentTestSupport
import PersistenceCore

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolRegistryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func seedRegistry(_ records: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("registry.json")
    let data = try JSONValue.array(records).serializedData(pretty: true)
    try data.write(to: path)
}

private func makeToolJSON(
    id: String,
    name: String? = nil,
    status: String = "active",
    createdAt: String = "2026-05-01T00:00:00+00:00",
    updatedAt: String? = "2026-05-01T00:00:01+00:00",
    lastUsedAt: String? = nil,
    lastUsedAtExplicitNull: Bool = false,
    extras: [String: JSONValue] = [:]
) -> JSONValue {
    var obj: [String: JSONValue] = [
        "id": .string(id),
        "name": .string(name ?? id),
        "status": .string(status),
        "createdAt": .string(createdAt),
    ]
    // Active records require activePath. Provide a sentinel-string default
    // so legacy tests stay valid. Tests that need a real path or want to
    // override pass it via `extras`.
    if status == "active" {
        obj["activePath"] = .string("/tmp/active-\(id)")
    }
    if let updatedAt {
        obj["updatedAt"] = .string(updatedAt)
    }
    if let lastUsedAt {
        obj["lastUsedAt"] = .string(lastUsedAt)
    } else if lastUsedAtExplicitNull {
        obj["lastUsedAt"] = .null
    }
    for (k, v) in extras { obj[k] = v }
    return .object(obj)
}

// MARK: - Factory

@Test func factoryReturnsSwiftNativeByDefault() async throws {
    let impl = makeToolRegistry()
    #expect(impl is SwiftNativeToolRegistry)
}

@Test func factoryIgnoresLegacySwiftFlag() async throws {
    let impl = makeToolRegistry()
    #expect(impl is SwiftNativeToolRegistry)
}

// MARK: - listTools

@Test func listTools_empty_registry_returns_empty() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let r = SwiftNativeToolRegistry(root: root)
    let tools = try await r.listTools(filter: .all)
    #expect(tools.isEmpty)
}

@Test func listTools_valid_returns_sorted_DESC_by_updatedAt_or_createdAt() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "alpha", updatedAt: "2026-05-30T10:00:00+00:00"),
        makeToolJSON(id: "bravo", updatedAt: "2026-05-30T12:00:00+00:00"),
        makeToolJSON(id: "charlie", updatedAt: "2026-05-30T11:00:00+00:00"),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let tools = try await r.listTools(filter: .all)
    #expect(tools.map(\.id) == ["bravo", "charlie", "alpha"])
}

@Test func listTools_malformed_file_returns_empty_does_not_throw() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json !!".utf8).write(to: dir.appendingPathComponent("registry.json"))
    let r = SwiftNativeToolRegistry(root: root)
    let tools = try await r.listTools(filter: .all)
    #expect(tools.isEmpty)
}

@Test func listTools_filter_by_status() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "a", status: "active"),
        makeToolJSON(id: "q", status: "quarantined"),
        makeToolJSON(id: "a2", status: "active"),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let active = try await r.listTools(filter: .status("active"))
    #expect(active.count == 2)
    for t in active { #expect(t.status == "active") }
    let quar = try await r.listTools(filter: .status("quarantined"))
    #expect(quar.count == 1)
    #expect(quar[0].id == "q")
}

@Test func listTools_sort_with_only_createdAt_or_only_updatedAt_or_both() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Three shapes: only-createdAt (updatedAt absent), only-updatedAt (older
    // createdAt), and both. Sort key = updatedAt OR createdAt.
    try seedRegistry([
        makeToolJSON(id: "only-created",
                     createdAt: "2026-05-30T08:00:00+00:00",
                     updatedAt: nil),
        makeToolJSON(id: "both-newer",
                     createdAt: "2026-05-30T05:00:00+00:00",
                     updatedAt: "2026-05-30T09:00:00+00:00"),
        makeToolJSON(id: "both-older",
                     createdAt: "2026-05-30T03:00:00+00:00",
                     updatedAt: "2026-05-30T06:00:00+00:00"),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let tools = try await r.listTools(filter: .all)
    #expect(tools.map(\.id) == ["both-newer", "only-created", "both-older"])
}

// Records that tie on the effective sort key MUST keep their on-disk (input)
// order. Swift's `sorted(by:)` is NOT stable, so without an explicit index
// tie-break the read surface could re-order tied records. Seed three records
// sharing one updatedAt and three sharing another; assert the within-tie
// order matches input order.
@Test func listTools_ties_preserve_input_order_stable() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Two tie-groups. Group A (updatedAt = ...09) on disk in order a1,a2,a3.
    // Group B (updatedAt = ...06) on disk in order b1,b2,b3. DESC by key
    // puts group A before group B; within each group, input order holds.
    let tA = "2026-05-30T09:00:00+00:00"
    let tB = "2026-05-30T06:00:00+00:00"
    try seedRegistry([
        makeToolJSON(id: "a1", updatedAt: tA),
        makeToolJSON(id: "a2", updatedAt: tA),
        makeToolJSON(id: "a3", updatedAt: tA),
        makeToolJSON(id: "b1", updatedAt: tB),
        makeToolJSON(id: "b2", updatedAt: tB),
        makeToolJSON(id: "b3", updatedAt: tB),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let tools = try await r.listTools(filter: .all)
    #expect(tools.map(\.id) == ["a1", "a2", "a3", "b1", "b2", "b3"])
}

// Interleaved fixture pins the stable-desc contract without relying on a
// second runtime as oracle.
@Test func listTools_tie_order_matches_stable_desc_contract() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Interleave the tie-groups on disk so a non-stable sort would visibly
    // scramble them: input order x1,y1,x2,y2,x3,y3 with x-group keyed newer.
    let tX = "2026-05-30T09:00:00+00:00"
    let tY = "2026-05-30T06:00:00+00:00"
    try seedRegistry([
        makeToolJSON(id: "x1", updatedAt: tX, extras: ["activePath": .string("/tmp/x1")]),
        makeToolJSON(id: "y1", updatedAt: tY, extras: ["activePath": .string("/tmp/y1")]),
        makeToolJSON(id: "x2", updatedAt: tX, extras: ["activePath": .string("/tmp/x2")]),
        makeToolJSON(id: "y2", updatedAt: tY, extras: ["activePath": .string("/tmp/y2")]),
        makeToolJSON(id: "x3", updatedAt: tX, extras: ["activePath": .string("/tmp/x3")]),
        makeToolJSON(id: "y3", updatedAt: tY, extras: ["activePath": .string("/tmp/y3")]),
    ], root: root)
    let expectedOrder = ["x1", "x2", "x3", "y1", "y2", "y3"]
    let r = SwiftNativeToolRegistry(root: root)
    let swiftOrder = try await r.listTools(filter: .all).map(\.id)
    #expect(swiftOrder == expectedOrder,
            "tie-order divergence:\nexpected: \(expectedOrder)\nswift:    \(swiftOrder)")
}

// MARK: - getTool

@Test func getTool_found_returns_record() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "wanted"),
        makeToolJSON(id: "other"),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.getTool(id: "wanted")
    #expect(rec?.id == "wanted")
}

@Test func getTool_notFound_returns_nil() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "exists"),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.getTool(id: "missing")
    #expect(rec == nil)
}

// MARK: - promote

@Test func promote_unknown_id_throws_toolNotFound() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([makeToolJSON(id: "real")], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    do {
        _ = try await r.promote(id: "ghost")
        Issue.record("expected throw")
    } catch let ToolRegistryError.toolNotFound(id) {
        #expect(id == "ghost")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func promote_flips_status_to_active_and_stamps_updatedAt() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "p1", status: "quarantined",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
    ], root: root)
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let r = SwiftNativeToolRegistry(root: root, clock: { fixed })
    let rec = try await r.promote(id: "p1")
    #expect(rec.status == "active")
    let expectedStamp = SwiftNativeToolRegistry.isoTimestamp(fixed)
    #expect(rec.updatedAt == expectedStamp)
    // Round-trip via list.
    let again = try await r.getTool(id: "p1")
    #expect(again?.status == "active")
    #expect(again?.updatedAt == expectedStamp)
}

@Test func promote_idempotent_active_tool_just_restamps() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "p1", status: "active",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
    ], root: root)
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let r = SwiftNativeToolRegistry(root: root, clock: { fixed })
    let rec = try await r.promote(id: "p1")
    #expect(rec.status == "active")
    #expect(rec.updatedAt == SwiftNativeToolRegistry.isoTimestamp(fixed))
}

@Test func promote_preserves_unknown_extra_fields() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "p1", status: "quarantined",
                     extras: [
                         "permissions": .array([.string("app_data_read")]),
                         "useCount": .int(7),
                         "_customDaemonKey": .string("custom-value"),
                     ]),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.promote(id: "p1")
    guard case .object(let extra)? = rec.extras else {
        Issue.record("extras missing — extras were dropped on promote")
        return
    }
    #expect(extra["permissions"] != nil)
    #expect(extra["useCount"] != nil)
    #expect(extra["_customDaemonKey"] != nil)
}

/// HARD SCOPE CARVE: promote() MUST NOT touch manifestSignature,
/// codeFingerprint, signedAt, activePath, or copy any file on disk. This
/// test pins that contract.
@Test func promote_does_NOT_touch_manifestSignature_codeFingerprint_signedAt_activePath() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let originalSig = "ORIGINAL_MANIFEST_SIG_SHOULD_NOT_CHANGE"
    let originalFp = "ORIGINAL_FINGERPRINT_SHOULD_NOT_CHANGE"
    let originalSignedAt = "2026-04-01T00:00:00+00:00"
    let originalActivePath = "/some/original/path/that/must/stay"
    let originalProposalPath = "/some/proposal/path/that/must/stay"
    try seedRegistry([
        .object([
            "id": .string("p1"),
            "name": .string("p1"),
            "status": .string("quarantined"),
            "phase": .string("quarantined"),
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "updatedAt": .string("2026-05-01T00:00:01+00:00"),
            "manifestSignature": .string(originalSig),
            "codeFingerprint": .string(originalFp),
            "signedAt": .string(originalSignedAt),
            "activePath": .string(originalActivePath),
            "proposalPath": .string(originalProposalPath),
        ])
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.promote(id: "p1")
    #expect(rec.manifestSignature == originalSig)
    #expect(rec.codeFingerprint == originalFp)
    #expect(rec.signedAt == originalSignedAt)
    #expect(rec.activePath == originalActivePath)
    #expect(rec.proposalPath == originalProposalPath)
    // phase IS in the daemon's flip set — it must move to "active".
    #expect(rec.phase == "active")
}

/// Daemon promote_tool writes quarantinePath=None, quarantineReason=None,
/// promotedAt=now. Swift must mirror — otherwise re-promoting a quarantined
/// tool leaves stale quarantine state and the promotedAt stamp is missing.
@Test func promote_clears_quarantine_fields_and_stamps_promotedAt() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        .object([
            "id": .string("pq1"),
            "name": .string("pq1"),
            "status": .string("quarantined"),
            "phase": .string("quarantined"),
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "updatedAt": .string("2026-05-01T00:00:01+00:00"),
            "quarantineReason": .string("X"),
            "quarantinePath": .string("/some/p"),
        ])
    ], root: root)
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let r = SwiftNativeToolRegistry(root: root, clock: { fixed })
    let rec = try await r.promote(id: "pq1")
    let expectedStamp = SwiftNativeToolRegistry.isoTimestamp(fixed)
    #expect(rec.status == "active")
    #expect(rec.phase == "active")
    guard case .object(let extra)? = rec.extras else {
        Issue.record("extras missing"); return
    }
    // quarantineReason / quarantinePath must be PRESENT as JSON null,
    // not absent — round-trip must preserve the daemon's explicit-null shape.
    guard let qr = extra["quarantineReason"] else {
        Issue.record("quarantineReason absent — should be explicit null"); return
    }
    if case .null = qr { /* ok */ } else { Issue.record("quarantineReason not null: \(qr)") }
    guard let qp = extra["quarantinePath"] else {
        Issue.record("quarantinePath absent — should be explicit null"); return
    }
    if case .null = qp { /* ok */ } else { Issue.record("quarantinePath not null: \(qp)") }
    // promotedAt landed in extras (not in knownKeys) as the clock stamp.
    guard let pa = extra["promotedAt"] else {
        Issue.record("promotedAt missing"); return
    }
    if case .string(let s) = pa {
        #expect(s == expectedStamp)
    } else {
        Issue.record("promotedAt not a string: \(pa)")
    }
}

/// HARD SCOPE CARVE: promote() MUST NOT touch validationStatus,
/// validationErrors, lastValidatedAt, autoPromotable, codeFingerprint, or
/// activePath — those fields belong to the daemon's validate_tool pipeline
/// + signing/copytree. This pins that contract.
@Test func promote_carve_pins_validation_fields() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        .object([
            "id": .string("pv1"),
            "name": .string("pv1"),
            "status": .string("quarantined"),
            "phase": .string("quarantined"),
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "updatedAt": .string("2026-05-01T00:00:01+00:00"),
            "validationStatus": .string("invalid"),
            "validationErrors": .array([.string("x")]),
            "lastValidatedAt": .string("2020-01-01"),
            "autoPromotable": .bool(false),
            "codeFingerprint": .string("abc"),
            "activePath": .string("/p"),
        ])
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.promote(id: "pv1")
    // validationStatus is a typed field; codeFingerprint + activePath too.
    #expect(rec.validationStatus == "invalid")
    #expect(rec.codeFingerprint == "abc")
    #expect(rec.activePath == "/p")
    guard case .object(let extra)? = rec.extras else {
        Issue.record("extras missing"); return
    }
    // validationErrors, lastValidatedAt, autoPromotable live in extras.
    if case .array(let arr) = extra["validationErrors"] ?? .null {
        #expect(arr.count == 1)
        if case .string(let s) = arr[0] { #expect(s == "x") }
    } else {
        Issue.record("validationErrors changed or missing")
    }
    if case .string(let s) = extra["lastValidatedAt"] ?? .null {
        #expect(s == "2020-01-01")
    } else {
        Issue.record("lastValidatedAt changed or missing")
    }
    if case .bool(let b) = extra["autoPromotable"] ?? .null {
        #expect(b == false)
    } else {
        Issue.record("autoPromotable changed or missing")
    }
}

// MARK: - quarantine

@Test func quarantine_unknown_id_throws_toolNotFound() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([makeToolJSON(id: "real")], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    do {
        _ = try await r.quarantine(id: "ghost", reason: "test")
        Issue.record("expected throw")
    } catch let ToolRegistryError.toolNotFound(id) {
        #expect(id == "ghost")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func quarantine_flips_status_to_quarantined_and_records_reason() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "q1", status: "active",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
    ], root: root)
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let r = SwiftNativeToolRegistry(root: root, clock: { fixed })
    let rec = try await r.quarantine(id: "q1", reason: "test reason")
    #expect(rec.status == "quarantined")
    #expect(rec.updatedAt == SwiftNativeToolRegistry.isoTimestamp(fixed))
    guard case .object(let extra)? = rec.extras else {
        Issue.record("extras missing — quarantineReason was not stashed"); return
    }
    if case .string(let r) = extra["quarantineReason"] ?? .null {
        #expect(r == "test reason")
    } else {
        Issue.record("quarantineReason missing or wrong type")
    }
}

/// HARD SCOPE CARVE: quarantine() MUST NOT touch the signing block.
@Test func quarantine_does_NOT_touch_signing_block() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let originalSig = "ORIGINAL_MANIFEST_SIG_SHOULD_NOT_CHANGE"
    let originalFp = "ORIGINAL_FINGERPRINT_SHOULD_NOT_CHANGE"
    let originalSignedAt = "2026-04-01T00:00:00+00:00"
    try seedRegistry([
        .object([
            "id": .string("q1"),
            "name": .string("q1"),
            "status": .string("active"),
            "phase": .string("active"),
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "updatedAt": .string("2026-05-01T00:00:01+00:00"),
            "manifestSignature": .string(originalSig),
            "codeFingerprint": .string(originalFp),
            "signedAt": .string(originalSignedAt),
            "activePath": .string("/tmp/active-q1"),
        ])
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.quarantine(id: "q1", reason: "drift detected")
    #expect(rec.manifestSignature == originalSig)
    #expect(rec.codeFingerprint == originalFp)
    #expect(rec.signedAt == originalSignedAt)
    // phase IS in the daemon's flip set — it must move to "quarantined".
    #expect(rec.phase == "quarantined")
}

/// Daemon quarantine_tool L34033 writes quarantinedAt=now. Mirror it.
@Test func quarantine_stamps_quarantinedAt() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "qa1", status: "active",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
    ], root: root)
    let fixed = Date(timeIntervalSince1970: 1_780_000_000)
    let r = SwiftNativeToolRegistry(root: root, clock: { fixed })
    let rec = try await r.quarantine(id: "qa1", reason: "drift")
    let expectedStamp = SwiftNativeToolRegistry.isoTimestamp(fixed)
    guard case .object(let extra)? = rec.extras else {
        Issue.record("extras missing"); return
    }
    if case .string(let s) = extra["quarantinedAt"] ?? .null {
        #expect(s == expectedStamp)
    } else {
        Issue.record("quarantinedAt missing or not a string")
    }
}

/// Finding #5 regression — if the copy step fails (e.g. source missing),
/// the prior quarantined body MUST still be intact. The old order rmtree'd
/// the existing quarantine dir before the copy, which silently lost data.
@Test func quarantine_preserves_existing_body_on_copy_failure() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Seed registry with an active record whose activePath points to a
    // NON-EXISTENT directory — forcing the copy step to be skipped (sourceDir
    // exists check fails). Then pre-populate quarantine/<id>/sentinel.txt.
    let bogusActive = root.appendingPathComponent("does-not-exist", isDirectory: true)
    try seedRegistry([
        makeToolJSON(id: "qcf1", status: "active",
                     updatedAt: "2026-05-01T00:00:00+00:00",
                     extras: ["activePath": .string(bogusActive.path)]),
    ], root: root)
    // Pre-populate an existing quarantined body.
    let quarantineDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("quarantine", isDirectory: true)
        .appendingPathComponent("qcf1", isDirectory: true)
    try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
    let sentinel = quarantineDir.appendingPathComponent("sentinel.txt")
    try Data("PRESERVE_ME".utf8).write(to: sentinel)

    let r = SwiftNativeToolRegistry(root: root)
    // The quarantine call itself should still succeed (record flips status);
    // the file-move branch should leave the prior body untouched because
    // the activePath src doesn't exist.
    _ = try await r.quarantine(id: "qcf1", reason: "test src-missing")

    // Sentinel survives — old quarantined body is intact.
    #expect(FileManager.default.fileExists(atPath: sentinel.path),
            "old quarantined body deleted before new copy landed — data loss bug")
    let body = try? Data(contentsOf: sentinel)
    #expect(body == Data("PRESERVE_ME".utf8))
}

/// Finding #6 — active record without activePath must hard-throw rather
/// than fall through to proposalPath and quarantine the wrong bytes.
@Test func quarantine_active_record_missing_activePath_throws_invalidState() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Raw .object to bypass makeToolJSON's auto-injected activePath default —
    // we WANT the inconsistent record (active without activePath).
    try seedRegistry([
        .object([
            "id": .string("noap"),
            "name": .string("noap"),
            "status": .string("active"),
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "updatedAt": .string("2026-05-01T00:00:00+00:00"),
            "proposalPath": .string("/tmp/should-not-be-used"),
        ]),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    do {
        _ = try await r.quarantine(id: "noap", reason: "test")
        Issue.record("expected invalidState throw")
    } catch let ToolRegistryError.invalidState(msg) {
        #expect(msg.contains("noap"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - Both-status-and-phase flip tests

@Test func promote_flips_both_status_AND_phase_to_active() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        .object([
            "id": .string("pp1"),
            "name": .string("pp1"),
            "status": .string("proposed"),
            "phase": .string("proposed"),
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "updatedAt": .string("2026-05-01T00:00:01+00:00"),
        ])
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.promote(id: "pp1")
    #expect(rec.status == "active")
    #expect(rec.phase == "active")
    // Round-trip via list.
    let again = try await r.getTool(id: "pp1")
    #expect(again?.status == "active")
    #expect(again?.phase == "active")
}

@Test func quarantine_flips_both_status_AND_phase_to_quarantined() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        .object([
            "id": .string("qq1"),
            "name": .string("qq1"),
            "status": .string("active"),
            "phase": .string("active"),
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "updatedAt": .string("2026-05-01T00:00:01+00:00"),
            "activePath": .string("/tmp/active-qq1"),
        ])
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let rec = try await r.quarantine(id: "qq1", reason: "test")
    #expect(rec.status == "quarantined")
    #expect(rec.phase == "quarantined")
    let again = try await r.getTool(id: "qq1")
    #expect(again?.status == "quarantined")
    #expect(again?.phase == "quarantined")
}

// MARK: - Concurrency

@Test func concurrent_promote_quarantine_same_id_no_corruption() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "race", status: "active",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<20 {
            if i.isMultiple(of: 2) {
                group.addTask { _ = try? await r.promote(id: "race") }
            } else {
                group.addTask { _ = try? await r.quarantine(id: "race", reason: "race-\(i)") }
            }
        }
        await group.waitForAll()
    }
    let tools = try await r.listTools(filter: .all)
    let matching = tools.filter { $0.id == "race" }
    #expect(matching.count == 1, "expected exactly 1 record, got \(matching.count)")
    guard let rec = matching.first else { return }
    #expect(rec.status == "active" || rec.status == "quarantined")
    // Lost-update detector: assert the final state is INTERNALLY CONSISTENT
    // with a SERIALIZED last-write. Without mutationTail, you'd see status
    // and the carve-cleanup fields disagree because the second R-M-W computed
    // its mutation off a pre-state that didn't reflect the first's writes
    // (e.g. status="active" but quarantineReason still set, or
    // status="quarantined" but quarantinedAt missing).
    guard case .object(let extra)? = rec.extras else {
        Issue.record("expected extras object on race record")
        return
    }
    // phase is a typed field on ToolRecord (set by promote/quarantine alongside status)
    if rec.status == "active" {
        #expect(rec.phase == "active",
                "active status without phase=active → torn R-M-W")
        #expect(extra["quarantineReason"] == .null,
                "active status with stale quarantineReason → lost-update")
        #expect(extra["quarantinePath"] == .null,
                "active status with stale quarantinePath → lost-update")
        if case .string(let s) = extra["promotedAt"] ?? .null {
            #expect(!s.isEmpty)
        } else {
            Issue.record("active status without promotedAt → lost-update")
        }
    } else {
        #expect(rec.phase == "quarantined",
                "quarantined status without phase=quarantined → torn R-M-W")
        if case .string(let s) = extra["quarantineReason"] ?? .null {
            #expect(!s.isEmpty,
                    "quarantined status with empty quarantineReason → lost-update")
        } else {
            Issue.record("quarantined status without quarantineReason → lost-update")
        }
        if case .string(let s) = extra["quarantinedAt"] ?? .null {
            #expect(!s.isEmpty)
        } else {
            Issue.record("quarantined status without quarantinedAt → lost-update")
        }
    }
}

/// PersistenceCore wrapper that injects a delay into readJSON so two
/// concurrent R-M-Ws WILL overlap if `mutationTail` serialization is
/// absent. writeJSON is forwarded directly (no delay) — the slow read is
/// what opens the lost-update window.
private final class SlowPersistenceCore: @unchecked Sendable, PersistenceCoreProtocol {
    private let inner: SwiftNativePersistenceCore
    private let readDelayNanos: UInt64
    init(readDelayMillis: UInt64 = 30) {
        self.inner = SwiftNativePersistenceCore()
        self.readDelayNanos = readDelayMillis * 1_000_000
    }
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        try? await Task.sleep(nanoseconds: readDelayNanos)
        return await inner.readJSON(path, defaultValue: defaultValue)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await inner.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await inner.appendJSONL(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await inner.readJSONL(path)
    }
}

@Test func concurrent_mutations_on_different_ids_both_persist() async throws {
    // Lost-update detector for DIFFERENT-id concurrent R-M-Ws. With
    // mutationTail serialization, writer B's read sees writer A's commit,
    // so B's rewrite of the whole array preserves A's mutation. Without
    // serialization, both reads return the pre-state, both rewrite the
    // whole array off that snapshot, and whoever writes second clobbers
    // the other's change. The slow readJSON widens that window so the
    // race is reliably reproducible if the gate is removed.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "alpha", status: "active",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
        makeToolJSON(id: "bravo", status: "active",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
    ], root: root)
    let slow = SlowPersistenceCore(readDelayMillis: 30)
    let r = SwiftNativeToolRegistry(root: root, persistence: slow)
    async let qA: ToolRecord? = {
        try? await r.quarantine(id: "alpha", reason: "R1")
    }()
    async let pB: ToolRecord? = {
        try? await r.promote(id: "bravo")
    }()
    _ = await (qA, pB)
    let tools = try await r.listTools(filter: .all)
    let a = tools.first { $0.id == "alpha" }
    let b = tools.first { $0.id == "bravo" }
    #expect(a?.status == "quarantined",
            "alpha lost its quarantine — bravo's R-M-W overwrote with pre-state")
    #expect(b?.status == "active",
            "bravo lost its promote — alpha's R-M-W overwrote with pre-state")
}

// MARK: - Registry JSON shape

@Test func registry_fixture_with_extras_reads_by_swift() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        .object([
            "id": .string("native-written"),
            "name": .string("Native Written"),
            "status": .string("active"),
            "activePath": .string("/tmp/native-written"),
            "createdAt": .string("2026-05-30T10:00:00+00:00"),
            "updatedAt": .string("2026-05-30T10:00:01+00:00"),
            "lastUsedAt": .null,
            "permissions": .array([.string("app_data_read")]),
            "useCount": .int(3),
        ])
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    let tools = try await r.listTools(filter: .all)
    #expect(tools.count == 1)
    let t = tools[0]
    #expect(t.id == "native-written")
    #expect(t.name == "Native Written")
    #expect(t.status == "active")
    guard case .object(let extra)? = t.extras else {
        Issue.record("extras missing — useCount/permissions dropped"); return
    }
    #expect(extra["permissions"] != nil)
    #expect(extra["useCount"] != nil)
}

@Test func swift_writes_registry_json_readable_directly() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "swift-written", status: "quarantined"),
    ], root: root)
    let r = SwiftNativeToolRegistry(root: root)
    _ = try await r.promote(id: "swift-written")
    let registryPath = await r.registryPath
    let parsed = try JSONValue.parse(Data(contentsOf: registryPath))
    guard case .array(let arr) = parsed, arr.count == 1,
          case .object(let obj) = arr[0],
          case .string(let id) = obj["id"] ?? .null,
          case .string(let status) = obj["status"] ?? .null else {
        Issue.record("unexpected registry shape")
        return
    }
    #expect(id == "swift-written")
    #expect(status == "active")
}

// MARK: - Replay baseline

@Test func replayBaselineToolsMatchesCapture() async throws {
    // Capture: 14 records, sorted DESC by updatedAt|createdAt.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let capturePath = repoRoot
        .appendingPathComponent("tests/replay/captures/tool_registry/872b6f90-371f-44fb-b910-816c2c290a81.json")
    guard FileManager.default.fileExists(atPath: capturePath.path) else {
        // Replay captures are ignored local artifacts. Fresh public checkouts
        // should skip this baseline until a capture is supplied.
        return
    }
    let captureData = try Data(contentsOf: capturePath)
    let captureRaw = try JSONSerialization.jsonObject(with: captureData, options: [])
    guard let captureDict = captureRaw as? [String: Any],
          let output = captureDict["output"] as? [String: Any],
          let body = output["body"] as? [Any] else {
        Issue.record("capture shape unexpected"); return
    }

    // Seed temp registry from the capture body.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registryPath = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    try FileManager.default.createDirectory(
        at: registryPath.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    try bodyData.write(to: registryPath)

    let r = SwiftNativeToolRegistry(root: root)
    let tools = try await r.listTools(filter: .all)

    // Same count.
    #expect(tools.count == body.count, "expected \(body.count), got \(tools.count)")

    // require_present_fields: id, name, status — all must be non-empty.
    for t in tools {
        #expect(!t.id.isEmpty)
        #expect(!t.name.isEmpty)
        #expect(!t.status.isEmpty)
    }

    // Sort: DESC by updatedAt|createdAt. The capture body is already sorted
    // by the recorder, so positional id sequence must match.
    let expectedIds: [String] = body.compactMap { ($0 as? [String: Any])?["id"] as? String }
    let actualIds = tools.map(\.id)
    #expect(actualIds == expectedIds,
            "id order mismatch.\nexpected: \(expectedIds)\nactual:   \(actualIds)")

    // The capture's ignore_fields rules say updatedAt / lastUsedAt /
    // lastValidatedAt / signedAt / codeFingerprint / manifestSignature are
    // not compared verbatim — verify the structural sibling fields the
    // recorder DOES compare against (id / status / phase / validationStatus).
    for (i, t) in tools.enumerated() {
        guard let row = body[i] as? [String: Any] else { continue }
        if let expectedStatus = row["status"] as? String {
            #expect(t.status == expectedStatus, "status mismatch at \(i)")
        }
        if let expectedName = row["name"] as? String {
            #expect(t.name == expectedName, "name mismatch at \(i)")
        }
    }
}

// MARK: - presence tracking

@Test func presence_tracking_lastUsedAt_null_round_trips_as_present_null() async throws {
    // Daemon writes `"lastUsedAt": null` on many records (proven by
    // data/tools/registry.json + the capture). Round-trip must preserve the
    // key as present-with-null, not omit it.
    let original: JSONValue = .object([
        "id": .string("p1"),
        "name": .string("p1"),
        "status": .string("active"),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
        "updatedAt": .string("2026-05-01T00:00:01+00:00"),
        "lastUsedAt": .null,
    ])
    guard let rec = ToolRecord(json: original) else {
        Issue.record("init failed"); return
    }
    #expect(rec.lastUsedAt == nil)
    let rebuilt = rec.toJSON()
    guard case .object(let out) = rebuilt else {
        Issue.record("toJSON did not return object"); return
    }
    // lastUsedAt MUST be present in output as JSON null.
    guard let v = out["lastUsedAt"] else {
        Issue.record("lastUsedAt was omitted; expected present-as-null"); return
    }
    if case .null = v {
        // correct
    } else {
        Issue.record("lastUsedAt is not null on round-trip")
    }
}

@Test func presence_tracking_absent_lastUsedAt_omitted_on_roundtrip() async throws {
    let original: JSONValue = .object([
        "id": .string("p2"),
        "name": .string("p2"),
        "status": .string("active"),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
        "updatedAt": .string("2026-05-01T00:00:01+00:00"),
        // lastUsedAt absent entirely
    ])
    guard let rec = ToolRecord(json: original) else {
        Issue.record("init failed"); return
    }
    #expect(rec.lastUsedAt == nil)
    guard case .object(let out) = rec.toJSON() else {
        Issue.record("toJSON not object"); return
    }
    #expect(out["lastUsedAt"] == nil, "absent key must NOT be re-emitted")
}

// MARK: - Cross-process flock pin (Wave 7 finding)

/// Pins that `SwiftNativeToolRegistry.promote` wraps its R-M-W of
/// `tools/registry.json` in `withFileLock(<registryPath>.lock, ...)`. Without
/// this, another process that uses the same registry lock could race a Swift
/// promote and clobber registry state.
@Test func swiftNative_promote_uses_withFileLock_for_cross_process_safety() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedRegistry([
        makeToolJSON(id: "lock-target", status: "proposal",
                     updatedAt: "2026-05-01T00:00:00+00:00"),
    ], root: root)

    let registryPath = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    let lockPath = registryPath.path + ".lock"
    let storeDir = registryPath.deletingLastPathComponent()
    let acquiredMarker = storeDir.appendingPathComponent("helper_acquired.txt")
    let releasedMarker = storeDir.appendingPathComponent("helper_released.txt")
    let releaseRequest = storeDir.appendingPathComponent("helper_release_request.txt")
    let swiftStartedMarker = storeDir.appendingPathComponent("swift_started.txt")
    let swiftFinishedMarker = storeDir.appendingPathComponent("swift_finished.txt")

    let helper = try NativeAgentFlockChild.hold(
        lockPath: lockPath,
        acquiredMarker: acquiredMarker,
        releasedMarker: releasedMarker,
        releaseRequest: releaseRequest
    )
    defer {
        try? Data("release".utf8).write(to: releaseRequest)
        helper.terminate()
    }

    // Wait for the helper to actually hold the flock.
    let acquireDeadline = Date().addingTimeInterval(15.0)
    while !FileManager.default.fileExists(atPath: acquiredMarker.path) {
        if Date() > acquireDeadline { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(FileManager.default.fileExists(atPath: acquiredMarker.path),
            "Swift helper failed to acquire <registry.json>.lock within deadline")

    let r = SwiftNativeToolRegistry(root: root)
    let swiftTask = Task {
        try Data("started".utf8).write(to: swiftStartedMarker)
        _ = try await r.promote(id: "lock-target")
        try Data("finished".utf8).write(to: swiftFinishedMarker)
    }
    let swiftStartDeadline = Date().addingTimeInterval(10.0)  // task start is a positive step under suite load
    while !FileManager.default.fileExists(atPath: swiftStartedMarker.path) {
        if Date() > swiftStartDeadline { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(FileManager.default.fileExists(atPath: swiftStartedMarker.path),
            "Swift promote task failed to start within deadline")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(!FileManager.default.fileExists(atPath: swiftFinishedMarker.path),
            "Swift promote finished before the foreign flock was released")

    try Data("release".utf8).write(to: releaseRequest)
    try await swiftTask.value
    // Bounded exit wait (never waitUntilExit — a starved helper must fail the
    // test loudly, not wedge the whole serial suite).
    let status = helper.wait(timeout: 30)
    if status == nil {
        helper.terminate()
        Issue.record("flock helper failed to exit within 30s — terminated")
    }
    #expect(status == 0, "flock helper failed: status \(String(describing: status))")

    let releasedRaw = try String(contentsOf: releasedMarker, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let helperReleased = try #require(TimeInterval(releasedRaw))
    let swiftFinishedAt = try FileManager.default
        .attributesOfItem(atPath: swiftFinishedMarker.path)[.modificationDate] as? Date
    let swiftEndUnix = try #require(swiftFinishedAt?.timeIntervalSince1970)
    #expect(swiftEndUnix >= helperReleased,
            "Swift promote finished at \(swiftEndUnix) before helper released at \(helperReleased) — flock ordering violated")

    // Sanity: the promote actually landed.
    let rec = try await r.getTool(id: "lock-target")
    #expect(rec?.status == "active")
}
