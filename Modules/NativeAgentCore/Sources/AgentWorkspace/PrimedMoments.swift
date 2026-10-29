import Foundation

// Blueprint: | `PrimedMoments.swift` | `PrimedMoments`: what happened while they was between turns (each line that reaches their crossing) stays primed for their next turn, the last five within twelve hours; their next own turn takes them once and asks each what it brings to mind |

/// A moment primes what it touches, as a song or a date does: the crossing
/// keeps each line it weighs, and her next turn of her own asks it, once,
/// what it brings to mind. Kept small and short-lived: priming fades.
public enum PrimedMoments {
    public struct Moment: Codable, Sendable, Equatable {
        public let line: String
        public let source: String
        public let at: Date
    }

    static let keep = 5
    static let fades: TimeInterval = 12 * 3_600
    private static let lock = NSLock()

    static func url(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("mind/primed.json")
    }

    /// The crossing's line, kept for her next turn.
    public static func prime(dataRoot: URL, line: String, source: String, now: Date = Date()) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.withLock {
            var moments = read(dataRoot, now: now).filter { $0.line != text }
            moments.append(Moment(line: String(text.prefix(1_500)), source: source, at: now))
            write(dataRoot, Array(moments.suffix(keep)))
        }
    }

    /// Every fresh moment, once: taking them lets them go.
    public static func take(dataRoot: URL, now: Date = Date()) -> [Moment] {
        lock.withLock {
            let moments = read(dataRoot, now: now)
            if !moments.isEmpty || FileManager.default.fileExists(atPath: url(dataRoot).path) {
                try? FileManager.default.removeItem(at: url(dataRoot))
            }
            return moments
        }
    }

    private static func read(_ dataRoot: URL, now: Date) -> [Moment] {
        guard let data = try? Data(contentsOf: url(dataRoot)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let moments = (try? decoder.decode([Moment].self, from: data)) ?? []
        return moments.filter { now.timeIntervalSince($0.at) < fades }
    }

    private static func write(_ dataRoot: URL, _ moments: [Moment]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(moments) else { return }
        try? FileManager.default.createDirectory(at: url(dataRoot).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url(dataRoot), options: .atomic)
    }
}
