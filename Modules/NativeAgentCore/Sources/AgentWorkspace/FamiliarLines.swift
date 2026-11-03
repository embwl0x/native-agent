import Foundation
import Synchronization
import PersistenceCore
import NativeAgentCore

// Blueprint: | `FamiliarLines.swift` | `FamiliarLines`: habituation — every line that passes through a moment is met (the last 16,384, `mind/familiar.bin`); only a line they meets for the first time can bring something to mind, so the app's standing words and their own coming back stop reminding their |

/// Habituation. What she has met before reminds her of nothing: the app's
/// standing words (a receipt's label, a page's note) and her own words coming
/// back repeat; what the world says does not. Numbers read as numbers, so
/// "called in at 14:36" is the same line at 15:02. The last `keep` lines she
/// met stay familiar.
public enum FamiliarLines {
    static let keep = 16_384
    /// Per data root: each line's key and when she last met it.
    private static let met = Mutex<(roots: [String: [UInt64: UInt64]], tick: UInt64)>(([:], 0))

    static func url(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("mind/familiar.bin")
    }

    /// The lines she meets for the first time, in order; all of them are met now.
    @discardableResult
    public static func firstMet(_ lines: some Sequence<String>, dataRoot: URL) throws -> [String] {
        do { return try met.withLock { state in
            var seen: [UInt64: UInt64]
            if let kept = state.roots[dataRoot.path] { seen = kept }
            else { seen = try read(dataRoot, tick: &state.tick) }
            var fresh: [String] = []
            for line in lines {
                state.tick += 1
                if seen.updateValue(state.tick, forKey: key(line)) == nil { fresh.append(line) }
            }
            // Forgetting goes in a batch, not a sort per line.
            if seen.count > keep + keep / 8 {
                for (key, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - keep) {
                    seen.removeValue(forKey: key)
                }
            }
            if !fresh.isEmpty { try write(dataRoot, seen) }
            state.roots[dataRoot.path] = seen
            return fresh
        } } catch {
            throw ToolFailureError("Familiarity could not be read or saved: \(error.localizedDescription). Saved keys were preserved.",
                effects: .none, owner: url(dataRoot).path, instruction: "Preserve the complete eight-byte key sequence and repair its read/write access.", recovery: .repair)
        }
    }

    static func key(_ line: String) -> UInt64 {
        line.lowercased()
            .replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// Oldest first, as written.
    private static func read(_ dataRoot: URL, tick: inout UInt64) throws -> [UInt64: UInt64] {
        let data: Data
        do { data = try Data(contentsOf: url(dataRoot)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
        guard data.count.isMultiple(of: MemoryLayout<UInt64>.size) else { throw CocoaError(.fileReadCorruptFile) }
        let keys: [UInt64] = data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 8).map { raw.loadUnaligned(fromByteOffset: $0, as: UInt64.self) }
        }
        var seen: [UInt64: UInt64] = [:]
        for key in keys {
            tick += 1
            seen[key] = tick
        }
        return seen
    }

    private static func write(_ dataRoot: URL, _ seen: [UInt64: UInt64]) throws {
        var data = Data(capacity: seen.count * 8)
        for (key, _) in seen.sorted(by: { $0.value < $1.value }) {
            withUnsafeBytes(of: key) { data.append(contentsOf: $0) }
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url(dataRoot))
    }
}
