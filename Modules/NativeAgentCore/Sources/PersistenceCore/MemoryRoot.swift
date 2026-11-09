import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `MemoryRoot.swift` | `MemoryRoot`: one moment a memory reached the agent (how, by, at, through); its codec, union, lines and short lead form |

/// One moment the agent came to know a memory: how it knows it, who told it or where its past was kept, when that reached it, and the principals
/// the stem attests for the turn that wrote it. A memory's roots live in `metadata.roots`; the memory store is their only writer.
public struct MemoryRoot: Sendable, Hashable, Codable {
    /// What the agent states. `kept` is the stem's word for a memory whose origin nothing recorded or stated; no writer states it.
    public enum How: String, Sendable, Codable, CaseIterable {
        case told, noticed, inferred, verified, remembered, kept

        /// The ways a writer may state.
        public static let stated: [How] = [.told, .noticed, .inferred, .verified, .remembered]
    }

    /// What a writer states about one telling; the store adds the time it was written and the turn's principals.
    public struct Telling: Sendable, Equatable {
        public let how: How
        public let by: String?
        public let since: Date?

        public init(how: How, by: String? = nil, since: Date? = nil) {
            self.how = how
            self.by = by
            self.since = since
        }

        /// Remembered, or dated before the write: the agent's own past carried here.
        public var restatesOwnPast: Bool { how == .remembered || since != nil }
    }

