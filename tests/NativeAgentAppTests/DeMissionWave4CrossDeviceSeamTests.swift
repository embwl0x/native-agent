// Wave 4 (de-mission phase 2) — cross-device READ-BOTH seam tests.
//
// Wave 4 is PHASE A: decoders widen, writers do NOT move. A 0.3.7 iOS install
// must keep decoding new Mac snapshots byte-for-byte and vice versa, so every
// test below comes in the same four corners:
//
//   (a) a live-shaped OLD-key fixture still decodes,
//   (b) a NEW-key fixture decodes,
//   (c) ENCODE still emits the OLD key, byte-compatibly — this wave is
//       wire-INVISIBLE,
//   (d) negative control: neither key present behaves exactly as before.
//
// Corner (c) is the load-bearing one. If a later edit flips a writer, these
// fail — which is the point: the writer flip is phase B and is gated on the
// iOS floor, not on this wave.

import Foundation
import Testing

import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import WorkshopExecution

@testable import NativeAgentApp

private let wave4Decoder = JSONDecoder()
private let wave4Encoder = JSONEncoder()

private func wave4ObjectKeys(_ data: Data) throws -> Set<String> {
    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return []
    }
    return Set(dict.keys)
}

// MARK: - 4a. TrustPolicy missionPolicy / workshopPolicy (Mac model)

/// Live shape of `trust/policy.json` as every writer still emits it.
private let legacyTrustPolicyJSON = """
{"permissionLevel":"balanced","autonomyDefault":"supervised",\
"missionPolicy":{"enabled":true,"showTimeline":true},\
"developerMode":false,"enableAutonomy":false}
"""

/// What a future (phase B) writer would emit. Accepted now, emitted by nobody.
private let futureTrustPolicyJSON = """
{"permissionLevel":"balanced","autonomyDefault":"supervised",\
"workshopPolicy":{"enabled":true,"showTimeline":true},\
"developerMode":false,"enableAutonomy":false}
"""

@Test("4a mac: legacy missionPolicy still decodes")
func wave4MacTrustPolicyDecodesLegacyKey() throws {
    let policy = try wave4Decoder.decode(TrustPolicy.self, from: Data(legacyTrustPolicyJSON.utf8))
    #expect(policy.workshopPolicy?.enabled == true)
    #expect(policy.workshopPolicy?.showTimeline == true)
}

@Test("4a mac: future workshopPolicy decodes")
func wave4MacTrustPolicyDecodesFutureKey() throws {
    let policy = try wave4Decoder.decode(TrustPolicy.self, from: Data(futureTrustPolicyJSON.utf8))
    #expect(policy.workshopPolicy?.enabled == true)
    #expect(policy.workshopPolicy?.showTimeline == true)
}

@Test("4a mac: future key wins when BOTH are present")
func wave4MacTrustPolicyPrefersFutureKey() throws {
    let both = """
    {"permissionLevel":"balanced",\
    "workshopPolicy":{"enabled":true},"missionPolicy":{"enabled":false}}
    """
    let policy = try wave4Decoder.decode(TrustPolicy.self, from: Data(both.utf8))
    #expect(policy.workshopPolicy?.enabled == true)
}

@Test("4a mac: ENCODE still emits missionPolicy — wave 4 is wire-invisible")
func wave4MacTrustPolicyEncodesLegacyKeyOnly() throws {
    // Decoded from EITHER spelling, the encoder must emit the old one. This is
    // what keeps a 0.3.7 iOS install decoding Mac snapshots byte-for-byte.
    for fixture in [legacyTrustPolicyJSON, futureTrustPolicyJSON] {
        let policy = try wave4Decoder.decode(TrustPolicy.self, from: Data(fixture.utf8))
        let keys = try wave4ObjectKeys(try wave4Encoder.encode(policy))
        #expect(keys.contains("missionPolicy"))
        #expect(!keys.contains("workshopPolicy"))
    }
}

