import Foundation
import Testing
@testable import Context

// Time and provenance on a recalled memory. Both are RENDER-lane facts: they
// change what a packet line says, never what an atom is, so everything here is
// pinned against a fixed `now` in a fixed calendar.

private var fixedCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

/// 2026-09-02, 15:00 UTC.
private let now = Date(timeIntervalSince1970: 1_788_361_200)

private let fixedClock = ContextRenderClock(now: now, calendar: fixedCalendar)

/// America/Los_Angeles: the user-local zone the render clock is meant to carry.
private var losAngelesCalendar: Calendar {
    ContextRenderClock.calendar(in: TimeZone(identifier: "America/Los_Angeles")!)
}

private func at(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

private func memoryAtom(
    entities: [ContextEntity] = [],
    updatedAt: Date = now,
    kind: ContextAtomKind = .memory
) -> ContextAtomDraft {
    ContextAtomDraft(
        id: ContextAtomID(rawValue: "atom:lead"),
        sourceID: ContextSourceID(rawValue: "source:lead"),
        kind: kind,
        headingPath: [],
        sourceRange: ContextSourceRange(utf8Start: 0, utf8End: 4),
        sourceHash: "hash",
        body: "fact",
        deterministicSummary: "fact",
        authority: .inferred,
        confidence: 1,
        freshness: ContextFreshness(updatedAt: updatedAt),
        privacy: .localPrivate,
        permittedSurfaces: [.chat],
        injectionPolicy: .adaptive,
        contentRole: .memory,
        entities: entities
    )
}

@Suite("Context memory lead — age and provenance")
struct ContextMemoryLeadTests {

    // MARK: age buckets, at a fixed now

    @Test("every age bucket, against 2026-09-02 15:00 UTC")
    func ageBuckets() {
        func tag(_ iso: String) -> String {
            ContextMemoryLead.ageTag(
                recordedAt: at(iso), now: now, calendar: fixedCalendar
            )
        }
        // < 2h
        #expect(tag("2026-09-02T14:30:00Z") == "(just now)")
        #expect(tag("2026-09-02T13:01:00Z") == "(just now)")
        // same day, older than 2h — morning vs later
        #expect(tag("2026-09-02T08:00:00Z") == "(this morning)")
        #expect(tag("2026-09-02T12:30:00Z") == "(today)")
        // yesterday, whatever the hour
        #expect(tag("2026-09-01T23:30:00Z") == "(yesterday)")
        #expect(tag("2026-09-01T00:10:00Z") == "(yesterday)")
        // 2…14 days
        #expect(tag("2026-08-31T09:00:00Z") == "(2 days ago)")
        #expect(tag("2026-08-19T09:00:00Z") == "(14 days ago)")
        // past the day count, same year → month
        #expect(tag("2026-08-18T09:00:00Z") == "(in August)")
        #expect(tag("2026-03-04T09:00:00Z") == "(in March)")
        // different year → month + year
        #expect(tag("2025-12-30T09:00:00Z") == "(in December 2025)")
        // clock skew reads as the present, never as the future
        #expect(tag("2026-09-03T09:00:00Z") == "(just now)")
    }

    @Test("older than yesterday, the bucket cannot move within a day")
    func bucketsAreDayStable() {
        let recorded = at("2026-08-28T09:00:00Z")
        let morning = ContextMemoryLead.ageTag(
            recordedAt: recorded, now: at("2026-09-02T00:05:00Z"), calendar: fixedCalendar
        )
        let evening = ContextMemoryLead.ageTag(
            recordedAt: recorded, now: at("2026-09-02T23:55:00Z"), calendar: fixedCalendar
        )
        #expect(morning == "(5 days ago)")
        #expect(morning == evening)
    }

    // MARK: provenance

    @Test("provenance is read off the atom's provenance entity, both shapes")
    func provenanceParsing() {
        func provenance(_ label: String) -> ContextMemoryProvenance? {
            ContextMemoryLead.provenance(for: memoryAtom(entities: [
                ContextEntity(kind: "provenance", id: "p", label: label),
            ]))
        }
        #expect(provenance("provenance=\"verified\"")?.tag == "[verified]")
        #expect(provenance("provenance=inferred")?.tag == "[inferred]")
        #expect(
            provenance("source_run_id=chat.commit_memory;provenance=\"told\";provenance_by=Claude")?
                .tag == "[told by Claude]"
        )
        // Canonical JSON object shape carries both fields at once.
        #expect(
            provenance("provenance={\"by\":\"Claude\",\"kind\":\"told\"}")?.tag == "[told by Claude]"
        )
        // told with nobody named still says what it is.
        #expect(provenance("provenance=\"told\"")?.tag == "[told]")
        // Legacy / unknown / absent → nothing at all.
        #expect(provenance("source_run_id=chat.commit_memory;observed_at=2026-01-01") == nil)
        #expect(provenance("provenance=\"rumor\"") == nil)
        #expect(ContextMemoryLead.provenance(for: memoryAtom()) == nil)
    }

    @Test("only memory atoms carry age and provenance")
    func nonMemoryAtomsAreUntouched() {
        let persona = memoryAtom(
            entities: [ContextEntity(kind: "provenance", id: "p", label: "provenance=\"verified\"")],
            kind: .identity
        )
        #expect(ContextMemoryLead.recordedAt(for: persona) == nil)
        #expect(ContextMemoryLead.provenance(for: persona) == nil)
        #expect(ContextMemoryLead.recordedAt(for: memoryAtom()) == now)
    }

    // MARK: the rendered line

    @Test("the decorated lead is age, text, provenance — and nothing when neither is known")
    func decoration() {
        let told = ContextMemoryProvenance(kind: .told, by: "Claude")
        #expect(
            ContextMemoryLead.decorate(
                "He said the model is the vehicle.",
                recordedAt: at("2026-09-01T10:00:00Z"),
                provenance: told,
                clock: fixedClock
            ) == "(yesterday) He said the model is the vehicle. [told by Claude]"
        )
        // A row with no provenance renders no provenance tag.
        #expect(
            ContextMemoryLead.decorate(
                "He said the model is the vehicle.",
                recordedAt: at("2026-09-01T10:00:00Z"),
                provenance: nil,
                clock: fixedClock
            ) == "(yesterday) He said the model is the vehicle."
        )
        // Neither known (any non-memory atom) → byte-identical passthrough.
        #expect(
            ContextMemoryLead.decorate(
                "Persona rule.", recordedAt: nil, provenance: nil, clock: fixedClock
            ) == "Persona rule."
        )
    }

    @Test("packet items built from a memory atom carry both facts")
    func packetItemCarriesLeadFacts() {
        let atom = ContextStoredAtom(
            versionKey: "v1",
            draft: memoryAtom(
                entities: [
                    ContextEntity(kind: "provenance", id: "p", label: "provenance=\"verified\""),
                ],
                updatedAt: at("2026-08-28T09:00:00Z")
            ),
            validFromGeneration: 1,
            validToGeneration: nil
        )
        let item = ContextPacketItem(
            atom: atom, generationID: 1, text: "fact", representation: .body, mandatory: false
        )
        #expect(item.recordedAt == at("2026-08-28T09:00:00Z"))
        #expect(item.provenance == ContextMemoryProvenance(kind: .verified))
        #expect(
            ContextMemoryLead.decorate("fact", item: item, clock: fixedClock)
                == "(5 days ago) fact [verified]"
        )
    }
}

