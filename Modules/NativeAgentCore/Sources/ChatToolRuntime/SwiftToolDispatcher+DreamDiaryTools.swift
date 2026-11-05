// Share FileBackedDreamDiary with the Dreams page so containment, archive merging and visible entries agree.

import DreamREMCycle
import Foundation
import PersistenceCore
// Blueprint: | `SwiftToolDispatcher+DreamDiaryTools.swift` | `SwiftToolDispatcher`: `impl_dream_diary_read`, `dreamDiaryEntryJSON`, `dreamDiaryStorageFields` |

extension SwiftToolDispatcher {


    /// Eight weeks keeps the default index one readable stretch.
    static let dreamDiaryDefaultWeeks = 8
    static let dreamDiaryMaximumWeeks = 52
    /// One file per night makes a year the full scan and the reader’s hard clamp.
    static let dreamDiaryScanLimit = 365
    static let dreamDiaryQueryDefaultLimit = 10
    static let dreamDiaryQueryMaximumLimit = 25
    static let dreamDiaryExcerptCharacters = 120
    /// A dream is a page; any truncation must be disclosed.
    static let dreamDiaryEntryCharacters = 20_000

    func impl_dream_diary_read(input: [String: JSONValue]) async throws -> JSONValue {
        let reader = FileBackedDreamDiary(dataRoot: dataRoot)

        // An exact date takes precedence and must reach archived entries by name.
        if let rawDate = optionalString(input, "date"),
           !rawDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
            // A read failure is not a missing night; every answer names storage availability.
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
            case .badPath(let storage):
                return .object([
                    "status": .string("refused"),
                    "reason": .string(
                        "'\(key)' is not a diary date. Pass one day as YYYY-MM-DD — "
                            + "a date is a single name, never a path."),
                ].merging(Self.dreamDiaryStorageFields(storage)) { current, _ in current })
            case .notFound(let storage):
                return .object([
                    "status": .string("ok"),
                    "found": .bool(false),
                    "date": .string(key),
                    "note": .string("no diary entry for \(key) — you did not dream that night, or the night was never written"),
                ].merging(Self.dreamDiaryStorageFields(storage)) { current, _ in current })
            case .entry(let entry, let archived):
                // A successful night read proves readability independently of the rest of the diary.
                var fields = Self.dreamDiaryEntryJSON(entry, archived: archived)
                fields["storage"] = .string("readable")
                return .object(fields)
            }
        }

        let listing = reader.listEntriesChecked(limit: Self.dreamDiaryScanLimit)
        // An unreadable directory is unknown storage, never evidence of an empty diary.
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
        // Every envelope reports storage readability; a note distinguishes unreadable or partial results from empty ones.
        let unreadable: [String: JSONValue] = listing.unreadableEntries > 0
            ? [
                "unreadable_entries": .int(Int64(listing.unreadableEntries)),
                "unreadable_files": .object(listing.failures.mapValues(JSONValue.string)),
                "partial": .bool(true),
                "storage": .string("partial (\(listing.unreadableEntries) skipped)"),
                "note": .string(
                    "\(listing.unreadableEntries) night(s) are in the diary but could not be "
                        + "read this time — they are missing from what follows"),
            ]
            : Self.dreamDiaryStorageFields(listing.storage)

        if let rawQuery = optionalString(input, "query"),
           !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = max(1, min(
                Self.dreamDiaryQueryMaximumLimit,
                Self.jsonInt(input["limit"]) ?? Self.dreamDiaryQueryDefaultLimit))
            let matched = entries.filter {
                ($0.content ?? "").range(of: needle, options: .caseInsensitive) != nil
            }
            let shown = Array(matched.prefix(limit))
            return .object(unreadable.merging([
                "status": .string("ok"),
                "query": .string(needle),
                "entries": .array(shown.map { entry in
                    .object(Self.dreamDiaryEntryJSON(
                        entry, archived: !listing.activeFilenames.contains(entry.filename ?? "\(entry.date).md")))
                }),
                "returned": .int(Int64(shown.count)),
                "matched": .int(Int64(matched.count)),
                "has_more": .bool(matched.count > shown.count),
                "scanned": .int(Int64(entries.count)),
            ]) { _, new in new }.merging(unreadable) { _, carried in carried })
        }

        let weeksAsked = max(1, min(
            Self.dreamDiaryMaximumWeeks,
            Self.jsonInt(input["weeks"]) ?? Self.dreamDiaryDefaultWeeks))
        let allWeeks = Self.dreamDiaryWeeks(entries, activeFilenames: listing.activeFilenames)
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

    /// Return the writer’s words verbatim, disclosing any bound that truncates them.
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

    static func dreamDiaryStorageFields(_ storage: String) -> [String: JSONValue] {
        if storage == "missing" {
            return [
                "storage": .string("missing"),
                "note": .string(
                    "there is no dream diary on this install yet — nothing has been written, "
                        + "which is not the same as a diary that could not be read"),
            ]
        }
        if storage == "unreadable" {
            return [
                "storage": .string("unreadable"),
                "note": .string(
                    "your dream diary is there but could not be read just now — this is a read "
                        + "failure, not an empty diary"),
            ]
        }
        return ["storage": .string("readable")]
    }

    /// Group added dreams inside their original night; rerunning a night does not create a separate day.
    static func dreamDiaryIndexRow(_ entry: DreamEntry, activeFilenames: Set<String>) -> JSONValue {
        let night = entry.night
        var row: [String: JSONValue] = [
            "date": .string(entry.date),
            "first_line": .string(String((night.latest.map { $0.title ?? $0.firstLine } ?? "")
                .prefix(dreamDiaryExcerptCharacters))),
            "archived": .bool(!activeFilenames.contains(entry.filename ?? "\(entry.date).md")),
        ]
        if night.dreams.count > 1 {
            row["dreams"] = .array(night.dreams.map { dream in
                var fields: [String: JSONValue] = ["title": .string(dream.title ?? dream.firstLine)]
                if let at = dream.dreamtAgainAt { fields["dreamt_again_at"] = .string(at) }
                return .object(fields)
            })
        }
        return .object(row)
    }

    static func dreamDiaryWeeks(
        _ entries: [DreamEntry],
        activeFilenames: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DreamDiaryWeekGroup] {
        DreamDiaryWeeks.weeks(entries, now: now, calendar: calendar).map { week in
            DreamDiaryWeekGroup(title: week.title, rows: week.entries.map { dreamDiaryIndexRow($0, activeFilenames: activeFilenames) })
        }
    }
}