@Test("4a mac: negative control — neither key decodes to nil, no crash")
func wave4MacTrustPolicyMissingBothKeysIsNil() throws {
    let neither = #"{"permissionLevel":"balanced","autonomyDefault":"supervised"}"#
    let policy = try wave4Decoder.decode(TrustPolicy.self, from: Data(neither.utf8))
    #expect(policy.workshopPolicy == nil)
    // ...and a nil block encodes to NO key at all, not to an empty legacy one.
    let keys = try wave4ObjectKeys(try wave4Encoder.encode(policy))
    #expect(!keys.contains("missionPolicy"))
    #expect(!keys.contains("workshopPolicy"))
}

// MARK: - 4a (dict lane). Trust policy plumbing — merge + gate

@Test("4a gate: workshopPolicyAllows reads BOTH spellings")
func wave4WorkshopPolicyGateReadsBothKeys() {
    // Old spelling — unchanged behavior, the case every live install hits.
    #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
        "missionPolicy": .object(["enabled": .bool(false)]),
    ]) == false)
    #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
        "missionPolicy": .object(["enabled": .bool(true)]),
    ]) == true)

    // New spelling — must DENY too. Before the widening this read as
    // "block absent -> merged default enabled=true -> allow", i.e. a fail-OPEN
    // on a policy that explicitly turned Workshop execution off.
    #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
        "workshopPolicy": .object(["enabled": .bool(false)]),
    ]) == false)

    // Malformed-under-either-spelling still denies (daemon parity).
    #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
        "workshopPolicy": .string("broken"),
    ]) == false)

    // Negative control: absent under BOTH spellings still ALLOWS (merged
    // default enabled=true) exactly as it did before this wave.
    #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
        "permissionLevel": .string("balanced"),
    ]) == true)
}

@Test("4a writers: every trust-policy writer still emits the OLD key")
func wave4TrustPolicyWritersUnchanged() {
    // A grep-proof, not a restatement: the defaults writer is the shape every
    // fresh install lands on disk, and it must still be spelled the old way.
    #expect(WorkshopPolicyBlockVocabulary.wireKey == "missionPolicy")
    #expect(WorkshopPolicyBlockVocabulary.futureKey == "workshopPolicy")
    #expect(WorkshopPolicyBlockVocabulary.bothSpellings.first == "workshopPolicy")
}

// MARK: - 4b. InboxItemRecord related_mission_id / related_execution_id

/// Live shape of one `notifications/inbox.jsonl` card / iCloud snapshot row.
private let legacyInboxCardJSON = """
{"id":"card-1","created_at":"2026-07-11T04:00:00Z","source":"execution_complete:wsx-42",\
"severity":"actionable","title":"Workshop execution finished","summary":"3 steps",\
"detail":null,"related_mission_id":"wsx-42","related_approval_id":null,\
"related_paths":null,"related_groups":null,"actions":[],"status":"unread","read_at":null}
"""

private let futureInboxCardJSON = """
{"id":"card-1","created_at":"2026-07-11T04:00:00Z","source":"execution_complete:wsx-42",\
"severity":"actionable","title":"Workshop execution finished","summary":"3 steps",\
"detail":null,"related_execution_id":"wsx-42","related_approval_id":null,\
"related_paths":null,"related_groups":null,"actions":[],"status":"unread","read_at":null}
"""

@Test("4b mac: legacy related_mission_id card still decodes")
func wave4MacInboxDecodesLegacyKey() throws {
    let card = try wave4Decoder.decode(InboxItemRecord.self, from: Data(legacyInboxCardJSON.utf8))
    #expect(card.relatedWorkshopExecutionId == "wsx-42")
}

@Test("4b mac: future related_execution_id card decodes")
func wave4MacInboxDecodesFutureKey() throws {
    let card = try wave4Decoder.decode(InboxItemRecord.self, from: Data(futureInboxCardJSON.utf8))
    #expect(card.relatedWorkshopExecutionId == "wsx-42")
}

