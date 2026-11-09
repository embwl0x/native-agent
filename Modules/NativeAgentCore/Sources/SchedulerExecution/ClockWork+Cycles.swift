import Foundation
import Experiences
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler
import DreamREMCycle
// Blueprint: | `ClockWork+Cycles.swift` | The dream and REM cards' wording and today's diary entries |

extension ClockWork {
    static func dreamEntriesForToday(dataRoot: URL, dateKey: String) throws -> [DreamDiarySnippet] {
        let files = try FileBackedDreamDiary(dataRoot: dataRoot).discover(in: .active, matching: .markdown)
        let newest = try files
            .filter { $0.name == "\(dateKey).md" || $0.name.hasPrefix("\(dateKey)_") }
            .map { file in
                let values = try file.url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = values.contentModificationDate else {
                    throw PersistenceCoreError.ioFailure("Dream metadata unavailable at \(file.url.path). Repair the diary file before publishing its receipt.")
                }
                return (file.url, modified)
            }
            .sorted { $0.1 > $1.1 }
        return try newest.prefix(5).map { url, _ in
            let text = try String(contentsOf: url, encoding: .utf8)
            let dream = DreamNight(text).latest
            return DreamDiarySnippet(path: url.path, title: dream?.title ?? "", summary: dream?.summary ?? "")
        }
    }

    static func dreamInboxMessage(
        entriesWritten: Int,
        sessionsProcessed: Int,
        errors: [String],
        entries: [DreamDiarySnippet]
    ) -> String {
        var lines: [String] = []
        if entriesWritten <= 0, !errors.isEmpty {
            lines.append("Dream cycle hit a provider or runtime error before writing a diary entry.")
            // Put the error detail second so it survives notification truncation.
            if let detail = firstErrorDetailLine(errors) {
                lines.append(detail)
            }
            lines.append("No dream file was created. Repair remains owed; app mind.dream runs the pass again.")
            if sessionsProcessed > 0 {
                lines.append("Recent conversations scanned: \(sessionsProcessed).")
            }
        } else if entriesWritten > 0 {
            lines.append("""
                Dream cycle wrote \(entriesWritten) entr\(entriesWritten == 1 ? "y" : "ies") across \(sessionsProcessed) recent \
                conversation\(sessionsProcessed == 1 ? "" : "s").
                """)
        } else {
            lines.append("Dream cycle ran, but there were no new dream entries to write.")
            if sessionsProcessed > 0 {
                lines.append("Recent conversations scanned: \(sessionsProcessed).")
            }
        }
        for entry in entries.prefix(3) {
            if !entry.title.isEmpty {
                lines.append(entry.title)
            }
            if !entry.summary.isEmpty {
                lines.append(entry.summary)
            }
        }
        if !errors.isEmpty {
            lines.append("Errors: \(errors.prefix(3).joined(separator: "; "))")
        }
        return lines.joined(separator: "\n\n")
    }

    /// The first non-empty line of the first error that carries one, trimmed to 160 characters so a long provider payload cannot swamp the notice.
    static func firstErrorDetailLine(_ errors: [String], limit: Int = 160) -> String? {
        for error in errors {
            for raw in error.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                if line.count <= limit { return line }
                return String(line.prefix(limit - 1)) + "…"
            }
        }
        return nil
    }

    static func remInboxMessage(
        proposalsGenerated: Int,
        archivedEntries: Int,
        tombstoneSkips: Int,
        growthMDEvicted: Bool
    ) -> String {
        var parts: [String] = [
            "Weekly REM consolidation generated \(proposalsGenerated) proposal\(proposalsGenerated == 1 ? "" : "s").",
        ]
        if tombstoneSkips > 0 {
            parts.append("\(tombstoneSkips) tombstoned proposal\(tombstoneSkips == 1 ? "" : "s") skipped.")
        }
        if archivedEntries > 0 {
            parts.append("\(archivedEntries) old dream entr\(archivedEntries == 1 ? "y" : "ies") archived.")
        }
        if growthMDEvicted {
            parts.append("GROWTH.md was compacted before new proposals.")
        }
        return parts.joined(separator: " ")
    }

    static func remRelatedPaths(dataRoot: URL) -> [String] {
        // REM proposals and pins belong to dataRoot; import-only storage cannot become their live owner.
        [
            dataRoot.appendingPathComponent("rem_proposals.jsonl").path,
            dataRoot.appendingPathComponent("rem_pins.json").path,
            PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("GROWTH.md").path,
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func anyInt(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(exactly: double.rounded(.towardZero)) ?? 0 }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return 0
    }

    static func anyBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes", "y"].contains(string.lowercased())
        }
        return false
    }
}
