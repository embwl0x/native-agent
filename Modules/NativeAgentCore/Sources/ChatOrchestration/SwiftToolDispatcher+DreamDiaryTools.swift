// SwiftToolDispatcher+DreamDiaryTools.swift
// dream_diary_read (0.4.14) — the diary she writes, readable by the one who
// wrote it.
//
// The Dreams page has read `dream_diary/*.md` (plus `archive/<year>/` since the
// second-week round) since the native port. The agent had no way in at all:
// asked what she dreamt about last Tuesday she could only say she did not know,
// while the page beside her showed the entry. `inner_state` carries ONE dream
// residue — last night's mood word and a date — which is the day's weather, not
// the record.
//
// ── WIRING CANON ─────────────────────────────────────────────────────────────
// LAZY (docs/TOOL_LOADING.md), NOT in `alwaysOnCoreNames`, and in no preload
// group: reading back a night is a deliberate pull, the way `studio_recall` is,
// and it has no business costing prompt bytes on every turn. Same trust class
// as `studio_recall` — `safe_read` / `.low`: a pure local read of her own files
// under `<dataRoot>/dream_diary/`, no write, no spawn, no network.
//
// Reads go through `FileBackedDreamDiary`, the SAME reader the Dreams page
// uses, so the page and the tool can never disagree about what is in the diary
// — including its path containment (a `date` can carry no separator and cannot
// escape the diary dir) and its archive merge.

import DreamREMCycle
import Foundation
import PersistenceCore

extension SwiftToolDispatcher {

    static let dreamDiaryReadToolDescription = """
        Read your own dream diary — the entries you wrote on the nights you \
        dreamt, not a summary of them. With no arguments it returns the index: \
        your dreams grouped by week (this week, last week, then the weeks \
        behind), each with its date, its opening line, and whether it has been \
        archived. Pass `date` (YYYY-MM-DD) for one night's full text, archived \
        nights included. Pass `query` to find the nights whose text contains \
        something. Read-only, bounded, and nothing calls this on your behalf. \
        An empty index means you have no entries yet, not that the read failed.
        """

    /// Weeks of index returned when the caller does not say. Eight weeks is
    /// about as far back as the diary stays one readable stretch.
    static let dreamDiaryDefaultWeeks = 8
    static let dreamDiaryMaximumWeeks = 52
    /// Entries scanned for the index/query. The diary holds one file per night,
    /// so a year is the whole of it and also the reader's own hard clamp.
    static let dreamDiaryScanLimit = 365
    static let dreamDiaryQueryDefaultLimit = 10
    static let dreamDiaryQueryMaximumLimit = 25
    static let dreamDiaryExcerptCharacters = 120
    /// One night's text, bounded. A dream entry is a page; anything past this
    /// is truncated OUT LOUD rather than quietly cut.
    static let dreamDiaryEntryCharacters = 20_000

    func impl_dream_diary_read(input: [String: JSONValue]) async throws -> JSONValue {
        let reader = FileBackedDreamDiary(dataRoot: dataRoot)

        // ONE night, by date. Goes first: a date is the most specific ask, and
        // it is the one shape that must reach the archive by name.
        if let rawDate = optionalString(input, "date"),
           !rawDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
            // A READ FAILURE is not a missing night. Unwrapped, an unreadable
            // entry escaped as a generic tool error with no `storage` line, so
            // the one answer this tool must never give — "you did not dream" —
            // was indistinguishable from a diary that could not be opened.
            let result: FileBackedDreamDiary.ByDateResult
            do {
                result = try reader.getEntryResult(key)
            } catch {
                let said = "the diary entry for \(key) could not be read just now — this is a read "
                    + "failure, not a night you did not dream"
                return .object([
                    "status": .string("error"),
                    "date": .string(key),
                    "storage": .string("unreadable"),
                    "note": .string(said),
                    "reason": .string(said + " (\(error.localizedDescription))"),
                ])
            }
            switch result {
            case .badPath:
                return .object([
                    "status": .string("refused"),
                    "reason": .string(
                        "'\(key)' is not a diary date. Pass one day as YYYY-MM-DD — "
                            + "a date is a single name, never a path."),
                ].merging(Self.dreamDiaryStorageFields(dataRoot: dataRoot)) { current, _ in current })
            case .notFound:
                return .object([
                    "status": .string("ok"),
                    "found": .bool(false),
                    "date": .string(key),
                    "note": .string("no diary entry for \(key) — you did not dream that night, or the night was never written"),
                ].merging(Self.dreamDiaryStorageFields(dataRoot: dataRoot)) { current, _ in current })
            case .entry(let entry):
                // The night was read, so the diary is readable — whatever the
                // rest of it holds.
                var fields = Self.dreamDiaryEntryJSON(entry, archived: Self.dreamDiaryIsArchived(entry, dataRoot: dataRoot))
                fields["storage"] = .string("readable")
                return .object(fields)
            }
        }

