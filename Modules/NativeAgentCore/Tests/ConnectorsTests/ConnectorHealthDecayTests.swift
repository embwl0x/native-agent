import Testing
import Foundation
@testable import Connectors
import NativeAgentCore
import PersistenceCore

// MARK: - Fable 5.1 sweep item 49 — connector health decays
//
// The registry's `healthStatus: "ok"` used to be derived from OAuth-token-FILE
// PRESENCE and rendered green forever, with `lastCheckedAt` frozen at
// 2026-06-02. These tests hold the replacement honest: a connector is green
// only while a REAL successful call proves it, and it decays on a clock.

private func decayRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("connector-decay-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeReceipts(_ root: URL, _ lines: [JSONValue]) throws {
    let path = ConnectorProofLedger.receiptsPath(root: root)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = try lines
        .map { String(data: try $0.serializedData(pretty: false), encoding: .utf8) ?? "" }
        .joined(separator: "\n") + "\n"
    try Data(text.utf8).write(to: path)
}

private func receipt(
    connectorId: String,
    status: String,
    at: Date,
    dryRun: Bool = false
) -> JSONValue {
    .object([
        "id": .string(UUID().uuidString),
        "actionId": .string("\(connectorId).probe"),
        "connectorId": .string(connectorId),
        "name": .string("\(connectorId) probe"),
        "status": .string(status),
        "dryRun": .bool(dryRun),
        "approvalId": .null,
        "createdAt": .string(ConnectorHealthDecay.isoTimestamp(at)),
    ])
}

/// A row shaped exactly like the runtime overlay's token-presence output: a
/// live-looking claim with the frozen registry stamp still on it, carrying the
/// overlay's credential proof-source stamp — the bit that makes it decayable.
private func tokenPresenceRow(id: String) -> [String: JSONValue] {
    [
        "id": .string(id),
        "name": .string(id),
        "enabled": .bool(true),
        "authState": .string("connected"),
        "healthStatus": .string("ok"),
        "lastCheckedAt": .string("2026-06-02T00:00:00+00:00"),
        ConnectorHealthDecay.proofSourceKey: .string(ConnectorHealthDecay.credentialProofSource),
    ]
}

/// A row shaped like the overlay's LOCAL readiness output: green, but green
/// because the machine can answer for it right now (a granted EventKit
/// permission, a configured Telegram bot) — no credential proof stamp, and no
/// receipt stream that could ever refresh one.
private func localReadinessRow(id: String, authState: String) -> [String: JSONValue] {
    [
        "id": .string(id),
        "name": .string(id),
        "enabled": .bool(true),
        "authState": .string(authState),
        "healthStatus": .string("ok"),
    ]
}

private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

private let now = Date(timeIntervalSince1970: 1_788_000_000)

// MARK: - the three states

@Test func decay_freshSuccessfulCallStaysOkAndCarriesThatCallsTimestamp() throws {
    let root = try decayRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let proven = now.addingTimeInterval(-2 * 24 * 3600)   // two days ago
    try writeReceipts(root, [receipt(connectorId: "slack", status: "succeeded", at: proven)])

    let proof = ConnectorProofLedger.lastSuccessByConnector(root: root)
    let row = ConnectorHealthDecay.apply(
        to: tokenPresenceRow(id: "slack"), lastSuccessAt: proof["slack"], now: now)

    #expect(row["healthStatus"] == .string("ok"))
    #expect(row["authState"] == .string("connected"))
    // The frozen 2026-06-02 stamp is replaced by the call that actually proved it.
    #expect(str(row["lastCheckedAt"]) == ConnectorHealthDecay.isoTimestamp(proven))
}

