import Foundation

// MARK: - Dream provenance (item 4)
//
// A dream used to end at "_(woven from 3 conversations)_" — a COUNT. A count
// cannot tell a week apart from a night: three dreams about one evening and
// three evenings each dreamt once collapse to the same number, and REM, reading
// only the dream dates, called both of them recurrence.
//
// The dream now retains WHAT it was woven from: the source message / encounter
// ids it actually read, and the date each of those things HAPPENED — the lived
// date, which is not the date of the dream. REM reads those lines back and
// counts INDEPENDENT LIVED DATES separately from DREAM DATES.
//
// Nothing here reaches the dream prompt. It is written after the model has
// spoken, exactly like the studio citation line beside the mood.

/// One thing a dream was woven from: a transcript row or a studio encounter,
/// with the date it HAPPENED (not the date it was dreamt about).
public struct DreamSourceRef: Sendable, Equatable {
    /// `message` for a transcript row, `recollection` for a consolidated
    /// stretch, `studio_entry` for a filed journal encounter.
    public var kind: String
    /// The row / entry id, verbatim, so the chain can be walked by hand.
    public var id: String
    /// The conversation the row belongs to, when there is one.
    public var sessionID: String?
    /// `YYYY-MM-DD` in the local calendar — when this actually happened.
    public var livedDate: String

    public init(kind: String, id: String, sessionID: String? = nil, livedDate: String) {
        self.kind = kind
        self.id = id
        self.sessionID = sessionID
        self.livedDate = livedDate
    }
}

/// The provenance a dream entry carries, and the parse of it back out.
///
/// `nil` from `parse` means the entry carries NO provenance line at all (every
/// diary entry written before this shape existed). That is reported as
/// "provenance unavailable" — it is never silently treated as support.
public struct DreamEntryProvenance: Sendable, Equatable {
    /// Distinct `YYYY-MM-DD` dates the dream's material actually happened on,
    /// ascending. Empty means the dream said so honestly: it had none to give.
    public var livedDates: [String]
    /// The source refs, as written (`<kind>:<id>` or `<kind>:<session>/<id>`).
    public var sourceRefs: [String]

    public init(livedDates: [String], sourceRefs: [String]) {
        self.livedDates = livedDates
        self.sourceRefs = sourceRefs
    }

    /// TRUE when the entry named its sources but had none to name.
    public var isEmpty: Bool { livedDates.isEmpty && sourceRefs.isEmpty }

    // MARK: Wire shape

    static let livedPrefix = "_Lived on: "
    static let sourcesPrefix = "_Sources: "
    /// The honest label for a dream that could not resolve where its material
    /// came from. Never omitted — an absent line is indistinguishable from a
    /// line that was never written, and the difference is the whole point.
    public static let unavailableLabel = "provenance unavailable"
    /// Bound on what one entry writes, so a 300-row night can't bloat the diary.
    static let sourceRefLimit = 24
    private static let dateRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
    }()

    /// The provenance block a dream entry carries, or the honest unavailable
    /// line when there is nothing to bind. Always emits the `_Lived on:` line
    /// so a reader (and REM) can tell "nothing to cite" from "written before
    /// this existed".
    public static func renderBlock(_ sources: [DreamSourceRef]) -> String {
        var seenRefs = Set<String>()
        var refs: [String] = []
        var seenDates = Set<String>()
        for source in sources {
            let id = source.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let date = source.livedDate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDateStem(date) else { continue }
            seenDates.insert(date)
            let session = source.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (session?.isEmpty == false) ? "\(session!)/\(id)" : id
            let ref = "\(source.kind):\(body)@\(date)"
            guard seenRefs.insert(ref).inserted else { continue }
            if refs.count < sourceRefLimit { refs.append(ref) }
        }
        let dates = seenDates.sorted()
        guard !dates.isEmpty else {
            return "\(livedPrefix)\(unavailableLabel)_\n\n"
        }
        var out = "\(livedPrefix)\(dates.joined(separator: ", "))_\n\n"
        if !refs.isEmpty {
            out += "\(sourcesPrefix)\(refs.joined(separator: " · "))_\n\n"
        }
        return out
    }

    /// Read the block back out of a diary entry. `nil` when the entry has no
    /// `_Lived on:` line — a legacy entry, whose provenance is UNAVAILABLE and
    /// must not be counted as lived recurrence.
    public static func parse(_ content: String?) -> DreamEntryProvenance? {
        guard let content else { return nil }
        var livedLine: String?
        var sourcesLine: String?
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if livedLine == nil, line.hasPrefix(livedPrefix) { livedLine = line }
            if sourcesLine == nil, line.hasPrefix(sourcesPrefix) { sourcesLine = line }
        }
        guard let livedLine else { return nil }
        if livedLine.contains(unavailableLabel) {
            return DreamEntryProvenance(livedDates: [], sourceRefs: [])
        }
        let dates = Set(matches(of: dateRegex, in: livedLine)).sorted()
        var refs: [String] = []
        if let sourcesLine {
            let body = String(sourcesLine.dropFirst(sourcesPrefix.count))
                .replacingOccurrences(of: "_", with: "")
            refs = body.components(separatedBy: " · ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return DreamEntryProvenance(livedDates: dates, sourceRefs: refs)
    }

    static func isDateStem(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        guard let match = dateRegex.firstMatch(in: s, options: [], range: range) else { return false }
        return match.range == range
    }

    private static func matches(of regex: NSRegularExpression, in s: String) -> [String] {
        let range = NSRange(s.startIndex..., in: s)
        return regex.matches(in: s, options: [], range: range).compactMap {
            Range($0.range, in: s).map { r in String(s[r]) }
        }
    }

    /// The local-calendar `YYYY-MM-DD` a timestamp belongs to — the unit the
    /// diary is named in, so a lived date and a dream date are comparable.
    public static func dateStem(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }
}