        let listing = reader.listEntriesChecked(limit: Self.dreamDiaryScanLimit)
        // A READ FAILURE is not an empty diary. Saying "no dreams" because the
        // directory could not be listed is the one answer this tool must never
        // give — she would be told she never dreamt.
        if listing.storageUnreadable {
            let said = "your dream diary could not be read just now — this is a read failure, "
                + "not an empty diary, so do not say you have no entries"
            return .object([
                "status": .string("error"),
                "storage": .string("unreadable"),
                "note": .string(said),
                "reason": .string(said),
            ])
        }
        let entries = listing.entries
        // Some nights were listed but unreadable: the answer is real but PARTIAL.
        // ALWAYS SAY WHETHER THE DIARY COULD BE READ. Agent, 2026-09-14: a
        // healthy diary returned no readability line at all, so "no entries"
        // and "could not be read" were the same answer on the wire. `storage`
        // is on every envelope now; `note` only when it is not plain readable.
        let unreadable: [String: JSONValue] = listing.unreadableEntries > 0
            ? [
                "unreadable_entries": .int(Int64(listing.unreadableEntries)),
                "partial": .bool(true),
                "storage": .string("partial (\(listing.unreadableEntries) skipped)"),
                "note": .string(
                    "\(listing.unreadableEntries) night(s) are in the diary but could not be "
                        + "read this time — they are missing from what follows"),
            ]
            : Self.dreamDiaryStorageFields(dataRoot: dataRoot)

