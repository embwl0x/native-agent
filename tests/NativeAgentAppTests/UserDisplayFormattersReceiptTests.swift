// 2026-06-07 ui-taste-sweep #83: regression harness for the receipt
// humanizer. Covers the actual problem inputs the user surfaced + the
// edge cases gpt-5.5 review pulled out (verb mis-extraction, trailing
// empty values). Keep this green when extending the parser.

import Foundation
import Testing
@testable import NativeAgentApp

@Test
func humanizeReceipt_parsesArchivedInboxReceiptFromUserReport() throws {
    // The exact example from the user's task #83 — what was rendering raw on
    // the Capabilities tab. The receipt's `name` was missing, so the
    // verb "archived" was embedded as a prefix in the detail string.
    let r = UserDisplayFormatters.humanizeReceipt(
        name: nil,
        detail: "archived: id: autonomy-inbox-digest-62396, reason: stale_duplicate, source: inbox, createdAt: 2026-05-26T01:32:52.022696+00:00, records: , checked: 716"
    )
    #expect(r.title == "Archived")
    // Subtitle should lead with the humanized reason. Timestamp tail
    // varies with current date — assert it's there but don't pin a
    // specific phrase.
    #expect(r.subtitle.hasPrefix("stale duplicate"))
    #expect(r.subtitle.contains("ago") || r.subtitle.contains("·"))
    // All 6 pairs preserved in order — including the empty `records`.
    let keys = r.rawPairs.map(\.0)
    #expect(keys == ["id", "reason", "source", "createdAt", "records", "checked"])
    let records = r.rawPairs.first(where: { $0.0 == "records" })?.1
    #expect(records == "")
}

@Test
func humanizeReceipt_doesNotMisreadFirstKeyAsVerb() throws {
    // gpt-5.5 review found this: when name is empty and detail STARTS
    // with "id: x, ...", the original code mis-extracted "id" as the
    // verb and lost the id pair entirely. The fix gates the verb
    // extraction on the rest looking like a kv dump.
    let r = UserDisplayFormatters.humanizeReceipt(
        name: nil,
        detail: "id: abc-123, reason: stale_duplicate"
    )
    // Title falls back to "Receipt" because no verb is present.
    #expect(r.title == "Receipt")
    // The id pair is NOT lost.
    #expect(r.rawPairs.contains(where: { $0.0 == "id" && $0.1 == "abc-123" }))
    #expect(r.rawPairs.contains(where: { $0.0 == "reason" && $0.1 == "stale_duplicate" }))
}

@Test
func humanizeReceipt_keepsTrailingEmptyValue() throws {
    // gpt-5.5 review found this: parseKeyValueDump used `range(of: ": ")`
    // which failed on "records:" (no trailing space after trim). The
    // fix uses `firstIndex(of: ":")` so empty values survive even at
    // payload tail.
    let r = UserDisplayFormatters.humanizeReceipt(
        name: "archived",
        detail: "checked: 716, records: "
    )
    #expect(r.title == "Archived")
    let recordsPair = r.rawPairs.first(where: { $0.0 == "records" })
    #expect(recordsPair != nil)
    #expect(recordsPair?.1 == "")
}

@Test
func humanizeReceipt_nilDetailUsesNameAsTitle() throws {
    let r = UserDisplayFormatters.humanizeReceipt(name: "completed", detail: nil)
    #expect(r.title == "Completed")
    #expect(r.subtitle == "")
    #expect(r.rawPairs.isEmpty)
}

@Test
func humanizeReceipt_nonKVDetailFallsBackToRawSubtitle() throws {
    // Free-form detail with no kv structure — must NOT drop the info.
    let r = UserDisplayFormatters.humanizeReceipt(name: "failed", detail: "all systems nominal")
    #expect(r.title == "Failed")
    #expect(r.subtitle == "all systems nominal")
    #expect(r.rawPairs.isEmpty)
}

@Test
func humanizeReceipt_snakeCaseVerbBecomesTitleCase() throws {
    let r = UserDisplayFormatters.humanizeReceipt(name: "auto_promote", detail: nil)
    #expect(r.title == "Auto Promote")
}

@Test
func humanizeReceipt_unknownDescriptiveKeyAppearsInSubtitle() throws {
    // No reason / createdAt, but source is present — should appear as
    // the subtitle fallback rather than the raw payload.
    let r = UserDisplayFormatters.humanizeReceipt(
        name: "completed",
        detail: "source: gateway_ping, target: anthropic"
    )
    #expect(r.title == "Completed")
    #expect(r.subtitle.contains("source"))
    #expect(r.subtitle.contains("gateway ping"))
}

@Test
func humanizeReceipt_isoTimestampWithFractionalSecondsResolvesToRelative() throws {
    // The exact timestamp format the daemon emits — must round-trip
    // through humanizeISOTimestamp without leaking the raw value.
    let r = UserDisplayFormatters.humanizeReceipt(
        name: "archived",
        detail: "reason: stale, createdAt: 2026-05-26T01:32:52.022696+00:00"
    )
    #expect(r.title == "Archived")
    // Subtitle should NOT contain the raw ISO string.
    #expect(!r.subtitle.contains("2026-05-26T01:32:52"))
    // Should contain some humanized form (the year or "ago" or "in").
    #expect(r.subtitle.contains("ago") || r.subtitle.contains("in "))
}