@Test("4b mac: future key wins when BOTH are present")
func wave4MacInboxPrefersFutureKey() throws {
    let both = """
    {"id":"card-2","created_at":"c","source":"s","severity":"info","title":"t",\
    "summary":"s","actions":[],"status":"unread",\
    "related_execution_id":"new-id","related_mission_id":"old-id"}
    """
    let card = try wave4Decoder.decode(InboxItemRecord.self, from: Data(both.utf8))
    #expect(card.relatedWorkshopExecutionId == "new-id")
}

@Test("4b mac: ENCODE still emits related_mission_id — wave 4 is wire-invisible")
func wave4MacInboxEncodesLegacyKeyOnly() throws {
    for fixture in [legacyInboxCardJSON, futureInboxCardJSON] {
        let card = try wave4Decoder.decode(InboxItemRecord.self, from: Data(fixture.utf8))
        let keys = try wave4ObjectKeys(try wave4Encoder.encode(card))
        #expect(keys.contains("related_mission_id"))
        #expect(!keys.contains("related_execution_id"))
    }
}

@Test("4b mac: negative control — neither key decodes to nil, encodes to no key")
func wave4MacInboxMissingBothKeysIsNil() throws {
    let neither = """
    {"id":"card-3","created_at":"c","source":"s","severity":"info","title":"t",\
    "summary":"s","actions":[],"status":"unread"}
    """
    let card = try wave4Decoder.decode(InboxItemRecord.self, from: Data(neither.utf8))
    #expect(card.relatedWorkshopExecutionId == nil)
    let keys = try wave4ObjectKeys(try wave4Encoder.encode(card))
    #expect(!keys.contains("related_mission_id"))
    #expect(!keys.contains("related_execution_id"))
}

// MARK: - 4c. InboxAction payload missionId / executionId (iOS -> Mac)

/// Live shape of the approve/reject payload a 0.3.7 iOS install sends. RAW
/// string keys on both ends — no Codable, so the resolver IS the seam.
private let legacyActionPayload: [String: String] = [
    "missionId": "wsx-42",
    "stepId": "step-3",
]

private let futureActionPayload: [String: String] = [
    "executionId": "wsx-42",
    "stepId": "step-3",
]

@Test("4c: legacy missionId payload still resolves (every 0.3.7 phone sends this)")
func wave4ActionPayloadResolvesLegacyKey() {
    #expect(InboxActionExecutionIdVocabulary.executionId(legacyActionPayload) == "wsx-42")
}

@Test("4c: future executionId payload resolves")
func wave4ActionPayloadResolvesFutureKey() {
    #expect(InboxActionExecutionIdVocabulary.executionId(futureActionPayload) == "wsx-42")
}

@Test("4c: future key wins when a payload carries BOTH")
func wave4ActionPayloadPrefersFutureKey() {
    let both = ["executionId": "new-id", "missionId": "old-id", "stepId": "s"]
    #expect(InboxActionExecutionIdVocabulary.executionId(both) == "new-id")
}

@Test("4c: an empty future value falls THROUGH to the legacy one")
func wave4ActionPayloadEmptyFutureFallsThrough() {
    // An empty string must not shadow a usable legacy id — that would be a
    // silently dead approve/reject from the phone.
    let emptyFuture = ["executionId": "", "missionId": "wsx-9", "stepId": "s"]
    #expect(InboxActionExecutionIdVocabulary.executionId(emptyFuture) == "wsx-9")
}

@Test("4c: negative control — neither key resolves to nil (router rejects it)")
func wave4ActionPayloadMissingBothKeysIsNil() {
    // The router turns nil into "" and then fails the missing_real_step_id
    // guard, which is exactly the pre-wave behavior for a payload with no id.
    let neither = ["stepId": "step-3"]
    #expect(InboxActionExecutionIdVocabulary.executionId(neither) == nil)
    let empty = ["executionId": "", "missionId": "", "stepId": "s"]
    #expect(InboxActionExecutionIdVocabulary.executionId(empty) == nil)
}

@Test("4c: the Mac response and the iOS writer still emit missionId")
func wave4ActionPayloadWriterKeyUnchanged() {
    #expect(InboxActionExecutionIdVocabulary.wireKey == "missionId")
    #expect(InboxActionExecutionIdVocabulary.futureKey == "executionId")
}