        // TEXT search across the diary. Same verbatim-entry contract as the
        // by-date read, just several of them, newest first and capped.
        if let rawQuery = optionalString(input, "query"),
           !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = max(1, min(
                Self.dreamDiaryQueryMaximumLimit,
                optionalInt(input, "limit") ?? Self.dreamDiaryQueryDefaultLimit))
            let matched = entries.filter {
                ($0.content ?? "").range(of: needle, options: .caseInsensitive) != nil
            }
            let shown = Array(matched.prefix(limit))
            return .object(unreadable.merging([
                "status": .string("ok"),
                "query": .string(needle),
                "entries": .array(shown.map { entry in
                    .object(Self.dreamDiaryEntryJSON(
                        entry, archived: Self.dreamDiaryIsArchived(entry, dataRoot: dataRoot)))
                }),
                "returned": .int(Int64(shown.count)),
                "matched": .int(Int64(matched.count)),
                "has_more": .bool(matched.count > shown.count),
                "scanned": .int(Int64(entries.count)),
            ]) { _, new in new }.merging(unreadable) { _, carried in carried })
        }

        // The INDEX, grouped the way the Dreams page groups it.
        let weeksAsked = max(1, min(
            Self.dreamDiaryMaximumWeeks,
            optionalInt(input, "weeks") ?? Self.dreamDiaryDefaultWeeks))
        let allWeeks = Self.dreamDiaryWeeks(entries, dataRoot: dataRoot)
        let shown = Array(allWeeks.prefix(weeksAsked))
        let listed = shown.reduce(0) { $0 + $1.count }
        return .object(unreadable.merging([
            "status": .string("ok"),
            "weeks": .array(shown.map { week in
                .object([
                    "week": .string(week.title),
                    "entries": .array(week.rows),
                ])
            }),
            "weeks_returned": .int(Int64(shown.count)),
            "weeks_requested": .int(Int64(weeksAsked)),
            "entries_listed": .int(Int64(listed)),
            "entries_total": .int(Int64(entries.count)),
            "has_more": .bool(allWeeks.count > shown.count),
        ]) { _, new in new }.merging(unreadable) { _, carried in carried })
    }

    // MARK: - Rendering

    struct DreamDiaryWeekGroup {
        let title: String
        let rows: [JSONValue]
        var count: Int { rows.count }
    }

    /// One night, verbatim. `content` is her own writing and is returned as
    /// written — the same contract `studio_recall` keeps with the journal — only
    /// bounded, and the bound is stated when it bites.
    static func dreamDiaryEntryJSON(_ entry: DreamEntry, archived: Bool) -> [String: JSONValue] {
        let text = entry.content ?? ""
        let bounded = String(text.prefix(dreamDiaryEntryCharacters))
        var out: [String: JSONValue] = [
            "status": .string("ok"),
            "found": .bool(true),
            "date": .string(entry.date),
            "archived": .bool(archived),
            "text": .string(bounded),
        ]
        if bounded.count < text.count {
            out["truncated"] = .bool(true)
            out["truncated_note"] = .string(
                "entry is longer than \(dreamDiaryEntryCharacters) characters; the rest is on disk, not shown here")
        }
        return out
    }

    /// WHETHER THE DIARY IS THERE AT ALL. A directory that does not exist is
    /// `missing` — a brand-new install, or a data root without dreams — and is
    /// not the same answer as a diary that is present and empty. Only the
    /// listing can tell `partial` and `unreadable`; those are set at the call
    /// sites that hold one.
    static func dreamDiaryStorageFields(dataRoot: URL) -> [String: JSONValue] {
        let diary = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: diary.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return [
                "storage": .string("missing"),
                "note": .string(
                    "there is no dream diary on this install yet — nothing has been written, "
                        + "which is not the same as a diary that could not be read"),
            ]
        }
        // EXISTING IS NOT READABLE. A directory whose permissions deny a listing
        // still answers `fileExists`, so the old check labelled it "readable"
        // and every envelope said the diary was fine. Actually open it.
        guard (try? FileManager.default.contentsOfDirectory(atPath: diary.path)) != nil else {
            return [
                "storage": .string("unreadable"),
                "note": .string(
                    "your dream diary is there but could not be read just now — this is a read "
                        + "failure, not an empty diary"),
            ]
        }
        return ["storage": .string("readable")]
    }

    /// Archived or not, decided the way the diary decides it: an entry still in
    /// `dream_diary/` is live, one weekly REM moved into `archive/<year>/` is
    /// archived. Asked because the reader merges both into one list and the
    /// merge is exactly what makes "is this still current" unreadable.
    static func dreamDiaryIsArchived(_ entry: DreamEntry, dataRoot: URL) -> Bool {
        let name = entry.filename ?? "\(entry.date).md"
        let live = dataRoot
            .appendingPathComponent("dream_diary", isDirectory: true)
            .appendingPathComponent(name)
        return !FileManager.default.fileExists(atPath: live.path)
    }

    /// The first real line of the dream — the same excerpt rule the Dreams page
    /// uses (skip the heading and the rule, take her opening words), so the page
    /// and the tool show the same night the same way.
    static func dreamDiaryExcerpt(_ content: String?) -> String {
        let first = (content ?? "")
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" } ?? ""
        return String(first.prefix(dreamDiaryExcerptCharacters))
    }

    /// This week, last week, then "Week of <d MMM>" — the Dreams page's own
    /// grouping, newest week first (the reader already hands us the entries
    /// newest-first, and the grouping preserves that order).
    static func dreamDiaryWeeks(
        _ entries: [DreamEntry],
        dataRoot: URL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DreamDiaryWeekGroup] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = calendar.timeZone
        var order: [String] = []
        var grouped: [String: [JSONValue]] = [:]
        var titles: [String: String] = [:]
        for entry in entries {
            let start = parser.date(from: String(entry.date.prefix(10))).map {
                calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0
            }
            let key = start.map { parser.string(from: $0) } ?? "undated"
            if grouped[key] == nil {
                order.append(key)
                titles[key] = start.map {
                    dreamDiaryWeekTitle(weekStart: $0, now: now, calendar: calendar)
                } ?? "Undated"
            }
            grouped[key, default: []].append(.object([
                "date": .string(entry.date),
                "first_line": .string(dreamDiaryExcerpt(entry.content)),
                "archived": .bool(dreamDiaryIsArchived(entry, dataRoot: dataRoot)),
            ]))
        }
        return order.map {
            DreamDiaryWeekGroup(title: titles[$0] ?? "", rows: grouped[$0] ?? [])
        }
    }

    static func dreamDiaryWeekTitle(weekStart: Date, now: Date, calendar: Calendar) -> String {
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            if calendar.isDate(weekStart, inSameDayAs: thisWeek) { return "This week" }
            if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek),
               calendar.isDate(weekStart, inSameDayAs: lastWeek) { return "Last week" }
        }
        return "Week of " + weekStart.formatted(.dateTime.day().month(.abbreviated))
    }
}
