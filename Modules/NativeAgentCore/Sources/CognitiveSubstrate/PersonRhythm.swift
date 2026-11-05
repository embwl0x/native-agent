import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `PersonRhythm.swift` | `PersonRhythm`: zone-bound daily evidence, standing claims and break identities |

/// Only cognition mutates lived day evidence; daily contributions prevent a busy conversation from counting as independent days.
public struct PersonRhythm: Codable, Sendable {
    public struct Activity: Codable, Sendable {
        public var at: Date
        public var door: String
        public init(at: Date, door: String) { self.at = at; self.door = String(door.prefix(64)) }
    }
    public struct Bin: Codable, Sendable {
        public var active = 0.0
        public var observed = 0.0
        var squared = 0.0
        mutating func fade(_ factor: Double) {
            active *= factor; observed *= factor; squared *= factor * factor
        }
        var tries: Int {
            squared > 0 ? Int(min(observed, observed * observed / squared).rounded(.down)) : 0
        }
    }
    struct Day: Codable, Sendable {
        var at: Date
        var observed = Array(repeating: 0.0, count: 24)
        /// First activity in each hour, not a transcript or an event log.
        var activity: [Activity] = []
        var completeStart = true
    }
    public struct Claim: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case quiet, startsBy, activeIn }
        public var kind: Kind
        public var from: Int
        public var to: Int
        public var confidence: Double
        public func contains(hour: Int) -> Bool {
            from < to ? (from..<to).contains(hour) : hour >= from || hour < to
        }
        public func words(person: String, day: Date) -> String {
            switch kind {
            case .quiet: return "\(person) is usually quiet from \(PersonRhythm.time(from * 60, on: day)) to \(PersonRhythm.time(to * 60, on: day))."
            case .startsBy: return "\(person) is usually up by \(PersonRhythm.time(to, on: day))."
            case .activeIn: return "\(person) is usually active around \(PersonRhythm.time(from * 60, on: day))."
            }
        }
    }
    public struct Break: Codable, Sendable {
        public var at: Date
        public var claim: Claim
        public init(at: Date, claim: Claim) { self.at = at; self.claim = claim }
        public func words(person: String) -> String {
            let calendar = Calendar.current
            let minute = calendar.component(.hour, from: at) * 60 + calendar.component(.minute, from: at)
            if claim.kind == .quiet {
                return """
                    \(person) is up at \(PersonRhythm.time(minute, on: at)); \(person) is usually quiet from \(PersonRhythm.time(claim.from * 60, on: at)) to \
                    \(PersonRhythm.time(claim.to * 60, on: at)).
                    """
            }
            return """
                It's \(PersonRhythm.time(minute, on: at)) and I haven't heard from \(person) today; \(person) is usually up by \
                \(PersonRhythm.time(claim.to, on: at)).
                """
        }
    }
    public private(set) var bins = Array(repeating: Bin(), count: 24)
    public private(set) var claims: [Claim] = []
    /// Starts are first activity after the longest quiet run, one per local day.
    public private(set) var starts: [Date] = []
    var days: [Day] = []
    var carried = Array(repeating: Bin(), count: 24)
    var carriedAt: Date
    public var lastTurnKey: String?
    public var breaks: [String: Date] = [:]
    public var pending: [String: Break] = [:]
    public private(set) var timeZone: String
    public init(at: Date) { carriedAt = at; timeZone = TimeZone.current.identifier }

    public static func path(_ root: URL) -> URL { root.appendingPathComponent("mind/rhythm.json") }
    public static func load(_ root: URL) throws -> Self? {
        let path = path(root)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard value.bins.count == 24, value.carried.count == 24,
              TimeZone(identifier: value.timeZone) != nil, value.days.count <= 64,
              value.claims.count <= 3,
              value.claims.allSatisfy({ $0.from >= 0 && $0.from < 24 && $0.to >= 0
                  && $0.to < ($0.kind == .startsBy ? 1440 : 24) && $0.confidence.isFinite }),
              value.days.allSatisfy({ $0.observed.count == 24 && $0.activity.count <= 24
                  && $0.observed.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }),
              (value.bins + value.carried).allSatisfy({
                  $0.active.isFinite && $0.observed.isFinite && $0.squared.isFinite
                      && $0.active >= 0 && $0.observed >= $0.active && $0.squared >= 0
              }) else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
    public func save(_ root: URL) throws {
        let path = Self.path(root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(self), to: path)
    }
    private mutating func day(_ at: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: at)
        if let i = days.firstIndex(where: { $0.at == start }) { return i }
        days.append(Day(at: start))
        return days.count - 1
    }
    public mutating func activity(_ value: Activity) {
        let calendar = Calendar.current
        rebucket(to: calendar)
        activity(value, calendar: calendar)
    }
    private mutating func activity(_ value: Activity, calendar: Calendar) {
        let i = day(value.at, calendar: calendar), hour = calendar.component(.hour, from: value.at)
        days[i].observed[hour] = 1
        if let old = days[i].activity.firstIndex(where: { calendar.component(.hour, from: $0.at) == hour }) {
            if value.at < days[i].activity[old].at { days[i].activity[old] = value }
        } else { days[i].activity.append(value) }
    }
    /// Workspace edges close real awake intervals. No tick, no inferred uptime across launch.
    public mutating func observed(from: Date, to: Date, present: Bool) {
        let calendar = Calendar.current
        rebucket(to: calendar)
        var cursor = max(from, to.addingTimeInterval(-31 * 86_400))
        while cursor < to, let interval = calendar.dateInterval(of: .hour, for: cursor) {
            let end = min(to, interval.end), i = day(cursor, calendar: calendar)
            let hour = calendar.component(.hour, from: cursor)
            days[i].observed[hour] = min(1, days[i].observed[hour] + end.timeIntervalSince(cursor) / interval.duration)
            if present { activity(Activity(at: cursor, door: "presence"), calendar: calendar) }
            cursor = end
        }
    }
    /// Only complete indexed days support message-silence evidence; silence cannot establish Mac uptime.
    public mutating func coldStart(_ rows: [Activity], at: Date) {
        for row in rows { activity(row) }
        let today = Calendar.current.startOfDay(for: at)
        let first = days.map(\.at).min()
        for i in days.indices {
            if days[i].at == first { days[i].completeStart = false }
            if days[i].at < today, days[i].at != first { days[i].observed = Array(repeating: 1, count: 24) }
        }
        recompute(at: at)
    }
    /// Hour fractions need their recorded zone; timestamp-free aggregates cannot travel.
    private mutating func rebucket(to calendar: Calendar) {
        if timeZone != calendar.timeZone.identifier, let zone = TimeZone(identifier: timeZone) {
            var oldCalendar = calendar
            oldCalendar.timeZone = zone
            let oldDays = days
            days = []
            carried = Array(repeating: Bin(), count: 24)
            for old in oldDays {
                for h in 0..<24 where old.observed[h] > 0 {
                    guard let instant = oldCalendar.date(bySettingHour: h, minute: 0, second: 0, of: old.at) else { continue }
                    let i = day(instant, calendar: calendar), hour = calendar.component(.hour, from: instant)
                    days[i].observed[hour] = min(1, days[i].observed[hour] + old.observed[h])
                    days[i].completeStart = days[i].completeStart && old.completeStart
                }
                for event in old.activity { activity(event, calendar: calendar) }
            }
            timeZone = calendar.timeZone.identifier
        }
    }
    public mutating func recompute(at: Date) {
        let calendar = Calendar.current
        rebucket(to: calendar)
        let cutoff = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: at))!
        let fade = pow(0.5, max(0, at.timeIntervalSince(carriedAt)) / (7 * 86_400))
        for i in carried.indices { carried[i].fade(fade) }
        carriedAt = at
        func contribution(_ day: Day, into bins: inout [Bin]) {
            let weight = pow(0.5, max(0, at.timeIntervalSince(day.at)) / (7 * 86_400))
            let active = Set(day.activity.map { calendar.component(.hour, from: $0.at) })
            for h in 0..<24 {
                let observed = day.observed[h] * weight
                bins[h].observed += observed
                bins[h].squared += observed * observed
                if active.contains(h) { bins[h].active += weight }
            }
        }
        for day in days where day.at < cutoff { contribution(day, into: &carried) }
        days.removeAll { $0.at < cutoff }
        bins = carried
        for day in days { contribution(day, into: &bins) }
        breaks = breaks.filter { $0.value >= cutoff }
        pending = pending.filter { $0.value.at >= cutoff }
        // One coarse quiet run; never treat its hours as independent nights.
        let quiet = bins.map { $0.observed > 0 && $0.active / $0.observed <= 0.1 }
        var run: (from: Int, length: Int)?
        for h in 0..<24 where quiet[h] && !quiet[(h + 23) % 24] {
            var length = 0
            while length < 24 && quiet[(h + length) % 24] { length += 1 }
            if length > (run?.length ?? 0) { run = (h, length) }
        }
        let quietEnd = run.map { ($0.from + $0.length) % 24 } ?? 0
        starts = days.filter { $0.completeStart }.compactMap { day in
            day.activity.filter { calendar.component(.hour, from: $0.at) >= quietEnd }.map(\.at).min()
        }.sorted()
        // Only coarse candidates are checked: a quiet run and the observed upper bound of starts. Hour activity is offered after three weeks of days.
        let activeCandidate = days.count >= 21 ? bins.indices.max(by: {
            bins[$0].active / max(1, bins[$0].observed) < bins[$1].active / max(1, bins[$1].observed)
        }) : nil
        let among = (run == nil ? 0 : 1) + (starts.isEmpty ? 0 : 1) + (activeCandidate == nil ? 0 : 1)
        func standing(_ hits: Int, _ tries: Int) -> Double? {
            // A private, care-gated fact has half the cost of withholding a useful noticing. This standing buys attention only, never action.
            let result = NativeAgentCore.Expectation.stands(hits: hits, tries: tries, cHit: 1, cMiss: 0.5, among: among)
            return result.stands ? result.lower : nil
        }
        claims = []
        if let run {
            let hours = (0..<run.length).map { (run.from + $0) % 24 }
            let tries = hours.map { bins[$0].tries }.min() ?? 0
            let rate = hours.map { 1 - bins[$0].active / bins[$0].observed }.min() ?? 0
            if let lower = standing(Int((Double(tries) * rate).rounded(.down)), tries) {
                claims.append(Claim(kind: .quiet, from: run.from, to: quietEnd, confidence: lower))
            }
        }
        let weights = starts.map { pow(0.5, max(0, at.timeIntervalSince($0)) / (7 * 86_400)) }
        let sum = weights.reduce(0, +), squared = weights.reduce(0) { $0 + $1 * $1 }
        let n = squared > 0 ? Int(min(sum, sum * sum / squared).rounded(.down)) : 0
        let timed = zip(starts, weights).map {
            (minute: calendar.component(.hour, from: $0.0) * 60 + calendar.component(.minute, from: $0.0), weight: $0.1)
        }.sorted { $0.minute < $1.minute }
        var mass = 0.0
        let upper = timed.first { value in mass += value.weight; return mass >= sum * 0.95 }?.minute
        let hitWeight = upper.map { upper in timed.filter { $0.minute <= upper }.reduce(0) { $0 + $1.weight } } ?? 0
        let hits = sum > 0 ? min(n, Int((Double(n) * hitWeight / sum + 1e-9).rounded(.down))) : 0
        if let upper, let lower = standing(hits, n) {
            claims.append(Claim(kind: .startsBy, from: 0, to: upper, confidence: lower))
        }
        if let h = activeCandidate, bins[h].observed > 0 {
            let n = bins[h].tries
            let hits = Int((Double(n) * bins[h].active / bins[h].observed).rounded(.down))
            if let lower = standing(hits, n) { claims.append(Claim(kind: .activeIn, from: h, to: (h + 1) % 24, confidence: lower)) }
        }
    }
    public func started(on day: Date) -> Bool {
        starts.contains { Calendar.current.isDate($0, inSameDayAs: day) }
    }
    public static func time(_ minute: Int, on day: Date) -> String {
        let calendar = Calendar.current
        let at = calendar.date(bySettingHour: (minute / 60) % 24, minute: minute % 60, second: 0, of: day)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: at)
    }
}
