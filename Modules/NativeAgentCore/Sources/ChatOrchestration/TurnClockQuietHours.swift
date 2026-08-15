import Foundation
import NativeAgentCore

/// The user's declared quiet-hours window, in LOCAL wall-clock hours.
/// `start > end` wraps midnight (19 → 3 means 7 PM through 3 AM).
///
/// W5 L1#6: the model was inferring "he must be asleep" from a bare clock
/// reading. The window is a FACT the turn can state instead of a guess it has
/// to make, so it rides the same one-line dynamic clock context.
public struct TurnQuietHoursWindow: Sendable, Equatable {
    public let startHour: Int
    public let endHour: Int

    public init?(startHour: Int, endHour: Int) {
        guard (0...23).contains(startHour), (0...23).contains(endHour),
              startHour != endHour else { return nil }
        self.startHour = startHour
        self.endHour = endHour
    }

    /// Whether a local wall-clock hour falls inside the window. Mirrors
    /// `SwiftNativeTriggerScheduler.inQuietHours` semantics deliberately: two
    /// different answers to "is it quiet right now" is exactly the shape that
    /// makes an agent contradict itself.
    public func contains(hour: Int) -> Bool {
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    /// `data/user_prefs.json` → `quiet_hours.{start,end}`. Absent file,
    /// absent key, or an out-of-range pair → nil (no quiet-hours clause is
    /// rendered; the clock line degrades to time + zone only).
    public static func read(dataRoot: URL) -> TurnQuietHoursWindow? {
        let url = dataRoot.appendingPathComponent("user_prefs.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quiet = root["quiet_hours"] as? [String: Any] else {
            return nil
        }
        guard let start = intValue(quiet["start"]), let end = intValue(quiet["end"]) else {
            return nil
        }
        return TurnQuietHoursWindow(startHour: start, endHour: end)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
