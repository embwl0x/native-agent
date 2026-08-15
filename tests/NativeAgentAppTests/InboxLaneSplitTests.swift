// W6 / G12 — "For you" vs "System".
//
// The predicate under test is the WHOLE feature: no producer changed, no card
// shape changed. So these tests pin it against the real source vocabulary read
// out of the live feed (`data/notifications/inbox.jsonl`, 2026-08-11), not
// against the enumeration in the evidence doc — the doc's list predates
// `provider_vitals` and the `memory_*` maintenance jobs.

import Foundation
import Testing
@testable import NativeAgentApp

private func laneItem(source: String, status: String = "unread") -> InboxItemRecord {
    let json = """
    {"id":"i-\(abs(source.hashValue))","created_at":"2026-08-11T00:00:00Z","source":"\(source)",
     "severity":"info","title":"t","summary":"s","actions":[],"status":"\(status)"}
    """
    return try! JSONDecoder().decode(InboxItemRecord.self, from: Data(json.utf8))
}

@Test
func systemLaneClaimsTheOperationsVocabulary() {
    // The seven the L5 evidence names.
    for source in [
        "background_loop", "disk_hygiene", "doctor", "heartbeat",
    ] {
        #expect(laneItem(source: source).isSystemLane, "\(source) should be System")
    }
    // The self-referential proactive kinds arrive wrapped — the lane test has
    // to read the KIND component, not the raw source.
    for kind in ["scheduler_health", "approval_backlog", "inbox_digest"] {
        let item = laneItem(source: "proactive_autonomy:\(kind):opp-\(kind)-abc123")
        #expect(item.isSystemLane, "proactive kind \(kind) should be System")
    }
    // Live operational sources the doc's enumeration predates.
    for source in ["provider_vitals", "memory_consolidation", "memory_repair", "memory_kind_backfill"] {
        #expect(laneItem(source: source).isSystemLane, "\(source) should be System")
    }
    // The loop-failure cards (L4-01's shape) prefix rather than match exactly.
    #expect(laneItem(source: "loop-failure:telegram_poll").isSystemLane)
}

@Test
func forYouLaneKeepsEverythingAddressedToTheHuman() {
    for source in [
        "dream_cycle",
        "rem_cycle",
        "trigger:morning_brief",
        "trigger:file_watch",
        "trigger:stuck_pattern",
        "idle_checkin",
        "agent_morning_warmup",
        "mission_complete:abc",
        "missions",
    ] {
        #expect(laneItem(source: source).isForYouLane, "\(source) should be For you")
    }
}

@Test
func aProactiveCardAboutRealWorkStaysInTheHumanLane() {
    // G5's new kind is proactive_autonomy-prefixed like the housekeeping kinds,
    // but it is about User's project. If the lane test matched on the
    // `proactive_autonomy:` prefix alone this would land in System and the
    // whole point of G5 would be lost behind a segment nobody opens.
    let item = laneItem(source: "proactive_autonomy:desk_stale:opp-desk_stale-9f10")
    #expect(item.isForYouLane)
}

@Test
func unknownSourcesDefaultToForYou() {
    // Fail toward visibility: a card wrongly in For-you is noise, a card
    // wrongly in System is invisible.
    #expect(laneItem(source: "some_future_producer").isForYouLane)
    #expect(laneItem(source: "").isForYouLane)
}

@Test
func lanesArePartitionAndTotal() {
    // No item may be in both lanes or in neither — the segmented control would
    // otherwise duplicate or lose rows.
    let sources = [
        "background_loop", "dream_cycle", "heartbeat", "trigger:morning_brief",
        "proactive_autonomy:inbox_digest:opp-x", "proactive_autonomy:desk_stale:opp-y",
        "provider_vitals", "", "unknown_thing",
    ]
    for source in sources {
        let item = laneItem(source: source)
        #expect(item.isSystemLane != item.isForYouLane, "\(source) is in both lanes or neither")
        #expect(InboxLane.forYou.matches(item) != InboxLane.system.matches(item))
    }
}

@Test
func laneMatchingIsCaseInsensitiveOnSource() {
    #expect(laneItem(source: "Background_Loop").isSystemLane)
    #expect(laneItem(source: "PROACTIVE_AUTONOMY:INBOX_DIGEST:opp-z").isSystemLane)
}
