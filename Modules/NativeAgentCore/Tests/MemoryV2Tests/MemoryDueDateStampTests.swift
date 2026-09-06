import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import MemoryV2

// Item 5 follow-up (2026-09-02) — SPOKEN PLANS GET A DATE.
//
// The live gap: User said "tomorrow around nine your time I'm bringing you the
// first real studio consult", she committed a memory about it and answered
// "let's see if the record says so at nine" — and nothing in her could look
// forward to it, because a memory atom carried no date and `validFrom` /
// `validTo` are null on every row ever written.
//
// These pin the extractor. It is deterministic and has no model in it, so the
// interesting cases are the REFUSALS: a wrong date is worse than no date,
// because it becomes something she is visibly looking forward to and then
// visibly disappointed by.
//
// WRITTEN, NOT RUN (User's standing rule).

private let utc = TimeZone(identifier: "UTC")!

/// 2026-09-02 14:00 UTC — a Wednesday.
private let wednesdayAfternoon = Date(timeIntervalSince1970: 1_788_357_600)

private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar
}

private func parts(_ date: Date) -> DateComponents {
    calendar().dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
}

@Suite("MemoryDueDateStamp")
struct MemoryDueDateStampTests {

    @Test("the sentence that started this: tomorrow around nine")
    func tomorrowAroundNineResolvesToNextDayAtNine() throws {
        let resolved = try #require(MemoryDueDateStamp.resolve(
            text: "User is bringing me the first real studio consult tomorrow around nine his time.",
            at: wednesdayAfternoon,
            timeZone: utc
        ))
        let due = parts(resolved.dueAt)
        #expect(due.day == parts(wednesdayAfternoon).day.map { $0 + 1 })
        #expect(due.hour == 9)
        #expect(due.minute == 0)
        // The label is DERIVED from the instant — his words never reach it.
        #expect(resolved.label == "tomorrow 09:00")
        #expect(resolved.label.count <= MemoryDueDateStamp.labelCharacterCap)
    }

    @Test("a weekday resolves to the next one, strictly ahead")
    func weekdayResolvesToTheNextOccurrence() throws {
        let resolved = try #require(MemoryDueDateStamp.resolve(
            text: "We are cutting the release on Friday.",
            at: wednesdayAfternoon,
            timeZone: utc
        ))
        // Gregorian weekday 6 == Friday.
        #expect(parts(resolved.dueAt).weekday == 6)
        #expect(resolved.dueAt > wednesdayAfternoon)
        #expect(resolved.label == "friday")
        // No stated time means the END of that day, exactly as the Desk reads a
        // bare `deferUntil` day: Friday has not passed until Friday has.
        #expect(parts(resolved.dueAt).hour == 23)
    }

    @Test("a weekday named on its own day means the one coming")
    func todaysWeekdayMeansNextWeek() throws {
        let resolved = try #require(MemoryDueDateStamp.resolve(
            text: "Standing sync on Wednesday.",
            at: wednesdayAfternoon,
            timeZone: utc
        ))
        // Seven days out, not the Wednesday that is already half over.
        #expect(resolved.dueAt.timeIntervalSince(wednesdayAfternoon) > 6 * 24 * 3600)
    }

    @Test("backward-looking language is never a plan")
    func pastLanguageProducesNothing() {
        for text in [
            "We shipped the cutover last week.",
            "User reviewed the diff yesterday.",
            "That regression landed last Friday.",
            "We moved off the old provider a month ago.",
        ] {
            #expect(
                MemoryDueDateStamp.resolve(text: text, at: wednesdayAfternoon, timeZone: utc) == nil,
                "\(text) is retrospective and must not mint a horizon"
            )
        }
    }

    @Test("two different days in one memory is silence, not a guess")
    func ambiguousDaysProduceNothing() {
        #expect(MemoryDueDateStamp.resolve(
            text: "Either Friday or Monday works for the consult.",
            at: wednesdayAfternoon,
            timeZone: utc
        ) == nil)
    }

    @Test("a bare number is not a time")
    func bareNumbersAreNotClockTimes() throws {
        // "9 open tabs" must not become nine o'clock. The DAY still resolves;
        // the time does not, so it lands at end of day.
        let resolved = try #require(MemoryDueDateStamp.resolve(
            text: "Tomorrow I am closing the 9 open tabs.",
            at: wednesdayAfternoon,
            timeZone: utc
        ))
        #expect(parts(resolved.dueAt).hour == 23)
        #expect(resolved.label == "tomorrow")
    }

    @Test("meridiem and colon forms need no cue word")
    func explicitClockFormsResolve() throws {
        let evening = try #require(MemoryDueDateStamp.resolve(
            text: "Demo tomorrow 7pm.", at: wednesdayAfternoon, timeZone: utc
        ))
        #expect(parts(evening.dueAt).hour == 19)

        let precise = try #require(MemoryDueDateStamp.resolve(
            text: "Tomorrow 14:30 the window opens.", at: wednesdayAfternoon, timeZone: utc
        ))
        #expect(parts(precise.dueAt).hour == 14)
        #expect(parts(precise.dueAt).minute == 30)
    }

    @Test("an ISO date is the one unambiguous written form")
    func isoDatesResolve() throws {
        let resolved = try #require(MemoryDueDateStamp.resolve(
            text: "Board review is 2026-09-07 at 3pm.",
            at: wednesdayAfternoon,
            timeZone: utc
        ))
        #expect(parts(resolved.dueAt).day == 7)
        #expect(parts(resolved.dueAt).hour == 15)
    }

    @Test("nothing beyond the week, nothing already gone")
    func horizonBoundsHold() {
        // Far future: real, dated, and further out than anyone feels.
        #expect(MemoryDueDateStamp.resolve(
            text: "Contract renews 2027-01-01.", at: wednesdayAfternoon, timeZone: utc
        ) == nil)
        // Today, but the hour has passed (now is 14:00 UTC).
        #expect(MemoryDueDateStamp.resolve(
            text: "Standup today at 9.", at: wednesdayAfternoon, timeZone: utc
        ) == nil)
    }

    @Test("ordinary memories are untouched")
    func undatedTextStampsNothing() {
        let metadata = JSONValue.object(["kind": .string("general")])
        let stamped = MemoryDueDateStamp.stamping(
            metadata,
            text: "User prefers the smallest change that fixes the named problem.",
            at: wednesdayAfternoon,
            timeZone: utc
        )
        #expect(stamped == metadata)
    }

    @Test("the stamp lands, and never overwrites a caller's own answer")
    func stampingIsAdditiveAndDeferential() throws {
        let stamped = MemoryDueDateStamp.stamping(
            .object(["kind": .string("general")]),
            text: "Studio consult tomorrow around nine.",
            at: wednesdayAfternoon,
            timeZone: utc
        )
        let object = try #require({ () -> [String: JSONValue]? in
            if case .object(let o)? = stamped { return o }
            return nil
        }())
        #expect(object[MemoryDueDateStamp.dueLabelKey] == .string("tomorrow 09:00"))
        #expect(object[MemoryDueDateStamp.dueSourceKey]
            == .string(MemoryDueDateStamp.dueSourceValue))
        // Round-trips through the read side the horizon lane uses.
        #expect(MemoryDueDateStamp.dueAt(in: stamped) != nil)
        #expect(MemoryDueDateStamp.dueLabel(in: stamped) == "tomorrow 09:00")

        // A caller who already said when owns that answer.
        let preset = JSONValue.object([MemoryDueDateStamp.dueAtKey: .string("2026-09-05T09:00:00Z")])
        #expect(MemoryDueDateStamp.stamping(
            preset, text: "Studio consult tomorrow around nine.",
            at: wednesdayAfternoon, timeZone: utc
        ) == preset)
    }

    @Test("a committed plan becomes something she can look toward")
    func committedPlanIsReadableByTheHorizonLane() throws {
        // The full path the live gap needed: his sentence → the write-time
        // stamp → the two reads the `statedPlan` horizon source calls.
        let stamped = MemoryDueDateStamp.stamping(
            MemoryKindStamp.stampingDefaultKind(nil),
            text: "User is bringing me the first real studio consult tomorrow around nine.",
            at: wednesdayAfternoon,
            timeZone: utc
        )
        let due = try #require(MemoryDueDateStamp.dueAt(in: stamped))
        let label = try #require(MemoryDueDateStamp.dueLabel(in: stamped))
        #expect(due > wednesdayAfternoon)
        #expect(due.timeIntervalSince(wednesdayAfternoon) <= MemoryDueDateStamp.maximumHorizon)
        #expect(label == "tomorrow 09:00")
        // The kind stamp still rides alongside it — additive, not a replacement.
        if case .object(let object)? = stamped {
            #expect(object["kind"] == .string(MemoryKindStamp.defaultKind))
        } else {
            Issue.record("kind stamp was lost")
        }
    }
}