@Test func decay_eightDaysUntouchedReadsUnverified() throws {
    let root = try decayRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let proven = now.addingTimeInterval(-8 * 24 * 3600)
    try writeReceipts(root, [receipt(connectorId: "slack", status: "succeeded", at: proven)])

    let proof = ConnectorProofLedger.lastSuccessByConnector(root: root)
    #expect(ConnectorHealthDecay.verification(lastSuccessAt: proof["slack"], now: now) == .stale)

    let row = ConnectorHealthDecay.apply(
        to: tokenPresenceRow(id: "slack"), lastSuccessAt: proof["slack"], now: now)
    #expect(row["healthStatus"] == .string("unverified"))
    // Still connected — the credential is real; only the health claim decayed.
    #expect(row["authState"] == .string("connected"))
    #expect(str(row["lastCheckedAt"]) == ConnectorHealthDecay.isoTimestamp(proven))
}

@Test func decay_tokenPresenceWithNoCallEverReadsConfiguredUnverified() throws {
    let root = try decayRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // No receipts file at all — a token on disk and nothing behind it.
    let proof = ConnectorProofLedger.lastSuccessByConnector(root: root)
    #expect(proof.isEmpty)

    let row = ConnectorHealthDecay.apply(
        to: tokenPresenceRow(id: "slack"), lastSuccessAt: proof["slack"], now: now)
    #expect(row["authState"] == .string("configured"))
    #expect(row["healthStatus"] == .string("unverified"))
    // No check ever happened, so the frozen stamp dies rather than being kept.
    #expect(row["lastCheckedAt"] == .null)
}

@Test func decay_aNewSuccessfulCallRefreshesAStaleConnector() throws {
    let root = try decayRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = now.addingTimeInterval(-30 * 24 * 3600)
    try writeReceipts(root, [receipt(connectorId: "slack", status: "succeeded", at: old)])
    let stale = ConnectorHealthDecay.apply(
        to: tokenPresenceRow(id: "slack"),
        lastSuccessAt: ConnectorProofLedger.lastSuccessByConnector(root: root)["slack"],
        now: now)
    #expect(stale["healthStatus"] == .string("unverified"))

    // The connector is used again — one new receipt, nothing else changes.
    let justNow = now.addingTimeInterval(-60)
    try writeReceipts(root, [
        receipt(connectorId: "slack", status: "succeeded", at: old),
        receipt(connectorId: "slack", status: "completed", at: justNow),
    ])
    let refreshed = ConnectorHealthDecay.apply(
        to: tokenPresenceRow(id: "slack"),
        lastSuccessAt: ConnectorProofLedger.lastSuccessByConnector(root: root)["slack"],
        now: now)
    #expect(refreshed["healthStatus"] == .string("ok"))
    #expect(str(refreshed["lastCheckedAt"]) == ConnectorHealthDecay.isoTimestamp(justNow))
}

// MARK: - what does NOT count as proof

@Test func proof_dryRunsAndFailuresAreNotEvidence() throws {
    let root = try decayRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeReceipts(root, [
        receipt(connectorId: "slack", status: "succeeded", at: now, dryRun: true),
        receipt(connectorId: "slack", status: "failed", at: now),
        receipt(connectorId: "slack", status: "needs_probe", at: now),
        receipt(connectorId: "slack", status: "pending_approval", at: now),
    ])
    #expect(ConnectorProofLedger.lastSuccessByConnector(root: root)["slack"] == nil)
}

@Test func proof_receiptAndRegistrySpellingsFoldOntoOneConnector() throws {
    let root = try decayRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let proven = now.addingTimeInterval(-3600)
    // Receipts say "email"/"calendar"; the registry rows say "gmail"/"gcal".
    try writeReceipts(root, [
        receipt(connectorId: "email", status: "succeeded", at: proven),
        receipt(connectorId: "calendar", status: "completed", at: proven),
    ])
    let proof = ConnectorProofLedger.lastSuccessByConnector(root: root)
    #expect(proof[ConnectorProofLedger.canonicalID("gmail")] != nil)
    #expect(proof[ConnectorProofLedger.canonicalID("gcal")] != nil)

    let gmail = ConnectorHealthDecay.apply(
        to: tokenPresenceRow(id: "gmail"),
        lastSuccessAt: proof[ConnectorProofLedger.canonicalID("gmail")],
        now: now)
    #expect(gmail["healthStatus"] == .string("ok"))
}

