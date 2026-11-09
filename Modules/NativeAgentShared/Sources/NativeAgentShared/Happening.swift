import Foundation
// Blueprint: | `Happening.swift` | `Happening` and `Thought`: the one form of every change the agent's attention takes in, and what one thought attended |

/// A persisted change. Owed kinds open a thought; world and self changes are weighed by the turn program.
public struct Happening: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case returned, moment, body, world, `self` }
    public static let wordsLimit = 280
    public static let showsLimit = 4_000

    public var kind: Kind
    /// What it is about (a watch, a job, a queue step, a care); worth that touches no care gathers on this subject.
    public var subject: String
    /// Where it came from: `sense:<watch>`, `part:<id>`, `clock:day`, `mac:front`, `job:<id>`, `contact:<id>`, `queue:<handle>`, `stem`.
    public var door: String
    /// Whose words it carries: `self`, `world`, `person`, or an agent's id.
    public var who: String
    public var words: String
    /// One happening per key: a second post under the same key is the same happening and writes nothing.
    public var once: String
    /// The parts' signal it also is (`app.installed`, `person.here`). Its source signals the parts itself, with the signal's own payload.
    public var signal: String?
    /// A care of the agent's moving: which (its id), how far (-1...1), and whether it holds an open question.
    public var care: String?
    public var moved: Double?
    public var open: Bool?
    /// The conversation it returns to; nil opens the agent's own mind stream.
    public var route: String?
    /// A promise's recorded reply route (its persisted envelope metadata, as JSON text), when the return is owed to the person who asked.
    public var reply: String?
    /// Agents whose words it quotes, and those of them elevated: the thought that reads it carries their authority, never more.
    public var peers: [String]?
    public var elevated: [String]?
    /// Material the thought shows beside the line, quoted (a habit's receipt, an organ to grow). Never drawn on a face.
    public var shows: String?

    public init(_ kind: Kind, subject: String, door: String, who: String = "world", words: String, once: String,
                signal: String? = nil, care: String? = nil, moved: Double? = nil, open: Bool? = nil,
                route: String? = nil, reply: String? = nil, peers: [String]? = nil, elevated: [String]? = nil, shows: String? = nil) {
        self.kind = kind; self.subject = subject; self.door = door; self.who = who
        self.words = String(words.prefix(Self.wordsLimit)); self.once = once; self.signal = signal
        self.care = care; self.moved = moved.flatMap { $0.isFinite ? $0 : nil }; self.open = open; self.route = route; self.reply = reply
        self.peers = peers.flatMap { $0.isEmpty ? nil : $0 }; self.elevated = elevated.flatMap { $0.isEmpty ? nil : $0 }
        self.shows = shows.map { String($0.prefix(Self.showsLimit)) }
    }

    /// Someone waits on it (a person or agent, the conversation that started some work, the agent's past self, its body): it opens a thought unweighed.
    public var owed: Bool { kind != .world && kind != .self }
    /// Its experience id in the record.
    public var id: String { "happening:" + once }
    /// Where it is owed: the conversation it returns to, or the agent's own mind stream.
    public var destination: String { "conversation:" + (route ?? Self.stream) }
    /// The agent's own mind stream: one conversation of thoughts, never replayed as history.
    public static let stream = "mind"
}

/// What one thought of the agent's attended. Its experience's outcome says how it went: `hit` (it spoke, acted with an effect, filed a promise or kept a
/// memory), `empty`, or `failed`; a care moving after it amends an empty thought with the claim `care.moved`.
public struct Thought: Codable, Sendable, Equatable {
    /// The field node whose drive ignited it; nil for a thought opened by owed happenings.
    public var node: String?
    public var drive: Double?
    /// The happenings it attended (record ids) and the doors they came through.
    public var happenings: [String]
    public var through: [String]
    /// The class its no-op record is kept under: the ignited node, or the owed kinds and doors it carried.
    public var kind: String
    public var session: String
    public var run: String?

    public init(node: String?, drive: Double?, happenings: [String], through: [String], kind: String, session: String, run: String?) {
        self.node = node; self.drive = drive; self.happenings = happenings; self.through = through
        self.kind = kind; self.session = session; self.run = run
    }

    /// The claim a care's later movement adds to the thought that attended it.
    public static let careMoved = "care.moved"
}