    /// A stored root that cannot be read; the item it belongs to reports it.
    public struct Unreadable: Error, LocalizedError, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { "Memory roots are unreadable: \(reason)" }
    }

    public static let key = "roots"
    /// Names enter model-facing lines and delimited metadata, so delimiters, brackets and controls are excluded.
    public static let nameLimit = 40

    public let how: How
    public let by: String?
    /// ISO-8601: when the agent came to know it, as stated.
    public let at: String
    /// ISO-8601: when the store wrote this root. The stem stamps it, never an argument; a root that steers reads at it, so a telling is never
    /// dated before it was told.
    public let written: String
    /// Principals, sorted and unique; empty is a clean attestation.
    public let through: [String]

    public init(how: How, by: String?, at: String, written: String, through: [String]) {
        self.how = how
        self.by = by
        self.at = at
        self.written = written
        self.through = Array(Set(through.filter { !$0.isEmpty })).sorted()
    }

    public var date: Date? { NativeTimestampFormat.parseISO8601FractionalFirst(at) }

    public static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= nameLimit else { return nil }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "." || scalar == "-" || scalar == "'"
        }
        return allowed ? name : nil
    }

    /// Gregorian and POSIX in the person's zone: dates and month names never follow the host locale.
    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    // MARK: Codec

    private enum CodingKeys: String, CodingKey { case how, by, at, written, through }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard let how = How(rawValue: try fields.decode(String.self, forKey: .how)) else {
            throw Unreadable("how is not one of \(How.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let by = try fields.decodeIfPresent(String.self, forKey: .by)
        if let by, Self.validName(by) != by { throw Unreadable("by is not a name of at most \(Self.nameLimit) letters, digits, spaces and . - '") }
        let at = try fields.decode(String.self, forKey: .at)
        guard NativeTimestampFormat.parseISO8601FractionalFirst(at) != nil else { throw Unreadable("at is not an ISO-8601 time") }
        let written = try fields.decode(String.self, forKey: .written)
        guard NativeTimestampFormat.parseISO8601FractionalFirst(written) != nil else { throw Unreadable("written is not an ISO-8601 time") }
        let through = try fields.decode([String].self, forKey: .through)
        guard through.allSatisfy({ !$0.isEmpty }) else { throw Unreadable("through holds an empty principal") }
        self.init(how: how, by: by, at: at, written: written, through: through)
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(how.rawValue, forKey: .how)
        try fields.encodeIfPresent(by, forKey: .by)
        try fields.encode(at, forKey: .at)
        try fields.encode(written, forKey: .written)
        try fields.encode(through, forKey: .through)
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["how": .string(how.rawValue), "at": .string(at), "written": .string(written),
                                           "through": .array(through.map(JSONValue.string))]
        if let by { fields["by"] = .string(by) }
        return .object(fields)
    }

    public static func decode(_ value: JSONValue) throws -> MemoryRoot {
        guard case .object(let fields) = value else { throw Unreadable("a root is not an object") }
        let extra = Set(fields.keys).subtracting(["how", "by", "at", "written", "through"])
        guard extra.isEmpty else { throw Unreadable("a root holds unknown fields \(extra.sorted().joined(separator: ", "))") }
        guard case .string(let rawHow)? = fields["how"], let how = How(rawValue: rawHow) else {
            throw Unreadable("how is not one of \(How.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var by: String?
        switch fields["by"] {
        case nil: by = nil
        case .string(let name)? where validName(name) == name: by = name
        default: throw Unreadable("by is not a name of at most \(nameLimit) letters, digits, spaces and . - '")
        }
        guard case .string(let at)? = fields["at"], NativeTimestampFormat.parseISO8601FractionalFirst(at) != nil else {
            throw Unreadable("at is not an ISO-8601 time")
        }
        guard case .string(let written)? = fields["written"], NativeTimestampFormat.parseISO8601FractionalFirst(written) != nil else {
            throw Unreadable("written is not an ISO-8601 time")
        }
        guard case .array(let values)? = fields["through"] else { throw Unreadable("through is not a list") }
        let through = try values.map { value -> String in
            guard case .string(let principal) = value, !principal.isEmpty else { throw Unreadable("through holds a principal that is not a name") }
            return principal
        }
        return MemoryRoot(how: how, by: by, at: at, written: written, through: through)
    }

    /// The roots a memory's metadata holds. A memory always has at least one; none, or any malformed root, is unreadable.
    public static func roots(in metadata: JSONValue?) throws -> [MemoryRoot] {
        guard case .object(let fields)? = metadata, let value = fields[key] else { throw Unreadable("no roots are recorded") }
        guard case .array(let values) = value, !values.isEmpty else { throw Unreadable("roots is not a nonempty list") }
        return try values.map(decode)
    }

    /// Metadata holding exactly these roots, whatever it held under the key before.
    public static func setting(_ roots: [MemoryRoot], in metadata: JSONValue?) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if case .object(let current)? = metadata { fields = current }
        fields[key] = .array(roots.map(\.json))
        return .object(fields)
    }

    /// What a reader holds: the roots, or the named reason they cannot be read. The item reports the reason; nothing reads it as clean.
    public enum Reading: Sendable, Equatable {
        case held([MemoryRoot])
        case unreadable(String)
    }

    public static func reading(_ metadata: JSONValue?) -> Reading {
        do { return .held(try roots(in: metadata)) } catch let error as Unreadable { return .unreadable(error.reason) } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    // MARK: Identity and union

    public func day(in calendar: Calendar) -> String {
        guard let date else { return at }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The same telling: the same how, by and through on the same day of the person's calendar. A source telling it on another day is another
    /// moment, dated when it was told: an older root of the same source never dates newer words.
    public func isSame(as other: MemoryRoot) -> Bool {
        let calendar = Self.calendar(in: .current)
        return how == other.how && by?.lowercased() == other.by?.lowercased() && through == other.through
            && day(in: calendar) == other.day(in: calendar)
    }

    /// Every root of every group once, earliest first; the same telling on one day keeps its earliest time.
    public static func union(_ groups: [[MemoryRoot]]) -> [MemoryRoot] {
        var out: [MemoryRoot] = []
        for root in ordered(groups.flatMap { $0 }) where !out.contains(where: { $0.isSame(as: root) }) {
            out.append(root)
        }
        return out
    }

    public static func ordered(_ roots: [MemoryRoot]) -> [MemoryRoot] {
        roots.enumerated().sorted { lhs, rhs in
            let left = lhs.element.date ?? .distantFuture, right = rhs.element.date ?? .distantFuture
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// When the agent first knew it: the earliest root's time.
    public static func firstKnown(_ roots: [MemoryRoot]) -> MemoryRoot? { ordered(roots).first }

    // MARK: Words, in the agent's voice

    public func line(calendar: Calendar) -> String {
        let date = day(in: calendar)
        switch how {
        case .told: return by.map { "\($0) told me on \(date)" } ?? "I was told this on \(date)"
        case .noticed: return "I noticed this on \(date)"
        case .inferred: return "I worked this out on \(date)"
        case .verified: return "I checked this on \(date)"
        case .remembered: return by.map { "From \($0), I've known this since \(date)" } ?? "I've known this since \(date)"
        case .kept: return "I've kept this since \(date); where it came from isn't recorded"
        }
    }

    /// The short form a context lead and a recall hit carry.
    public func lead(calendar: Calendar) -> String {
        let date = day(in: calendar)
        switch how {
        case .told: return by.map { "\($0) told me \(date)" } ?? "I was told it \(date)"
        case .noticed: return "I noticed it \(date)"
        case .inferred: return "I worked it out \(date)"
        case .verified: return "I checked it \(date)"
        case .remembered: return by.map { "from \($0), known since \(date)" } ?? "known since \(date)"
        case .kept: return "kept since \(date), source unrecorded"
        }
    }

    /// One to three roots in full; past three, the earliest, the latest and how many more.
    public static func lead(of roots: [MemoryRoot], calendar: Calendar) -> String? {
        let sorted = ordered(roots)
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let parts = sorted.count <= 3 ? sorted.map { $0.lead(calendar: calendar) }
            : [first.lead(calendar: calendar), last.lead(calendar: calendar), "+\(sorted.count - 2) more"]
        return parts.joined(separator: "; ")
    }
}