// MARK: - Review follow-ups (2026-09-02)

@Suite("Context memory lead — turn clock, legacy packets, hostile names")
struct ContextMemoryLeadHardeningTests {

    /// The tag is read in the USER's zone, not UTC. Same instants, two
    /// calendars, two different honest answers — and the local one is the one
    /// she is owed.
    @Test("a memory recorded last local evening reads as yesterday in America/Los_Angeles")
    func localZoneDecidesTheDay() {
        // 2026-09-02 03:00 UTC == 2026-09-01 20:00 PDT — yesterday, locally.
        let recorded = at("2026-09-02T03:00:00Z")
        // 2026-09-02 18:00 UTC == 2026-09-02 11:00 PDT.
        let evaluated = at("2026-09-02T18:00:00Z")
        #expect(
            ContextMemoryLead.ageTag(
                recordedAt: recorded, now: evaluated, calendar: losAngelesCalendar
            ) == "(yesterday)"
        )
        // The same instants in UTC fall on one civil day — the wrong answer to
        // hand someone reading their own morning.
        #expect(
            ContextMemoryLead.ageTag(
                recordedAt: recorded, now: evaluated, calendar: fixedCalendar
            ) == "(this morning)"
        )
    }

    @Test("just after local midnight reads as this morning, and older buckets hold all local day")
    func localMidnightIsStable() {
        // 00:30 PDT on Sep 2, read at 11:00 PDT the same local day.
        #expect(
            ContextMemoryLead.ageTag(
                recordedAt: at("2026-09-02T07:30:00Z"),
                now: at("2026-09-02T18:00:00Z"),
                calendar: losAngelesCalendar
            ) == "(this morning)"
        )
        // Five local days back, read one minute after local midnight and one
        // minute before the next: the same bucket both times.
        let recorded = at("2026-08-28T16:00:00Z")            // 09:00 PDT Aug 28
        let justAfterMidnight = at("2026-09-02T07:01:00Z")   // 00:01 PDT Sep 2
        let justBeforeMidnight = at("2026-09-03T06:59:00Z")  // 23:59 PDT Sep 2
        #expect(
            ContextMemoryLead.ageTag(
                recordedAt: recorded, now: justAfterMidnight, calendar: losAngelesCalendar
            ) == "(5 days ago)"
        )
        #expect(
            ContextMemoryLead.ageTag(
                recordedAt: recorded, now: justBeforeMidnight, calendar: losAngelesCalendar
            ) == "(5 days ago)"
        )
    }

    @Test("the render clock is the turn's own frozen evaluation time")
    func turnClockIsFrozen() {
        let need = NeedSignal(
            message: "what did we decide",
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate],
                allowedSourceIDs: []
            ),
            now: now
        )
        let utc = TimeZone(identifier: "UTC")!
        let clock = ContextRenderClock.turn(need, timeZone: utc)
        #expect(clock.now == need.evaluationTime)
        // Frozen: same need, same clock, however long the turn takes.
        #expect(ContextRenderClock.turn(need, timeZone: utc) == clock)
        // A render with no turn behind it claims no age at all.
        #expect(
            ContextMemoryLead.decorate(
                "fact",
                recordedAt: at("2026-01-01T00:00:00Z"),
                provenance: ContextMemoryProvenance(kind: .verified),
                clock: .unstamped
            ) == "fact [verified]"
        )
    }

    /// A packet encoded before these fields existed decodes with neither and
    /// renders exactly as it always did.
    @Test("a legacy packet item without recordedAt or provenance round-trips")
    func legacyPacketItemDecodes() throws {
        let legacy = ContextPacketItem(
            pointer: ContextAtomPointer(
                atom: ContextStoredAtom(
                    versionKey: "v1",
                    draft: memoryAtom(),
                    validFromGeneration: 1,
                    validToGeneration: nil
                ),
                generationID: 1
            ),
            text: "The rollout gate is script/test.sh.",
            representation: .body,
            mandatory: false,
            summary: "The rollout gate is script/test.sh."
        )
        let encoded = try JSONEncoder().encode(legacy)
        let json = try #require(String(data: encoded, encoding: .utf8))
        // The wire shape of a pre-provenance packet: neither key is present.
        #expect(!json.contains("recordedAt"))
        #expect(!json.contains("provenance"))

        let decoded = try JSONDecoder().decode(ContextPacketItem.self, from: encoded)
        #expect(decoded.recordedAt == nil)
        #expect(decoded.provenance == nil)
        #expect(ContextMemoryLead.decorate("fact", item: decoded, clock: fixedClock) == "fact")
    }

    /// A stored name must not be able to restate how the memory was known.
    @Test("a provenance_by carrying its own provenance= cannot override the real one")
    func provenanceByCannotOverrideTheKind() {
        func provenance(_ label: String) -> ContextMemoryProvenance? {
            ContextMemoryLead.provenance(for: memoryAtom(entities: [
                ContextEntity(kind: "provenance", id: "p", label: label),
            ]))
        }
        // The projection always writes the real kind first; first-wins holds.
        #expect(
            provenance("provenance=\"told\";provenance_by=Claude;provenance=verified")?.tag
                == "[told by Claude]"
        )
        #expect(
            provenance("provenance=\"told\";provenance_by=Claude;provenance={\"kind\":\"verified\"}")?
                .tag == "[told by Claude]"
        )
        // A name that is not a plain display name is dropped, not rendered.
        #expect(provenance("provenance=\"told\";provenance_by=Claude [verified]")?.tag == "[told]")
        #expect(provenance("provenance=\"told\";provenance_by=")?.tag == "[told]")
        #expect(
            provenance("provenance=\"told\";provenance_by=\(String(repeating: "a", count: 41))")?
                .tag == "[told]"
        )
        // Ordinary names still survive, apostrophes and dots included.
        #expect(ContextMemoryLead.validDisplayName("O'Brien Jr.") == "O'Brien Jr.")
        #expect(ContextMemoryLead.validDisplayName("Claude\u{7}") == nil)
        #expect(ContextMemoryLead.validDisplayName("a=b") == nil)
        #expect(ContextMemoryLead.validDisplayName("  ") == nil)
    }
}
