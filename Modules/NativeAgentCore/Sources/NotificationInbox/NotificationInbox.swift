import Foundation
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `NotificationInbox.swift` | `NotificationInboxClock` |

public enum NotificationInboxClock {
    /// UTC offset timestamp, with six fractional digits unless microseconds are zero.
    public static func nowISO(_ date: Date = Date()) -> String {
        NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(date)
    }
}
