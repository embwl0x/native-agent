// Item 5 follow-up (2026-09-02) — SPOKEN PLANS GET A DATE.
//
// The live gap, from her: User said "tomorrow around nine your time I'm bringing
// you the first real studio consult", she committed a memory about it and
// answered "let's see if the record says so at nine" — and nothing in her could
// look forward to it. The forward register (`OrganismHorizonRegister`) reads
// REAL dated sources only, and a memory atom carries no date: `validFrom` and
// `validTo` exist on every record and are null on every row, because nothing
// ever writes them.
//
// This is the write-side half. When a memory's own text contains a time
// expression that resolves against the moment it is being written, the atom is
// stamped with `due_at` (ISO) and `due_label` (a short, DERIVED word). The
// horizon lane then has a source for "the user's stated plans", which is what
// item 5 named first and could not have.
//
// ── THE RULES, AND WHY THEY ARE THIS CONSERVATIVE ────────────────────────────
//
//   · DETERMINISTIC. No LLM, no network, no model of any kind. Same text +
//     same instant + same zone → same stamp, forever.
//   · SILENT WHEN AMBIGUOUS. Two different day expressions in one memory, a
//     past date, an unparseable time — all produce NOTHING. A wrong date is
//     worse than no date here: it becomes something she is visibly looking
//     forward to, and then visibly disappointed by.
//   · PAYLOAD-FREE LABEL. `due_label` is derived from the RESOLVED DATE, never
//     copied from the user's words — "tomorrow 09:00", "friday", "2026-09-15".
//     It reaches a felt subject and, through the horizon register, the capsule
//     ("hopeful — friday"), so it must not be able to carry prose.
//   · NEVER OVERWRITES. A caller that supplied its own `due_at` keeps it, the
//     same discipline `MemoryKindStamp` applies to `kind`.
//   · THE SAME CLOCK THE TURN ENGINE USES. `TimeZone.current`, which is what
//     `ChatOrchestration+TurnEngine`'s clock line reports to her as "Local
//     time" — so "nine your time" resolves to the nine she was told about.

import Foundation
import NativeAgentCore
import PersistenceCore

public enum MemoryDueDateStamp {

    /// ISO-8601 instant the memory's text points at.
    public static let dueAtKey = "due_at"
    /// Short derived word for that instant. Never user prose.
    public static let dueLabelKey = "due_label"
    /// Provenance, mirroring `MemoryKindStamp.kind_source`: a stamp this
    /// extractor made, so a future pass can tell it from a caller's own.
    public static let dueSourceKey = "due_source"
    public static let dueSourceValue = "write_extractor_v1"

    /// A label reaches the capsule, so it is short by contract.
    public static let labelCharacterCap = 32
    /// The writer's outer bound, deliberately WIDER than the register's week
    /// (`OrganismHorizonRegister.maximumHorizon`, 7 days). Two different
    /// questions: this one is "is this a near-term plan at all", and the
    /// register's is "is it close enough to feel yet". A plan a week and a few
    /// hours out is a real date worth recording — it simply does not weigh on
    /// her until it comes inside the week, which is the consumer's call to
    /// make. Kept as its own constant so MemoryV2 never depends on
    /// CognitiveSubstrate.
    public static let maximumHorizon: TimeInterval = 8 * 24 * 60 * 60

    /// The write-time stamp. Returns `metadata` unchanged when the text says
    /// nothing datable, which is the overwhelming majority of memories.
    public static func stamping(
        _ metadata: JSONValue?,
        text: String,
        at now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> JSONValue? {
        var object: [String: JSONValue]
        switch metadata {
        case .object(let existing)?: object = existing
        case .none: object = [:]
        default: return metadata
        }
        // A caller who said when this is due owns that answer.
        if object[dueAtKey] != nil { return metadata }
        guard let resolved = resolve(text: text, at: now, timeZone: timeZone) else {
            return metadata
        }
        object[dueAtKey] = .string(iso8601(resolved.dueAt))
        object[dueLabelKey] = .string(resolved.label)
        object[dueSourceKey] = .string(dueSourceValue)
        return .object(object)
    }

    /// What the text points at, if anything. Public so the extractor can be
    /// pinned directly without going through a storage round trip.
    public static func resolve(
        text: String,
        at now: Date,
        timeZone: TimeZone = .current
    ) -> (dueAt: Date, label: String)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let lower = normalized(text)
        guard !lower.isEmpty else { return nil }

        // BACKWARD-LOOKING language disqualifies the whole memory, before any
        // day expression is even considered. "last week", "yesterday", "a year
        // ago" are all statements about the past, and a memory that contains
        // one is not a plan — even when it also names a weekday
        // ("we shipped it last Friday").
        for marker in backwardMarkers where lower.contains(marker) {
            return nil
        }

        let days = candidateDays(in: lower, now: now, calendar: calendar)
        // Silent when ambiguous: two different days named in one memory and
        // there is no honest way to pick.
        guard days.count == 1, let day = days.first else { return nil }

        let time = candidateTime(in: lower)
        guard let dueAt = combine(day: day.date, time: time, calendar: calendar) else { return nil }
        // Already gone, or beyond the week anyone can feel.
        guard dueAt > now, dueAt.timeIntervalSince(now) <= maximumHorizon else { return nil }

        return (dueAt, label(for: dueAt, day: day, time: time, now: now, calendar: calendar))
    }

