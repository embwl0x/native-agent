// P2-2 de-mission — two-vocabulary seam tests for the Mac-local activity
// envelope and the Workshop-step approval payload.
//
// Same four corners as the checkpoint seam tests, per type:
//   (a) a LIVE-SHAPED old-key fixture still decodes,
//   (b) a new-key fixture decodes,
//   (c) decode-old -> encode emits ONLY the new key,
//   (d) neither key behaves as before (nil/absent, never a crash).
//
// The activity fixture below is a REAL row copied from the live
// data/activity/events.jsonl envelope shape, not one minted by the encoder
// under test. 4762 historical rows carry "missionId"; the read-fallback is
// permanent, so corner (a) is a forever-guard, not a migration-window test.

import Foundation
import Testing

import NativeAgentCore
import NativeAgentShared

private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func objectKeys(_ data: Data) throws -> Set<String> {
    let any = try JSONSerialization.jsonObject(with: data)
    guard let dict = any as? [String: Any] else { return [] }
    return Set(dict.keys)
}

// MARK: - ActivityEvent (data/activity/events.jsonl)

/// Live shape of an events.jsonl row written before the P2-2 flip.
private let legacyActivityJSON = """
{"id":"6f1c9b2e-0000-4d1a-9c11-8a2b3c4d5e6f","kind":"mission",\
"title":"Workshop task created","detail":"tighten the SSE decoder","status":"ok",\
"missionId":"wsx-42","createdAt":"2026-07-11T04:00:00Z"}
"""

private let canonicalActivityJSON = """
{"id":"6f1c9b2e-0000-4d1a-9c11-8a2b3c4d5e6f","kind":"execution",\
"title":"Workshop task created","detail":"tighten the SSE decoder","status":"ok",\
"executionId":"wsx-42","createdAt":"2026-07-11T04:00:00Z"}
"""

@Test("activity: legacy missionId row still decodes (4762 live rows depend on this)")
func activityDecodesLegacyKey() throws {
    let ev = try decoder.decode(ActivityEvent.self, from: Data(legacyActivityJSON.utf8))
    #expect(ev.executionId == "wsx-42")
    #expect(ev.kind == "mission")
    #expect(ev.status == "ok")
}

@Test("activity: canonical executionId row decodes")
func activityDecodesCanonicalKey() throws {
    let ev = try decoder.decode(ActivityEvent.self, from: Data(canonicalActivityJSON.utf8))
    #expect(ev.executionId == "wsx-42")
    #expect(ev.kind == "execution")
}

@Test("activity: canonical wins when a row carries BOTH keys")
func activityPrefersCanonicalOverLegacy() throws {
    let both = """
    {"id":"a1","kind":"k","title":"t","status":"ok","createdAt":"c",\
    "executionId":"new-id","missionId":"old-id"}
    """
    let ev = try decoder.decode(ActivityEvent.self, from: Data(both.utf8))
    #expect(ev.executionId == "new-id")
}

@Test("activity: decode legacy -> encode emits ONLY executionId")
func activityRoundTripDropsLegacyKey() throws {
    let ev = try decoder.decode(ActivityEvent.self, from: Data(legacyActivityJSON.utf8))
    let data = try encoder.encode(ev)
    let keys = try objectKeys(data)
    #expect(keys.contains("executionId"))
    #expect(!keys.contains("missionId"))
}

@Test("activity: a row with NEITHER key decodes with nil executionId, no crash")
func activityMissingBothKeysIsNil() throws {
    // The envelope writers emit a null id for non-execution events, and older
    // rows omit the field entirely. Both must stay non-fatal — this field has
    // always been optional and the flip must not change that.
    let omitted = """
    {"id":"a2","kind":"chat","title":"t","status":"ok","createdAt":"c"}
    """
    let ev = try decoder.decode(ActivityEvent.self, from: Data(omitted.utf8))
    #expect(ev.executionId == nil)

    let explicitNulls = """
    {"id":"a3","kind":"chat","title":"t","status":"ok","createdAt":"c",\
    "executionId":null,"missionId":null}
    """
    let ev2 = try decoder.decode(ActivityEvent.self, from: Data(explicitNulls.utf8))
    #expect(ev2.executionId == nil)
}

@Test("activity: a nil executionId encodes to no key at all, not a legacy key")
func activityNilEncodesNoLegacyKey() throws {
    let omitted = """
    {"id":"a4","kind":"chat","title":"t","status":"ok","createdAt":"c"}
    """
    let ev = try decoder.decode(ActivityEvent.self, from: Data(omitted.utf8))
    let keys = try objectKeys(try encoder.encode(ev))
    #expect(!keys.contains("missionId"))
    #expect(!keys.contains("executionId"))
}

// MARK: - Workshop-step approval payload (workflows/approvals/requests.json)
//
// These exercise the SHARED resolver both readers route through
// (BackgroundLoopsAssembly's dedupe scan and NativeClient+ApprovalExecutors'
// resume guard), so the assertions are about production behavior rather than a
// restatement of the lookup expression.

/// Live shape of the payload on an approval staged by a 0.3.x binary.
private let legacyApprovalPayload: [String: String] = [
    "kind": "mission.step",
    "mission_id": "wsx-42",
    "step_id": "step-3",
    "tool": "shell",
]

private let canonicalApprovalPayload: [String: String] = [
    "kind": "execution.step",
    "execution_id": "wsx-42",
    "step_id": "step-3",
    "tool": "shell",
]

@Test("approval: legacy mission_id payload still resolves (7 live rows depend on this)")
func approvalResolvesLegacyKey() {
    let id = WorkshopStepApprovalPayload.executionId { legacyApprovalPayload[$0] }
    #expect(id == "wsx-42")
}

@Test("approval: canonical execution_id payload resolves")
func approvalResolvesCanonicalKey() {
    let id = WorkshopStepApprovalPayload.executionId { canonicalApprovalPayload[$0] }
    #expect(id == "wsx-42")
}

@Test("approval: canonical wins when a payload carries BOTH keys")
func approvalPrefersCanonicalOverLegacy() {
    let both = ["execution_id": "new-id", "mission_id": "old-id"]
    #expect(WorkshopStepApprovalPayload.executionId { both[$0] } == "new-id")
}

@Test("approval: neither key resolves to nil, no crash")
func approvalMissingBothKeysIsNil() {
    let neither = ["kind": "execution.step", "step_id": "step-3"]
    #expect(WorkshopStepApprovalPayload.executionId { neither[$0] } == nil)
}

@Test("approval: an empty id is treated as absent, not as a valid execution")
func approvalEmptyIdIsAbsent() {
    // The resume guard rejected empty ids before the flip; keep that.
    let empty = ["execution_id": "", "mission_id": ""]
    #expect(WorkshopStepApprovalPayload.executionId { empty[$0] } == nil)
    // An empty canonical must fall THROUGH to a usable legacy value rather
    // than shadowing it.
    let emptyCanonical = ["execution_id": "", "mission_id": "wsx-9"]
    #expect(WorkshopStepApprovalPayload.executionId { emptyCanonical[$0] } == "wsx-9")
}

@Test("approval: writers may only emit the canonical key")
func approvalWriterKeyIsCanonical() {
    // Guard against a future edit re-pointing the stager at the legacy spelling.
    #expect(WorkshopStepApprovalPayload.canonicalExecutionIdKey == "execution_id")
    #expect(WorkshopStepApprovalPayload.executionIdKeys.first == "execution_id")
    #expect(WorkshopStepApprovalPayload.executionIdKeys.contains("mission_id"))
}
