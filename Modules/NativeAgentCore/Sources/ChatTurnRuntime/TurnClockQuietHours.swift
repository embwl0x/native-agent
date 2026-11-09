import Transcripts
import Foundation
import PersistenceCore
import NativeAgentCore
import Experiences

// Blueprint: | `TurnClockQuietHours.swift` | `TurnQuietHoursWindow`; Checked local quiet hours shared with delivery |

/// Share local quiet-hour interpretation between context and delivery; start after end denotes a midnight-spanning window.
public struct TurnQuietHoursWindow: Sendable, Equatable {
    public let startHour: Int
    public let endHour: Int

    public init?(startHour: Int, endHour: Int) {
        guard (0...23).contains(startHour), (0...23).contains(endHour),
              startHour != endHour else { return nil }
        self.startHour = startHour
        self.endHour = endHour
    }

    /// Local-hour membership includes the start and excludes the end.
    public func contains(hour: Int) -> Bool {
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    /// Next local occurrence of the end hour, using the calendar's next valid time.
    public func end(after date: Date) -> Date? {
        var components = DateComponents()
        components.hour = endHour; components.minute = 0; components.second = 0
        return Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    /// Confirmed missing preferences or an absent window is unset; present damage is unavailable.
    public static func checkedRead(dataRoot: URL) throws -> TurnQuietHoursWindow? {
        do {
            let window = try readPreferences(dataRoot: dataRoot)
            if window != nil {
                RepairOwed.settle(dataRoot, operation: "clock.quiet_hours", evidence: .init(source: "user_prefs.json", id: "quiet_hours"))
            }
            return window
        } catch {
            reportUnavailable(error, dataRoot: dataRoot)
            throw error
        }
    }

    private static func readPreferences(dataRoot: URL) throws -> TurnQuietHoursWindow? {
        let url = dataRoot.appendingPathComponent("user_prefs.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        catch { throw unavailable(error.localizedDescription) }
        do {
            guard case .object(let root) = try JSONValue.parse(data) else { throw unavailable("The preferences are not an object.") }
            guard let value = root["quiet_hours"] else { return nil }
            guard case .object(let quiet) = value,
                  let start = intValue(quiet["start"]), let end = intValue(quiet["end"]),
                  let window = TurnQuietHoursWindow(startHour: start, endHour: end) else {
                throw unavailable("quiet_hours requires distinct integer start/end hours from 0 through 23.")
            }
            return window
        } catch let error as ToolFailureError { throw error }
        catch { throw unavailable(error.localizedDescription) }
    }

    private static func unavailable(_ reason: String) -> ToolFailureError {
        ToolFailureError("Quiet hours are unavailable: \(reason) Repair user_prefs.json so held deliveries can be decided.",
            effects: .none, owner: "user_prefs.json", code: "quiet_hours_unavailable", recovery: .repair)
    }

    private static func reportUnavailable(_ error: Error, dataRoot: URL) {
        RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run, operation: "clock.quiet_hours",
            owner: "user_prefs.json", words: error.localizedDescription,
            nextCall: ToolFailureError.call("app", ["action": .string("files.read"), "args": .object(["path": .string(dataRoot
                .appendingPathComponent("user_prefs.json").path)])]))
    }

    private static func intValue(_ raw: JSONValue?) -> Int? {
        guard case .int(let value)? = raw else { return nil }
        return Int(exactly: value)
    }
}
