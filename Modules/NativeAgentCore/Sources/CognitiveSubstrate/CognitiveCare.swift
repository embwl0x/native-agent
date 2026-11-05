import Foundation
import Experiences
import PersistenceCore

// Blueprint: | `CognitiveCare.swift` | Care stance, relationships, depth and bounded story; durable merge links retain movement evidence |
/// A care holds stance, relationships, depth, open questions and lived story; charge is derived from the story.
public struct CognitiveCare: Sendable, Equatable, Identifiable, Codable {
    /// How deep it runs, which sets how long a feeling about it lasts.
    public enum Depth: String, Sendable, Equatable, Codable, CaseIterable {
        case now, lately, season, life

        public var halfLife: TimeInterval {
            switch self {
            case .now: return 2 * 3_600
            case .lately: return 12 * 3_600
            case .season: return 2 * 86_400
            case .life: return 4 * 86_400
            }
        }
    }
    /// A stance makes a care an opinion.
    public struct Stance: Sendable, Equatable, Codable {
        public var text: String
        public var because: String
        public var wouldChangeMind: String

        public init(text: String, because: String, wouldChangeMind: String) {
            self.text = String(text.prefix(CognitiveCare.stanceCharacters))
            self.because = String(because.prefix(CognitiveCare.stanceCharacters))
            self.wouldChangeMind = String(wouldChangeMind.prefix(CognitiveCare.stanceCharacters))
        }
    }
    public enum Mover: String, Sendable, Equatable, Codable, CaseIterable {
        case them, her, world
    }
    public struct DepthChange: Sendable, Equatable, Codable {
        public var from: Depth
        public var to: Depth
        public init(from: Depth, to: Depth) { self.from = from; self.to = to }
    }
    /// One time it moved the agent: a pointer to what really happened (`source`: `exchange:<session>/<turn>` or a memory id), never a second copy of it.
    public struct Moment: Sendable, Equatable, Codable {
        public var at: Date
        /// -1...1: away from or toward what the agent cares about.
        public var moved: Double
        public var by: Mover
        public var who: String?
        public var felt: String
        public var note: String
        public var source: String
        public var depthChange: DepthChange?
        /// A proposed change, held as evidence until the agent's night confirms it.
        public var stancePressure: Stance?
        /// Only an observed gap closure counts as evidence.
        public var closedGap: Bool?

        public init(at: Date, moved: Double, by: Mover, who: String? = nil, felt: String, note: String,
                    source: String, depthChange: DepthChange? = nil, stancePressure: Stance? = nil,
                    closedGap: Bool? = nil) {
            self.at = at
            self.moved = moved.isFinite ? min(1, max(-1, moved)) : 0
            self.by = by
            self.who = who
            self.felt = String(felt.prefix(CognitiveCare.feltCharacters))
            self.note = String(note.prefix(CognitiveCare.noteCharacters))
            self.source = source
            self.depthChange = depthChange
            self.stancePressure = stancePressure
            self.closedGap = closedGap
        }
    }
    /// Movements older than the newest `storyMovements`, folded into one line.
    public struct Folded: Sendable, Equatable, Codable {
        public var count: Int
        public var sumMoved: Double
        public var since: Date
        /// Merge and folding retain distinct movement days; nil carries no surviving evidence.
        public var movedDays: [Date]?

