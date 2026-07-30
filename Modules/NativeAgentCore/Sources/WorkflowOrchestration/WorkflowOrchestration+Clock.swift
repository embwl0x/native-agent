import Foundation
import CryptoKit
import ApprovalInbox
import MCPDispatcher
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Research
import SystemOps

// MARK: - ISO clock (mirror now_iso)

public enum WorkflowOrchestrationClock {
    /// Mirrors Python's `now_iso()` = `datetime.now(timezone.utc).isoformat()`,
    /// which emits SIX fractional digits (microseconds) and a `+00:00` suffix,
    /// e.g. `2026-06-01T12:34:56.789012+00:00`. ISO8601DateFormatter only gives
    /// millisecond precision, so we build the string with a microsecond
    /// component derived from the Date's sub-second fraction (gpt-5.5 review
    /// finding #2, 2026-06-01).
    public static func nowISO() -> String {
        nowISO(from: Date())
    }

    /// Testable seam: format a specific Date the Python `isoformat()` way.
    public static func nowISO(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Microseconds from the fractional second of the timestamp.
        let frac = date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)
        let micros = min(999_999, Int((frac * 1_000_000).rounded(.toNearestOrEven)))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d+00:00",
            comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1,
            comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0,
            micros
        )
    }
}

// MARK: - Factory

public func makeWorkflowOrchestrationClient(root: URL) -> any WorkflowOrchestrationClient {
    return SwiftNativeWorkflowOrchestrationClient(root: root)
}
