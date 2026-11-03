import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore

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
        do { try lock.withLock {
            var moments = try read(dataRoot, now: now).filter { $0.line != text }
            moments.append(Moment(line: String(text.prefix(1_500)), source: source, at: now))
            try write(dataRoot, Array(moments.suffix(keep)))
        } } catch { unavailable(dataRoot, error) }
    }

    /// Every fresh moment, once: taking them lets them go.
    public static func take(dataRoot: URL, now: Date = Date()) throws -> [Moment] {
        do { return try lock.withLock {
            let moments = try read(dataRoot, now: now)
            do { try FileManager.default.removeItem(at: url(dataRoot)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            return moments
        } } catch {
            unavailable(dataRoot, error)
            throw ToolFailureError("Primed moments could not be read and consumed: \(error.localizedDescription). Existing bytes were preserved.",
                effects: .none, owner: url(dataRoot).path, instruction: "Repair the saved Moment array and its read/write access before the next turn.", recovery: .repair)
        }
    }

    private static func read(_ dataRoot: URL, now: Date) throws -> [Moment] {
        let data: Data
        do { data = try Data(contentsOf: url(dataRoot)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let moments = try decoder.decode([Moment].self, from: data)
        return moments.filter { now.timeIntervalSince($0.at) < fades }
    }

    private static func write(_ dataRoot: URL, _ moments: [Moment]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(moments), to: url(dataRoot))
    }

    private static func unavailable(_ root: URL, _ error: Error) {
        RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: "mind.primed", owner: url(root).path,
            words: "Primed moments are unavailable: \(error.localizedDescription). Existing moments are preserved.",
            tap: ToolFailureError.fileRepairInstruction(url(root), shape: "Preserve the primed Moment array and repair its read/write access."))
    }
}
