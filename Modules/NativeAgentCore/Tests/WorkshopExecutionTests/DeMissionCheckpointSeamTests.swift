// P2-2 de-mission — two-vocabulary seam tests for the Mac-local checkpoint and
// escalation logs.
//
// This bug class dies SILENTLY: flip a writer to a new key, leave a reader
// pinned to the old one, and nothing throws — the field just decodes as absent
// forever. These tests pin all four corners of the seam per type:
//   (a) a LIVE-SHAPED old-key fixture still decodes,
//   (b) a new-key fixture decodes,
//   (c) decode-old -> encode emits ONLY the new key (the writer really flipped),
//   (d) neither key behaves as it did before the flip (throws, not crashes).
//
// Fixtures are hand-written JSON, NOT round-tripped from the encoder — a
// fixture minted by the same encoder under test would agree with itself no
// matter which key it used, which is exactly the tautology that lets this class
// ship.

import Foundation
import Testing

@testable import WorkshopExecution

private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func objectKeys(_ data: Data) throws -> Set<String> {
    let any = try JSONSerialization.jsonObject(with: data)
    guard let dict = any as? [String: Any] else { return [] }
    return Set(dict.keys)
}

// MARK: - WorkshopCheckpoint

/// Live shape of a checkpoints.jsonl row written by a 0.3.x binary.
private let legacyCheckpointJSON = """
{"id":"cp-1","missionId":"wsx-42","ts":"2026-07-11T04:00:00Z","phase":"investigating",\
"progress":0.25,"summary":"read the failing test","detail":"stack trace attached",\
"nextStep":"patch the decoder","blockingQuestion":null}
"""

private let canonicalCheckpointJSON = """
{"id":"cp-1","executionId":"wsx-42","ts":"2026-07-11T04:00:00Z","phase":"investigating",\
"progress":0.25,"summary":"read the failing test","detail":"stack trace attached",\
"nextStep":"patch the decoder"}
"""

@Test("checkpoint: legacy missionId row still decodes")
func checkpointDecodesLegacyKey() throws {
    let cp = try decoder.decode(WorkshopCheckpoint.self, from: Data(legacyCheckpointJSON.utf8))
    #expect(cp.executionId == "wsx-42")
    #expect(cp.id == "cp-1")
    #expect(cp.phase == "investigating")
    #expect(cp.progress == 0.25)
}

@Test("checkpoint: canonical executionId row decodes")
func checkpointDecodesCanonicalKey() throws {
    let cp = try decoder.decode(WorkshopCheckpoint.self, from: Data(canonicalCheckpointJSON.utf8))
    #expect(cp.executionId == "wsx-42")
    #expect(cp.nextStep == "patch the decoder")
}

@Test("checkpoint: canonical wins when a row carries BOTH keys")
func checkpointPrefersCanonicalOverLegacy() throws {
    let both = """
    {"id":"cp-2","executionId":"new-id","missionId":"old-id","ts":"t","phase":"p","summary":"s"}
    """
    let cp = try decoder.decode(WorkshopCheckpoint.self, from: Data(both.utf8))
    #expect(cp.executionId == "new-id")
}

@Test("checkpoint: decode legacy -> encode emits ONLY executionId")
func checkpointRoundTripDropsLegacyKey() throws {
    let cp = try decoder.decode(WorkshopCheckpoint.self, from: Data(legacyCheckpointJSON.utf8))
    let keys = try objectKeys(try encoder.encode(cp))
    #expect(keys.contains("executionId"))
    #expect(!keys.contains("missionId"))
}

@Test("checkpoint: neither key throws, as a missing required field always did")
func checkpointMissingBothKeysThrows() {
    let neither = """
    {"id":"cp-3","ts":"t","phase":"p","summary":"s"}
    """
    #expect(throws: DecodingError.self) {
        _ = try decoder.decode(WorkshopCheckpoint.self, from: Data(neither.utf8))
    }
}

// MARK: - WorkshopEscalation
//
// The nested checkpoint carries the legacy key too — a real 0.3.x escalation
// row is legacy all the way down, so the nested decoder must fall back as well.

private let legacyEscalationJSON = """
{"id":"esc-1","missionId":"wsx-42","ts":"2026-07-11T04:05:00Z","reason":"user_input_required",\
"question":"which branch should I target?",\
"checkpoint":{"id":"cp-1","missionId":"wsx-42","ts":"2026-07-11T04:00:00Z","phase":"blocked",\
"summary":"waiting on User"}}
"""

@Test("escalation: legacy row decodes, including the NESTED checkpoint")
func escalationDecodesLegacyKeyIncludingNested() throws {
    let esc = try decoder.decode(WorkshopEscalation.self, from: Data(legacyEscalationJSON.utf8))
    #expect(esc.executionId == "wsx-42")
    #expect(esc.reason == .userInputRequired)
    // The nested checkpoint is the half a naive fix forgets.
    #expect(esc.checkpoint.executionId == "wsx-42")
    #expect(esc.checkpoint.phase == "blocked")
}

@Test("escalation: canonical row decodes")
func escalationDecodesCanonicalKey() throws {
    let canonical = """
    {"id":"esc-2","executionId":"wsx-7","ts":"t","reason":"budget_exceeded","question":"q",\
    "checkpoint":{"id":"cp-9","executionId":"wsx-7","ts":"t","phase":"p","summary":"s"}}
    """
    let esc = try decoder.decode(WorkshopEscalation.self, from: Data(canonical.utf8))
    #expect(esc.executionId == "wsx-7")
    #expect(esc.checkpoint.executionId == "wsx-7")
}

@Test("escalation: decode legacy -> encode emits ONLY executionId, nested too")
func escalationRoundTripDropsLegacyKey() throws {
    let esc = try decoder.decode(WorkshopEscalation.self, from: Data(legacyEscalationJSON.utf8))
    let data = try encoder.encode(esc)
    let keys = try objectKeys(data)
    #expect(keys.contains("executionId"))
    #expect(!keys.contains("missionId"))

    let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let nested = try #require(dict["checkpoint"] as? [String: Any])
    #expect(nested["executionId"] as? String == "wsx-42")
    #expect(nested["missionId"] == nil)

    // Whole-payload guard: the legacy spelling must not survive ANYWHERE in the
    // encoded bytes, nested or otherwise.
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("missionId"))
}

@Test("escalation: neither key throws, as a missing required field always did")
func escalationMissingBothKeysThrows() {
    let neither = """
    {"id":"esc-3","ts":"t","reason":"budget_exceeded","question":"q",\
    "checkpoint":{"id":"cp-9","executionId":"wsx-7","ts":"t","phase":"p","summary":"s"}}
    """
    #expect(throws: DecodingError.self) {
        _ = try decoder.decode(WorkshopEscalation.self, from: Data(neither.utf8))
    }
}
