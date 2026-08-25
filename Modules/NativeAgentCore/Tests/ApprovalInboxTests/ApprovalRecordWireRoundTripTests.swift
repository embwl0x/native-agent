import Foundation
import Testing
import PersistenceCore
@testable import ApprovalInbox

// Ledger row: approvals.record.wireRoundTrip
//
// Silent-failure class: DROPPED ROW / WRONG VALUE. `ApprovalRecord.init?(json:)`
// reads 17 named fields with tolerant `str`/`optStr`/`bool` readers and
// `toJSON()` emits exactly those 17 with a deliberately asymmetric null policy
// (`resolvedAt`/`decision` explicit null; `executedAction`/`detail` OMITTED when
// nil; `decidedBy`/`resolutionProvenance` omitted when nil). Every read/mutate
// of the authority store goes through this pair, so a field that stops
// round-tripping is silently ERASED on the next write of an unrelated row —
// e.g. a lost `executedAction` makes an already-executed approval look
// unexecuted, and a lost `remoteResolvable` re-widens authority.

private func fullRecord() -> ApprovalRecord {
    ApprovalRecord(
        id: "approval-full",
        title: "Send the release note",
        action: "external_send",
        risk: "high",
        reason: "outbound message",
        status: "resolved",
        payload: .object([
            "to": .string("user"),
            "body": .string("ship it"),
            "nested": .object(["depth": .int(2), "flag": .bool(false), "ratio": .double(0.5)]),
            "list": .array([.string("a"), .int(1), .null]),
        ]),
        payloadPreview: "to user: ship it",
        createdAt: "2026-08-23T10:00:00Z",
        resolvedAt: "2026-08-23T10:05:00Z",
        decision: "approved",
        decidedBy: "user",
        resolutionProvenance: .signedIOS(clientID: "client-7", decidedBy: "user"),
        remoteResolvable: true,
        localOnly: false,
        executedAction: .object(["ok": .bool(true), "receipt": .string("r-1")]),
        detail: "sent"
    )
}

private func minimalRecord() -> ApprovalRecord {
    ApprovalRecord(
        id: "approval-minimal",
        title: "Approval required",
        action: "shell",
        risk: "medium",
        reason: "",
        status: "pending",
        payload: .object([:]),
        payloadPreview: "{}",
        createdAt: "2026-08-23T10:00:00Z",
        remoteResolvable: false,
        localOnly: true
    )
}

private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let obj) = value else {
        throw ApprovalInboxError.malformedResponse("not an object")
    }
    return obj
}

@Test("a fully-populated record survives toJSON → init(json:) byte-for-byte")
func approvalRecordFullRoundTrip() throws {
    let original = fullRecord()
    let decoded = try #require(ApprovalRecord(json: original.toJSON()))

    #expect(decoded.id == original.id)
    #expect(decoded.title == original.title)
    #expect(decoded.action == original.action)
    #expect(decoded.risk == original.risk)
    #expect(decoded.reason == original.reason)
    #expect(decoded.status == original.status)
    #expect(decoded.payload == original.payload)
    #expect(decoded.payloadPreview == original.payloadPreview)
    #expect(decoded.createdAt == original.createdAt)
    #expect(decoded.resolvedAt == original.resolvedAt)
    #expect(decoded.decision == original.decision)
    #expect(decoded.decidedBy == original.decidedBy)
    #expect(decoded.resolutionProvenance == original.resolutionProvenance)
    #expect(decoded.remoteResolvable == original.remoteResolvable)
    #expect(decoded.localOnly == original.localOnly)
    #expect(decoded.executedAction == original.executedAction)
    #expect(decoded.detail == original.detail)

    // Re-encoding is a fixpoint: two writes of the same row produce identical
    // bytes, so an untouched row never churns the authority store.
    #expect(decoded.toJSON() == original.toJSON())
    #expect(try decoded.toJSON().serializedData(pretty: true)
            == original.toJSON().serializedData(pretty: true))
}

@Test("the emitted key set is exactly the documented wire shape")
func approvalRecordEmitsTheDocumentedKeys() throws {
    let full = try object(fullRecord().toJSON())
    #expect(Set(full.keys) == Set([
        "id", "title", "action", "risk", "reason", "status", "payload",
        "payloadPreview", "createdAt", "resolvedAt", "decision", "decidedBy",
        "resolutionProvenance", "remoteResolvable", "localOnly",
        "executedAction", "detail",
    ]))

    let minimal = try object(minimalRecord().toJSON())
    // Nullable-but-always-present fields keep an explicit null (Python parity).
    #expect(minimal["resolvedAt"] == .null)
    #expect(minimal["decision"] == .null)
    // Post-execution fields are OMITTED, not null — Python only adds these keys
    // after the action ran, and a null here reads as "executed with no result".
    #expect(minimal["executedAction"] == nil)
    #expect(minimal["detail"] == nil)
    #expect(minimal["decidedBy"] == nil)
    #expect(minimal["resolutionProvenance"] == nil)
    #expect(Set(minimal.keys) == Set([
        "id", "title", "action", "risk", "reason", "status", "payload",
        "payloadPreview", "createdAt", "resolvedAt", "decision",
        "remoteResolvable", "localOnly",
    ]))
}