        public init(count: Int, sumMoved: Double, since: Date, movedDays: [Date]? = nil) {
            self.count = count
            self.sumMoved = sumMoved
            self.since = since
            self.movedDays = movedDays
        }
        private enum CodingKeys: String, CodingKey { case count, sumMoved, since, movedDays }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let count = try values.decode(Int.self, forKey: .count)
            guard count >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .count, in: values,
                    debugDescription: "A folded movement count cannot be negative")
            }
            self.init(count: count, sumMoved: try values.decode(Double.self, forKey: .sumMoved),
                      since: try values.decode(Date.self, forKey: .since),
                      movedDays: try values.decodeIfPresent([Date].self, forKey: .movedDays))
        }
    }
    public enum Origin: Sendable, Equatable, Codable {
        case seed, grown
        case migrated(String)
    }
    public var id: UUID
    public var about: String
    /// Person keys it is held between; empty means the agent's alone.
    public var with: [String]
    public var depth: Depth
    public var stance: Stance?
    /// The gap: an unanswered question or unfinished thing. nil is settled.
    public var open: String?
    public var story: [Moment]
    public var folded: Folded?
    public var origin: Origin
    public var createdAt: Date
    public var updatedAt: Date
    /// When the night faded it (never moved within its depth's horizon). It stays in the store and is not shown or read as live; an ordinarily faded care comes
    /// back when touched. Merged donors follow their survivor.
    public var fadedAt: Date?
    /// A merged donor never revives independently; later moments and evidence follow this care to its survivor (which may itself merge later).
    public var mergedInto: UUID?
    /// Stamped once after all judgments for a moment apply; nil carries no recorded fold.
    public var lived: UInt64?
    /// Stable moment/ordinal birth identities that moved this care by meaning. Refolding follows the original target even after its words have changed.
    public var birthIDs: [UUID]?

    static func survivorID(for id: UUID, among cares: [UUID: Self]) -> UUID? {
        var current = id, seen = Set<UUID>()
        while seen.insert(current).inserted, let care = cares[current] {
            if let next = care.mergedInto { current = next; continue }
            guard let marker = care.story.last(where: {
                $0.by == .her && $0.moved == 0 && $0.felt == "came together" && $0.note.hasPrefix("became part of ")
            }) else { return current }
            // Match the donor's bounded note to the survivor's same-night entry; missing or ambiguous evidence cannot authorize undoing a merge.
            let survivors = cares.values.filter { candidate in
                candidate.id != care.id && Set(candidate.with) == Set(care.with)
                    && marker.note == String("became part of \(candidate.about)".prefix(Self.noteCharacters))
                    && candidate.story.contains {
                        $0.at == marker.at && $0.source == marker.source && $0.by == .her
                            && $0.felt == "came together" && !$0.note.hasPrefix("became part of ")
                    }
            }
            guard survivors.count == 1, let next = survivors.first?.id else { return nil }
            current = next
        }
        return nil
    }

    public static let aboutCharacters = 120
    public static let stanceCharacters = 200
    public static let openCharacters = 200
    public static let noteCharacters = 120
    public static let feltCharacters = 40
    /// The newest movements kept whole; every depth change is always kept.
    public static let storyMovements = 24
    /// Notes get the same recent-history window, independently of movements.
    public static let storyNotes = storyMovements
    /// Pressure keeps distinct proposals across days, so within-day volume cannot consume the evidence needed for a life's 14-day span.
    public static let stancePressureDays = 24
    public static let ownerKey = "owner"

    public init(id: UUID, about: String, with: [String] = [], depth: Depth, stance: Stance? = nil,
                open: String? = nil, story: [Moment] = [], origin: Origin, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.about = String(about.prefix(Self.aboutCharacters))
        self.with = with
        self.depth = depth
        self.stance = stance
        self.open = open.map { String($0.prefix(Self.openCharacters)) }
        self.story = []
        self.folded = nil
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        for moment in story { record(moment) }
    }
    /// Recent movement, signed, each decayed on this care's clock at read time.
    public func charge(at now: Date) -> Double {
        let halfLife = depth.halfLife
        return story.reduce(0) { sum, moment in
            sum + moment.moved * pow(0.5, max(0, now.timeIntervalSince(moment.at)) / halfLife)
        }
    }
    /// Backdated movements retain time order; only movements beyond `storyMovements` fold. Notes have their own bound; depth changes never fold.
    public mutating func record(_ moment: Moment) {
        story.insert(moment, at: story.lastIndex(where: { $0.at <= moment.at }).map { $0 + 1 } ?? 0)
        updatedAt = max(updatedAt, moment.at)
        while story.filter({ $0.depthChange == nil && $0.moved != 0 }).count > Self.storyMovements,
              let oldest = story.firstIndex(where: { $0.depthChange == nil && $0.moved != 0 }) {
            let gone = story.remove(at: oldest)
            let calendar = Calendar.current
            let dates = (folded?.movedDays ?? []) + [gone.at]
            let days = Dictionary(dates.map { (calendar.startOfDay(for: $0), $0) },
                                  uniquingKeysWith: max).values.sorted()
            // A lifetime tally saturates at its representable maximum; it is descriptive evidence, never a reason to stop recording a care.
            let count = folded?.count ?? 0
            folded = Folded(count: count < Int.max ? count + 1 : Int.max, sumMoved: (folded?.sumMoved ?? 0) + gone.moved,
                            since: min(folded?.since ?? gone.at, gone.at),
                            movedDays: Array(days))
        }
        while story.filter({ $0.depthChange == nil && $0.moved == 0 && $0.stancePressure == nil && $0.felt != "changed my mind" }).count > Self.storyNotes,
              let oldest = story.firstIndex(where: { $0.depthChange == nil && $0.moved == 0 && $0.stancePressure == nil && $0.felt != "changed my mind" }) {
            story.remove(at: oldest)
        }
        // Only exact same-day proposals are redundant. The dream, never this compactor, decides whether different proposals point the same way.
        let calendar = Calendar.current
        var daily: [Date: [Stance]] = [:]
        for index in story.indices.reversed() {
            guard let stance = story[index].stancePressure else { continue }
            let day = calendar.startOfDay(for: story[index].at)
            if daily[day]?.contains(stance) == true {
                story.remove(at: index)
            } else { daily[day, default: []].append(stance) }
        }
        let days = daily.keys.sorted()
        if days.count > Self.stancePressureDays {
            let oldest = days[days.count - Self.stancePressureDays]
            story.removeAll { $0.stancePressure != nil && calendar.startOfDay(for: $0.at) < oldest }
        }
    }

    /// A merge loses no retained movement. Subsequent recording uses the normal story bounds and folds movement days rather than discarding their evidence.
    mutating func absorbHistory(of other: Self) {
        story = (story + other.story).sorted { $0.at < $1.at }
        if let incoming = other.folded {
            if let existing = folded {
                let total = existing.count.addingReportingOverflow(incoming.count)
                folded = Folded(count: total.overflow ? Int.max : total.partialValue,
                                sumMoved: existing.sumMoved + incoming.sumMoved,
                                since: min(existing.since, incoming.since),
                                movedDays: Array(Set((existing.movedDays ?? []) + (incoming.movedDays ?? []))).sorted())
            } else { folded = incoming }
        }
        updatedAt = max(updatedAt, other.updatedAt)
        lived = [lived, other.lived].compactMap { $0 }.max()
        let aliases = Set((birthIDs ?? []) + (other.birthIDs ?? []) + [other.id])
        birthIDs = aliases.isEmpty ? nil : aliases.sorted { $0.uuidString < $1.uuidString }
        if other.depth.halfLife > depth.halfLife { depth = other.depth }
    }
}