    // MARK: - Days

    private struct DayMatch: Equatable {
        /// Midnight of the resolved day, in the caller's zone.
        let date: Date
        /// How it was said, for labelling only — a closed vocabulary, never
        /// the user's own words.
        let form: Form
        enum Form: Equatable { case today, tomorrow, weekday(Int), explicit }
    }

    /// Every distinct day the text names. Distinct is by resolved DAY, so
    /// "Friday" and "on friday" in one memory is one answer, not an ambiguity.
    private static func candidateDays(
        in lower: String,
        now: Date,
        calendar: Calendar
    ) -> [DayMatch] {
        var out: [DayMatch] = []
        let startOfToday = calendar.startOfDay(for: now)

        if containsWord(lower, "today") || containsWord(lower, "tonight") {
            out.append(DayMatch(date: startOfToday, form: .today))
        }
        if containsWord(lower, "tomorrow") {
            if let next = calendar.date(byAdding: .day, value: 1, to: startOfToday) {
                out.append(DayMatch(date: next, form: .tomorrow))
            }
        }
        // "next week" is a WEEK, not a day — a bare seven days out, end of that
        // day. Deliberately coarse: nobody means an instant by it.
        if lower.contains("next week") {
            if let next = calendar.date(byAdding: .day, value: 7, to: startOfToday) {
                out.append(DayMatch(date: next, form: .explicit))
            }
        }
        for (index, name) in weekdayNames.enumerated() where containsWord(lower, name) {
            // Gregorian weekday is 1-based from Sunday; `weekdayNames` is
            // 0-based from Sunday, so the target is index + 1.
            if let next = nextOccurrence(ofWeekday: index + 1, after: now, calendar: calendar) {
                out.append(DayMatch(date: next, form: .weekday(index)))
            }
        }
        // ISO days: 2026-09-15. The one unambiguous written form.
        for iso in isoDays(in: lower) {
            var components = DateComponents()
            components.year = iso.year
            components.month = iso.month
            components.day = iso.day
            if let date = calendar.date(from: components) {
                out.append(DayMatch(date: calendar.startOfDay(for: date), form: .explicit))
            }
        }
        // Collapse to distinct DAYS; keep the most specific description of each
        // (an explicit date beats a weekday name for the same day).
        var byDay: [Date: DayMatch] = [:]
        for match in out {
            if let existing = byDay[match.date], existing.form == .explicit { continue }
            byDay[match.date] = match
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// The next STRICTLY future occurrence of a weekday. "Friday" said on a
    /// Friday means the one coming, not the one happening — a plan is never
    /// about a moment that has already started.
    ///
    /// "next friday" is treated identically to "friday". English genuinely does
    /// not agree on whether it means the coming Friday or the one after, and a
    /// coin-flip on a date she will visibly anticipate is worse than the
    /// nearer, more common reading.
    private static func nextOccurrence(
        ofWeekday weekday: Int,
        after now: Date,
        calendar: Calendar
    ) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 1...7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: startOfToday) else {
                continue
            }
            if calendar.component(.weekday, from: candidate) == weekday { return candidate }
        }
        return nil
    }

    private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// Language that makes the whole memory retrospective.
    private static let backwardMarkers = [
        "yesterday", "last week", "last month", "last year", "last night",
        "ago", "previously", "used to", "back in", "earlier today",
        "last sunday", "last monday", "last tuesday", "last wednesday",
        "last thursday", "last friday", "last saturday",
    ]

    private static func isoDays(in lower: String) -> [(year: Int, month: Int, day: Int)] {
        var out: [(Int, Int, Int)] = []
        let scalars = Array(lower)
        var index = 0
        while index + 10 <= scalars.count {
            let slice = String(scalars[index..<(index + 10)])
            let parts = slice.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
               let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
               (1...12).contains(month), (1...31).contains(day) {
                out.append((year, month, day))
                index += 10
                continue
            }
            index += 1
        }
        return out
    }

    // MARK: - Time of day

    /// An hour/minute, only when the text CUES one. A bare number is never a
    /// time: "9 open tabs" is not nine o'clock, and inventing an hour is how a
    /// register starts lying about when.
    private static func candidateTime(in lower: String) -> (hour: Int, minute: Int)? {
        let words = lower.split(whereSeparator: { $0 == " " }).map(String.init)
        var found: [(hour: Int, minute: Int)] = []
        for (index, word) in words.enumerated() {
            let previous = index > 0 ? words[index - 1] : ""
            let cued = timeCues.contains(previous)
            guard let parsed = parseClockWord(word, cued: cued, next: index + 1 < words.count ? words[index + 1] : "")
            else { continue }
            found.append(parsed)
        }
        // Two different times is the same ambiguity as two different days.
        let distinct = Set(found.map { $0.hour * 60 + $0.minute })
        guard distinct.count == 1, let first = found.first else { return nil }
        return first
    }

    private static let timeCues: Set<String> = ["at", "around", "by", "before", "after", "til", "until"]

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "noon": 12, "midnight": 0,
    ]

    /// `cued` means a word like "at"/"around" preceded this one. Digits need
    /// that cue OR a meridiem/colon of their own; number WORDS ("nine") always
    /// need the cue, because "nine" appears in prose far more often than
    /// "9:30" does.
    private static func parseClockWord(_ raw: String, cued: Bool, next: String) -> (hour: Int, minute: Int)? {
        var word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        // A meridiem may be attached ("9pm") or the next word ("9 pm").
        var meridiem: String?
        for suffix in ["am", "pm"] where word.hasSuffix(suffix) && word.count > suffix.count {
            meridiem = suffix
            word = String(word.dropLast(suffix.count))
        }
        if meridiem == nil, next == "am" || next == "pm" { meridiem = next }

        if let value = numberWords[word] {
            guard cued || meridiem != nil else { return nil }
            return (applyMeridiem(value, meridiem), 0)
        }
        if word.contains(":") {
            let parts = word.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return (applyMeridiem(hour, meridiem), minute)
        }
        if let hour = Int(word), (0...23).contains(hour) {
            guard cued || meridiem != nil else { return nil }
            return (applyMeridiem(hour, meridiem), 0)
        }
        return nil
    }

    /// No meridiem and an hour of 1–11 reads as the MORNING: "around nine"
    /// means nine in the morning, and someone who means the evening says "nine
    /// tonight" or "9pm". 12 and 13–23 are already unambiguous.
    private static func applyMeridiem(_ hour: Int, _ meridiem: String?) -> Int {
        switch meridiem {
        case "am": return hour == 12 ? 0 : hour
        case "pm": return hour == 12 ? 12 : (hour < 12 ? hour + 12 : hour)
        default: return hour
        }
    }

    /// A day with no stated time is the END of that day, exactly as the Desk's
    /// `deferUntil` contract reads a bare `yyyy-MM-dd`. "Friday" has not passed
    /// until Friday has.
    private static func combine(
        day: Date,
        time: (hour: Int, minute: Int)?,
        calendar: Calendar
    ) -> Date? {
        guard let time else {
            // Set the wall-clock end of the day rather than adding 86399
            // seconds: across a DST transition those are different instants,
            // and "Friday" means the end of Friday however long Friday was.
            return calendar.date(
                bySettingHour: 23, minute: 59, second: 59, of: day, matchingPolicy: .nextTime
            )
        }
        return calendar.date(
            bySettingHour: time.hour, minute: time.minute, second: 0, of: day, matchingPolicy: .nextTime
        )
    }

    // MARK: - Label

    /// Derived entirely from the RESOLVED instant. The user's words never reach
    /// it, which is what makes it safe to put in front of her.
    private static func label(
        for dueAt: Date,
        day: DayMatch,
        time: (hour: Int, minute: Int)?,
        now: Date,
        calendar: Calendar
    ) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let dayCount = calendar.dateComponents([.day], from: startOfToday, to: day.date).day ?? 0
        var word: String
        switch dayCount {
        case 0: word = "today"
        case 1: word = "tomorrow"
        case 2...6:
            let index = calendar.component(.weekday, from: day.date) - 1
            word = weekdayNames.indices.contains(index) ? weekdayNames[index] : isoDay(day.date, calendar)
        default: word = isoDay(day.date, calendar)
        }
        if let time {
            word += String(format: " %02d:%02d", time.hour, time.minute)
        }
        return String(word.prefix(labelCharacterCap))
    }

    private static func isoDay(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    // MARK: - Text

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whole-word containment. Substring matching would find "sunday" inside
    /// nothing useful but "at" inside "attention", and the time cues depend on
    /// this being exact.
    private static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0 == Substring(needle) }
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Read side: the instant an atom's metadata points at, or nil.
    public static func dueAt(in metadata: JSONValue?) -> Date? {
        guard case .object(let object)? = metadata,
              case .string(let raw)? = object[dueAtKey] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let parsed = formatter.date(from: raw) { return parsed }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    /// Read side: the short derived word, already bounded at write time and
    /// re-bounded here so a hand-edited row cannot widen it.
    public static func dueLabel(in metadata: JSONValue?) -> String? {
        guard case .object(let object)? = metadata,
              case .string(let raw)? = object[dueLabelKey] else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(labelCharacterCap))
    }
}