@Test("explicit nulls decode back to nil, not to empty strings")
func approvalRecordNullFieldsDecodeToNil() throws {
    let decoded = try #require(ApprovalRecord(json: minimalRecord().toJSON()))
    #expect(decoded.resolvedAt == nil)
    #expect(decoded.decision == nil)
    #expect(decoded.decidedBy == nil)
    #expect(decoded.resolutionProvenance == nil)
    #expect(decoded.executedAction == nil)
    #expect(decoded.detail == nil)
    #expect(decoded.remoteResolvable == false)
    #expect(decoded.localOnly == true)
}

@Test("every resolution-provenance channel round-trips with its bound identity")
func approvalRecordProvenanceChannelsRoundTrip() throws {
    let provenances: [ApprovalResolutionProvenance] = [
        .local(decidedBy: "user"),
        .telegram(chatID: "-100123", userID: "42"),
        .signedIOS(clientID: "client-7", decidedBy: "user"),
    ]
    for provenance in provenances {
        var record = fullRecord()
        record.resolutionProvenance = provenance
        let decoded = try #require(ApprovalRecord(json: record.toJSON()))
        #expect(decoded.resolutionProvenance == provenance)
        // `remote` is authority-bearing: it must be carried, not recomputed
        // from a channel string the reader trusts.
        let wire = try object(try object(record.toJSON())["resolutionProvenance"] ?? .null)
        let expectedRemote: Bool
        switch provenance {
        case .local: expectedRemote = false
        case .telegram, .signedIOS: expectedRemote = true
        }
        #expect(wire["remote"] == .bool(expectedRemote))
        #expect(wire["schema"] == .string(ApprovalResolutionProvenance.schema))
        // The reader re-derives `remote` from the case and REJECTS a row whose
        // carried flag disagrees — a forged downgrade cannot pass.
        var forged = wire
        forged["remote"] = .bool(!expectedRemote)
        #expect(ApprovalResolutionProvenance(json: .object(forged)) == nil)
    }
}

@Test("a row with no id is rejected rather than silently becoming an empty-id row")
func approvalRecordRejectsIdlessRows() {
    #expect(ApprovalRecord(json: .object([:])) == nil)
    #expect(ApprovalRecord(json: .object(["id": .string("")])) == nil)
    #expect(ApprovalRecord(json: .object(["id": .null, "title": .string("x")])) == nil)
    #expect(ApprovalRecord(json: .array([])) == nil)
    #expect(ApprovalRecord(json: .string("approval-1")) == nil)
}

@Test("a wrong-typed authority flag reads as false, never as truthy")
func approvalRecordAuthorityFlagsFailClosed() throws {
    // The Python-era truthiness bug: any non-empty string coerced to true.
    for poison: JSONValue in [.string("true"), .string("false"), .int(1), .null, .array([])] {
        let decoded = try #require(ApprovalRecord(json: .object([
            "id": .string("a"),
            "status": .string("pending"),
            "remoteResolvable": poison,
            "localOnly": poison,
        ])))
        #expect(decoded.remoteResolvable == false, "remoteResolvable widened by \(poison)")
        #expect(decoded.localOnly == false)
    }
}

@Test("executedAction is lossless — an arbitrary nested receipt survives a round-trip")
func approvalRecordExecutedActionIsLossless() throws {
    let receipt = JSONValue.object([
        "ok": .bool(true),
        "stdout": .string("done\nwith\ttabs and \u{1F600}"),
        "counts": .array([.int(0), .int(-1), .double(1.5)]),
        "nested": .object(["deep": .object(["deeper": .array([.null, .bool(false)])])]),
    ])
    var record = minimalRecord()
    record.executedAction = receipt
    let decoded = try #require(ApprovalRecord(json: record.toJSON()))
    #expect(decoded.executedAction == receipt)
    #expect(try decoded.toJSON().serializedData(pretty: false)
            == record.toJSON().serializedData(pretty: false))
}

@Test("a record survives a real serialize → parse trip through the store bytes")
func approvalRecordSurvivesStoreBytes() throws {
    let original = fullRecord()
    let bytes = try JSONValue.array([original.toJSON()]).serializedData(pretty: true)
    guard case .array(let items) = try JSONValue.parse(bytes), let first = items.first else {
        Issue.record("store bytes did not parse back to an array")
        return
    }
    let decoded = try #require(ApprovalRecord(json: first))
    #expect(decoded.toJSON() == original.toJSON())
}
