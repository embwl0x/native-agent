import Foundation
import Synchronization

// Blueprint: | `OrganBody.swift` | `OrganBody`: the one body projection (each organ's line, deviation and last completed pass), the felt-memory rule, told faults a pass cleared, and the body read hook |

/// The body as one projection: every organ's line (latest beat, why, next expected beat) and its deviation, derived from the organ records on every read and
/// never stored. The agent's `mind.body` read, Doctor's Body view, the felt line in the agent's turns and the organism's signal are all drawn from it.
public struct OrganBody: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let organ: String
        public let latest: OrganPulse
        /// Nil when the organ's beats match its record; an organ switched off never deviates.
        public let deviation: OrganRecord.Deviation?
        /// When the next beat is due; nil for an organ run on events or switched off.
        public let next: Date?
        /// When the newest completed pass (`worked` or `nothing`) in its kept beats landed; nil when none did.
        public let passed: Date?
        /// Whether that pass comes after the newest failed or held beat in beat order, which whole-second times cannot tell apart.
        public let passedAfterFault: Bool

        /// The line both faces read, in plain words.
        public func words(now: Date) -> String {
            let name = OrganBody.name(organ)
            if let deviation { return name + " " + deviation.why }
            if latest.isOff { return name + " is off: " + String(latest.note.dropFirst(OrganPulse.offPrefix.count)) }
            var words = name + " " + latest.outcome.rawValue + " at " + OrganRecord.clock(latest.at, now: now)
            if !latest.note.isEmpty { words += " (" + latest.note + ")" }
            if let next { words += "; next by " + OrganRecord.clock(next, now: now) }
            return words
        }
    }

    public let at: Date
    /// Deviations first, then quiet organs, each by name. Empty when no organ has beaten yet: nothing is known, which is not a quiet body.
    public let lines: [Line]
    /// Organs whose beat evidence does not decode (organ id: why). Their state is unknown, never quiet.
    public let unreadable: [String: String]

    public init(records: [OrganRecord], unreadable: [String: String], now: Date, launchedAt: Date) {
        at = now
        self.unreadable = unreadable
        lines = records.map { record in
            let latest = record.latest
            let next = latest.isOff ? nil : latest.cadence.map { max(latest.at, launchedAt).addingTimeInterval($0) }
            let pass = record.beats.lastIndex { $0.outcome == .worked || $0.outcome == .nothing }
            let fault = record.beats.lastIndex { $0.outcome == .failed || ($0.outcome == .held && !$0.isOff) }
            return Line(organ: record.organ, latest: latest, deviation: record.deviation(now: now, launchedAt: launchedAt), next: next,
                        passed: pass.map { record.beats[$0].at }, passedAfterFault: pass.map { $0 > (fault ?? -1) } ?? false)
        }.sorted { ($0.deviation == nil ? 1 : 0, $0.organ) < ($1.deviation == nil ? 1 : 0, $1.organ) }
    }

    /// The organs whose beats the record did not predict.
    public var felt: [Line] { lines.filter { $0.deviation != nil } }

    /// An organ id in words: `studio_canon` reads "studio canon".
    public static func name(_ organ: String) -> String {
        organ.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
    }

    // MARK: Felt memory

    /// The last felt deviation's identity and size; repeated reads of that same evidence do not repeat its signal.
    public struct Mark: Codable, Sendable, Equatable {
        public let kind: OrganRecord.Deviation.Kind
        /// Whole seconds: the loop-state file keeps beats at that precision, so an onset read after a relaunch is the same onset.
        public let since: Date
        public let size: Int

        public init(_ deviation: OrganRecord.Deviation) {
            kind = deviation.kind
            since = Self.second(deviation.since)
            size = deviation.size
        }

        public func names(_ deviation: OrganRecord.Deviation) -> Bool {
            kind == deviation.kind && since == Self.second(deviation.since)
        }

        private static func second(_ date: Date) -> Date {
            Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
    }

    /// New deviations and changes in their kind, onset or size.
    public func unfelt(_ marks: [String: Mark]) -> [Line] {
        felt.filter { line in
            guard let deviation = line.deviation, let mark = marks[line.organ], mark.names(deviation) else { return true }
            return deviation.size != mark.size
        }
    }

    /// Marks once `lines` are felt: each felt line takes its current mark, other deviating organs keep theirs, and an organ that no longer deviates drops
    /// its mark.
    public func marks(feeling lines: [Line], over marks: [String: Mark]) -> [String: Mark] {
        let feeling = Set(lines.map(\.organ))
        return felt.reduce(into: [:]) { next, line in
            guard let deviation = line.deviation else { return }
            next[line.organ] = feeling.contains(line.organ) ? Mark(deviation) : marks[line.organ]
        }
    }

    /// Told deviations (`marks`) that have cleared with a completed pass since they began: a real pass, never a busy beat or a beat from before.
    /// A failure or hold is cleared by a pass after it in beat order, even within its second; silence and an empty pass by a later pass.
    public func recovered(_ marks: [String: Mark]) -> [Line] {
        lines.filter { line in
            guard line.deviation == nil, let mark = marks[line.organ], let passed = line.passed else { return false }
            let second = passed.timeIntervalSince1970.rounded(.down), since = mark.since.timeIntervalSince1970
            return mark.kind == .failed || mark.kind == .stuck ? line.passedAfterFault && second >= since : second > since
        }
    }

    /// Organs one felt line names, deviations first; the rest are counted and stay owed.
    public static let feltLineLimit = 3

    /// The one short line a turn carries for `lines` and for told faults `recovered` (already within the limit), in the agent's own voice; nil when
    /// there is nothing to feel.
    public static func feltLine(_ lines: [Line], recovered: [Line] = [], now: Date = Date()) -> String? {
        guard !lines.isEmpty || !recovered.isEmpty else { return nil }
        // One sentence per organ: an organ's own why may already hold a semicolon.
        let shown = lines.prefix(feltLineLimit).compactMap { line in
            line.deviation.map { name(line.organ) + " " + Self.bounded($0.why) }
        }
        let back = recovered.compactMap { line in
            line.passed.map { name(line.organ) + " works again (it passed at " + OrganRecord.clock($0, now: now) + ")" }
        }
        let more = lines.count > shown.count ? ". \(lines.count - shown.count) more in mind.body" : ""
        return "In my body: " + (shown + back).joined(separator: ". ") + more + "."
    }

    /// One line of an organ's own words: whitespace collapsed, trailing stops dropped, at most 160 characters.
    private static func bounded(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".;"))
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    // MARK: Read

    /// The app installs the body read where it installs pulse recording (BackgroundLoops owns the records; lower targets cannot import it).
    public static func install(_ read: @escaping @Sendable (Date) async throws -> OrganBody) {
        reader.withLock { $0 = Reader(read: read) }
    }

    /// The body now; nil until the read is installed. A missing read is no body, never a quiet one; a failed read throws.
    public static func read(now: Date = Date()) async throws -> OrganBody? {
        guard let read = reader.withLock({ $0 }) else { return nil }
        return try await read.read(now)
    }

    private struct Reader: Sendable {
        let read: @Sendable (Date) async throws -> OrganBody
    }
    private static let reader = Mutex<Reader?>(nil)
}
