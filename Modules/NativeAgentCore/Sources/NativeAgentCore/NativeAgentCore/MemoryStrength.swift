import Foundation

// Blueprint: | `MemoryStrength.swift` | Five-minute feedback buckets and checked ACT-R use reachability |

public enum MemoryStrength {
    public static func bucket(for date: Date) -> Int64? {
        Int64(exactly: (date.timeIntervalSince1970 / 300).rounded(.towardZero))
    }

    public static func reachability(useBuckets: [Int64], at now: Int64) -> Double? {
        var odds = 1.0
        for use in useBuckets {
            let (elapsed, overflow) = now.subtractingReportingOverflow(use)
            guard !overflow else { return nil }
            odds += pow(Double(max(1, elapsed)) / 288, -0.5)
        }
        return odds / (1 + odds)
    }
}