// MARK: - decay only downgrades an unproven green; it never invents a state

@Test func decay_leavesRowsThatDoNotClaimHealthOkAlone() {
    let needsAuth: [String: JSONValue] = [
        "id": .string("notion"),
        "authState": .string("not_connected"),
        "healthStatus": .string("needs_auth"),
    ]
    #expect(ConnectorHealthDecay.apply(to: needsAuth, lastSuccessAt: nil, now: now) == needsAuth)

    // A local, credential-free surface reports "ready", not "ok" — a probe-free
    // readiness claim is honest and must not be decayed into a warning.
    let ready: [String: JSONValue] = [
        "id": .string("browser"),
        "authState": .string("not_required"),
        "healthStatus": .string("ready"),
    ]
    #expect(ConnectorHealthDecay.apply(to: ready, lastSuccessAt: nil, now: now) == ready)
}

// MARK: - a green that is not a CREDENTIAL green never decays
//
// The 2026-09-01 HIGH: "healthStatus == ok" was the whole eligibility test, so
// the local-readiness rows decayed too. Neither of these connectors ever emits
// a connector-action receipt, so decay could only ever downgrade them — on a
// fresh install and on a fresh permission grant they read `configured,
// unverified` while working perfectly.

@Test func decay_localReadinessGreensAreNotDecayed() {
    // EventKit calendar: the OS says the permission is granted. That is a fact
    // the machine can answer for now, not a stale credential claim.
    let calendar = localReadinessRow(id: "calendar", authState: "connected")
    #expect(ConnectorHealthDecay.apply(to: calendar, lastSuccessAt: nil, now: now) == calendar)

    // Telegram: a configured, enabled bot the poll loop owns.
    let telegram = localReadinessRow(id: "telegram", authState: "configured")
    #expect(ConnectorHealthDecay.apply(to: telegram, lastSuccessAt: nil, now: now) == telegram)

    // Not even an eight-day-old receipt drags them down: without the stamp
    // there is nothing to decay in the first place.
    let old = now.addingTimeInterval(-30 * 24 * 3600)
    #expect(ConnectorHealthDecay.apply(to: calendar, lastSuccessAt: old, now: now) == calendar)
    #expect(ConnectorHealthDecay.apply(to: telegram, lastSuccessAt: old, now: now) == telegram)
}

@Test func decay_theStampIsWhatMakesARowEligible() {
    // Same row, same absent proof — the ONLY difference is the overlay's
    // credential stamp, and it is the difference between green and unverified.
    var stamped = localReadinessRow(id: "slack", authState: "connected")
    stamped[ConnectorHealthDecay.proofSourceKey] =
        .string(ConnectorHealthDecay.credentialProofSource)
    let decayed = ConnectorHealthDecay.apply(to: stamped, lastSuccessAt: nil, now: now)
    #expect(decayed["healthStatus"] == .string("unverified"))
    #expect(decayed["authState"] == .string("configured"))

    // An unrecognized proof source is not credential proof, so it is left alone.
    var other = localReadinessRow(id: "slack", authState: "connected")
    other[ConnectorHealthDecay.proofSourceKey] = .string("local_permission")
    #expect(ConnectorHealthDecay.apply(to: other, lastSuccessAt: nil, now: now) == other)
}

@Test func decay_windowBoundaryAndClockSkew() {
    let exactlySevenDays = now.addingTimeInterval(-ConnectorHealthDecay.provenWindow)
    #expect(ConnectorHealthDecay.verification(lastSuccessAt: exactlySevenDays, now: now) == .fresh)
    #expect(ConnectorHealthDecay.verification(
        lastSuccessAt: exactlySevenDays.addingTimeInterval(-1), now: now) == .stale)
    // A receipt stamped slightly ahead of the local clock is still evidence.
    #expect(ConnectorHealthDecay.verification(
        lastSuccessAt: now.addingTimeInterval(90), now: now) == .fresh)
}
