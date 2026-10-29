import Foundation
import Experiences
import PersistenceCore

// Blueprint: | `CognitiveCare.swift` | Care stance, relationships, depth and bounded lived story with unchanged Codable representation |
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
    /// What she thinks or wants about it. A care with a stance is an opinion.
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
    /// One time it moved her: a pointer to what really happened (`source`:
    /// `exchange:<session>/<turn>` or a memory id), never a second copy of it.
    public struct Moment: Sendable, Equatable, Codable {
        public var at: Date
        /// -1...1: away from or toward what she cares about.
        public var moved: Double
        public var by: Mover
        /// The person key when `by` is them.
        public var who: String?
        public var felt: String
        public var note: String
        public var source: String
        public var depthChange: DepthChange?

        public init(at: Date, moved: Double, by: Mover, who: String? = nil, felt: String, note: String,
                    source: String, depthChange: DepthChange? = nil) {
            self.at = at
            self.moved = moved.isFinite ? min(1, max(-1, moved)) : 0
            self.by = by
            self.who = who
            self.felt = String(felt.prefix(CognitiveCare.feltCharacters))
            self.note = String(note.prefix(CognitiveCare.noteCharacters))
            self.source = source
            self.depthChange = depthChange
        }
    }
    /// Movements older than the newest `storyMovements`, folded into one line.
    public struct Folded: Sendable, Equatable, Codable {
        public var count: Int
        public var sumMoved: Double
        public var since: Date
        /// Movement witnesses for the first eight distinct local days and the
        /// latest day: enough for every earned-depth threshold, without keeping
        /// the discarded story. nil is a legacy fold with no surviving evidence.
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
    /// Person keys it is held between; empty means hers alone.
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
    /// When the night faded it (never moved within its depth's horizon). It
    /// stays in the store and is not shown or read as live; touched again, it
    /// comes back.
    public var fadedAt: Date?
    /// The fold seq of the last lived moment that moved this care. Stamped once
    /// per moment after all of that moment's judgments are applied, and saved
    /// in the care's own row. nil: none (or a row an older binary wrote).
    public var lived: UInt64?

    public static let aboutCharacters = 120
    public static let stanceCharacters = 200
    public static let openCharacters = 200
    public static let noteCharacters = 120
    public static let feltCharacters = 40
    /// The newest movements kept whole; every depth change is always kept.
    public static let storyMovements = 24
    /// Notes get the same recent-history window, independently of movements.
    public static let storyNotes = storyMovements
    /// The owner's person key.
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
    /// Place one moment in time order (a backdated one goes where it
    /// happened). Past the newest `storyMovements` movements the oldest folds
    /// into `folded`; zero-movement notes have their own window and depth changes never fold.
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
            // A lifetime tally saturates at its representable maximum; it is
            // descriptive evidence, never a reason to stop recording a care.
            let count = folded?.count ?? 0
            folded = Folded(count: count < Int.max ? count + 1 : Int.max, sumMoved: (folded?.sumMoved ?? 0) + gone.moved,
                            since: min(folded?.since ?? gone.at, gone.at),
                            movedDays: Array(days.prefix(8)) + (days.count > 8 ? Array(days.suffix(1)) : []))
        }
        while story.filter({ $0.depthChange == nil && $0.moved == 0 }).count > Self.storyNotes,
              let oldest = story.firstIndex(where: { $0.depthChange == nil && $0.moved == 0 }) {
            story.remove(at: oldest)
        }
    }
}
