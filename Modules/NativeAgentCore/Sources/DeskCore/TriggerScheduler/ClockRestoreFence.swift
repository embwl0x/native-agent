import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ClockRestoreFence.swift` | `ClockRestoreFence`: a restored clock keeps each time's current next occurrence, so a restore never repeats one |

public enum ClockRestoreFence {
    /// Called before the live owners exist. Keep later shared next occurrences and all consumption evidence, including ended one-shots that are
    /// absent from the restored selection. Current-only pending work is not imported; its consumed occurrence remains as an ended time.
    public static func merge(safetyRoot: URL, destinationRoot: URL) throws -> [String] {
        let relative = "clock/times.json"
        let current = try read(safetyRoot.appendingPathComponent(relative)) ?? []
        _ = try OneClock.keyed(current)
        let destination = destinationRoot.appendingPathComponent(relative)
        let restored = try read(destination) ?? []
        let original = try OneClock.keyed(restored)
        var merged = original
        for time in current where time.isPending || time.delivered != nil {
            guard var kept = merged[time.id] else {
                guard let delivered = time.delivered else { continue }
                var ended = time
                ended.next = delivered
                ended.ended = true
                merged[time.id] = ended
                continue
            }
            if let delivered = time.delivered,
               kept.delivered.map({ $0 < delivered }) ?? true {
                kept.delivered = delivered
            }
            if kept.isPending {
                kept.next = max(kept.next, time.next)
                if let delivered = kept.delivered, kept.next <= delivered {
                    kept.next = delivered
                    kept.ended = true
                }
            } else if let delivered = kept.delivered {
                kept.next = delivered
            }
            merged[time.id] = kept
        }
        guard merged != original else { return [] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(merged.values.sorted { $0.id < $1.id }), to: destination)
        return []
    }

    private static func read(_ url: URL) throws -> [OneClock.Time]? {
        do { return try JSONDecoder().decode([OneClock.Time].self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
}
