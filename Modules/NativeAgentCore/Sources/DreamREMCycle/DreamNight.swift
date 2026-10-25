import Foundation

// Blueprint: | `DreamNight.swift` | `DreamNight` and `DreamDiaryWeeks`: shared diary section/title parsing and week grouping across all dream readers |

/// One night of the diary, read the one way (`DreamCycleRunner` writes it):
/// `# Dream — <date>`, then every later run of the same night as a
/// `## Dreamt again — <yyyy-MM-dd HH:mm>` section. Each dream opens with
/// `**<title>**`, then its summary, then `_Mood: <mood>_`.
///
/// Today, the Dreams page, `dream_diary_read` and provenance all read a night
/// through here, so "the night's dream" is the same dream everywhere: the
/// latest one (10-23: Today named the re-dream while the diary named the
/// night's first dream).
public struct DreamNight: Sendable, Equatable {
    public struct Dream: Sendable, Equatable {
        /// When a later run wrote it, as its heading names it; nil for the
        /// night's first dream (the file's own time says when that was).
        public var dreamtAgainAt: String?
        public var title: String?
        public var mood: String?
        /// The first real line: the title as written, or the opening words
        /// of an entry without one.
        public var firstLine: String
    }

    public static let firstHeading = "# Dream — "
    public static let againHeading = "## Dreamt again — "

    public let dreams: [Dream]

    public var latest: Dream? { dreams.last }

    public init(_ content: String) {
        var dreams: [Dream] = []
        var current: Dream?
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(Self.againHeading) {
                if let current { dreams.append(current) }
                let stamp = line.dropFirst(Self.againHeading.count).trimmingCharacters(in: .whitespaces)
                current = Dream(dreamtAgainAt: stamp.isEmpty ? nil : stamp, firstLine: "")
                continue
            }
            if line.hasPrefix(Self.firstHeading), current == nil {
                current = Dream(firstLine: "")
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line == "---" { continue }
            var dream = current ?? Dream(firstLine: "")
            if dream.firstLine.isEmpty {
                dream.firstLine = line
                if line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") {
                    let inner = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty, !inner.contains("**") { dream.title = inner }
                }
            } else if dream.mood == nil, line.hasPrefix("_Mood:") {
                var value = String(line.dropFirst("_Mood:".count))
                if value.hasSuffix("_") { value = String(value.dropLast()) }
                dream.mood = value.trimmingCharacters(in: .whitespaces)
            }
            current = dream
        }
        if let current { dreams.append(current) }
        self.dreams = dreams
    }
}

extension DreamEntry {
    /// This entry's night, read the one way.
    public var night: DreamNight { DreamNight(content ?? "") }
}

/// The diary read as history: this week, last week, then "Week of <d MMM>",
/// newest week first (entries arrive newest-first and the grouping keeps that
/// order). The Dreams page and `dream_diary_read` group with this one rule.
public enum DreamDiaryWeeks {
    public struct Week: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let entries: [DreamEntry]
    }

    public static func weeks(_ entries: [DreamEntry], now: Date = Date(),
                             calendar: Calendar = Calendar.autoupdatingCurrent) -> [Week] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = calendar.timeZone
        var order: [String] = []
        var grouped: [String: [DreamEntry]] = [:]
        var titles: [String: String] = [:]
        for entry in entries {
            let start = parser.date(from: String(entry.date.prefix(10))).map {
                calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0
            }
            let key = start.map { parser.string(from: $0) } ?? "undated"
            if grouped[key] == nil {
                order.append(key)
                titles[key] = start.map { title(weekStart: $0, now: now, calendar: calendar) } ?? "Undated"
            }
            grouped[key, default: []].append(entry)
        }
        return order.map { Week(id: $0, title: titles[$0] ?? "", entries: grouped[$0] ?? []) }
    }

    static func title(weekStart: Date, now: Date, calendar: Calendar) -> String {
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            if calendar.isDate(weekStart, inSameDayAs: thisWeek) { return "This week" }
            if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek),
               calendar.isDate(weekStart, inSameDayAs: lastWeek) { return "Last week" }
        }
        return "Week of " + weekStart.formatted(.dateTime.day().month(.abbreviated))
    }
}
