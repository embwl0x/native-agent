import Testing
import Foundation
@testable import CognitiveSubstrate

// M9 (honesty sweep, 2026-07-09): ContinuityField.seenEventKeys was the one
// collection here with no eviction path — `evictNodes`/`enforceCapacity` bound
// the nodes, decay anchors and association weights, but the dedup set grew ~900
// entries/day for the life of the process. It is now a FIFO ring.

/// The dedup key is the event `id` when non-empty, so the ring can be exercised
/// with thousands of distinct events that all land on ONE node. Minting a fresh
/// subject per event instead would make this test quadratic in node bookkeeping
/// (~25s) while testing nothing extra.
private func makeEvent(id: String, at date: Date, subject: String = "shared-subject") -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .toolSucceeded,
        subject: CognitiveSubjectReference(type: "topic", id: subject, label: subject),
        sourceClass: .observed,
        occurredAt: date,
        summary: "event \(id)",
        importance: 0.5,
        metadata: [:]
    )
}

@Test func seenEventKeys_dedups_within_the_ring() {
    var field = ContinuityField()
    let now = Date()
    let config = CognitiveConfiguration()
    let event = makeEvent(id: "dup", at: now)

    #expect(field.ingest(event, now: now, makeUUID: { UUID() }, configuration: config) != nil)
    // Same key, immediately after: still deduplicated.
    #expect(field.ingest(event, now: now, makeUUID: { UUID() }, configuration: config) == nil)
}

@Test func seenEventKeys_is_bounded_and_evicts_oldest_first() {
    var field = ContinuityField()
    let now = Date()
    let config = CognitiveConfiguration()

    let first = makeEvent(id: "first", at: now)
    #expect(field.ingest(first, now: now, makeUUID: { UUID() }, configuration: config) != nil)

    // Push the ring well past its cap so the oldest batch is evicted.
    let overflow = ContinuityField.maximumSeenEventKeys + ContinuityField.seenEventKeyEvictionBatch + 16
    for i in 0..<overflow {
        let e = makeEvent(id: "filler-\(i)", at: now.addingTimeInterval(Double(i)))
        _ = field.ingest(e, now: now, makeUUID: { UUID() }, configuration: config)
    }

    // The oldest key aged out of the dedup ring, so the same event is accepted
    // again. Before the fix the set simply grew forever and this returned nil.
    #expect(field.ingest(first, now: now, makeUUID: { UUID() }, configuration: config) != nil)

    // And the most RECENT filler is still deduplicated — eviction is oldest-first,
    // not a wholesale clear.
    let newest = makeEvent(id: "filler-\(overflow - 1)", at: now.addingTimeInterval(Double(overflow - 1)))
    #expect(field.ingest(newest, now: now, makeUUID: { UUID() }, configuration: config) == nil)
}
