import Foundation

/// Compact duration wording shared by Mac and iOS presentation.
public enum CompactDurationFormatter {
    public static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        // Round once, then branch — 59.5 must roll into "1m", not print "60s".
        // Refuse durations outside Int's range instead of trapping during conversion.
        guard let total = Int(exactly: seconds.rounded()) else { return "" }
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let s = total % 60
            return s == 0 ? "\(total / 60)m" : "\(total / 60)m \(s)s"
        }
        let m = (total % 3600) / 60
        return m == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(m)m"
    }
}
