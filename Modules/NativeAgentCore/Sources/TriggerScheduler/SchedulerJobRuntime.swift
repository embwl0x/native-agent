import Foundation

// Blueprint: | `SchedulerJobRuntime.swift` | `SchedulerJobRuntime`: a civil minute's identity, which no zone change can repeat |

public enum SchedulerJobRuntime {
    /// Civil identity deliberately has no offset: changing zones cannot create another occurrence.
    public static func occurrence(at date: Date, zone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }
}
