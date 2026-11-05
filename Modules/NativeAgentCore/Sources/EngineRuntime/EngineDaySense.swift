import Cognition
import Connectors
import Foundation
@preconcurrency import EventKit
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import TrustCenter

// Blueprint: | `EngineDaySense.swift` | Clock-driven day perception with authorized calendar titles and care rest |

extension CognitionHost {
    public func perceiveDay(dataRoot: URL) async {
        // Only the installed mind perceives the person's Mac.
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else { return }
        await EngineDaySense.post(dataRoot: dataRoot)
    }
}

@MainActor
enum EngineDaySense {
    private static var posting = false

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }

    static func formatter(_ format: String) -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = calendar
        value.timeZone = calendar.timeZone
        value.dateFormat = format
        return value
    }

    static func dayKey(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }

    static func post(dataRoot: URL) async {
        guard !posting, !Task.isCancelled, let crossing = SensesHub.shared.crossing else { return }
        posting = true
        defer { posting = false }
        do {
            let start = calendar.startOfDay(for: Date())
            let stamp = ISO8601DateFormatter().string(from: start)
            let path = dataRoot.appendingPathComponent("mind/day-posted")
            let previous: String?
            do { previous = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            catch CocoaError.fileReadNoSuchFile { previous = nil }
            if let previous {
                guard ISO8601DateFormatter().date(from: previous) != nil else { throw CocoaError(.fileReadCorruptFile) }
                if previous == stamp { return }
            }
            let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
                "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth",
                "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "twenty-first",
                "twenty-second", "twenty-third", "twenty-fourth", "twenty-fifth", "twenty-sixth",
                "twenty-seventh", "twenty-eighth", "twenty-ninth", "thirtieth", "thirty-first"]
            let day = calendar.component(.day, from: start)
            var line = "It's \(formatter("EEEE").string(from: start)) the \(ordinals[day - 1]) of \(formatter("MMMM").string(from: start))."
            do {
                let agenda = try await calendarWords(dataRoot: dataRoot, start: start)
                // A day or zone change during the calendar read belongs to the next buffered invalidation.
                guard !Task.isCancelled, start == calendar.startOfDay(for: Date()) else { return }
                if let agenda, try await calendarAllowed(dataRoot: dataRoot) { line += agenda }
            } catch is CancellationError {
                return
            } catch {
                nativeLog("Day calendar unavailable: %@", error.localizedDescription)
                line += " The calendar is unavailable: \(error.localizedDescription)"
            }
            guard !Task.isCancelled, start == calendar.startOfDay(for: Date()) else { return }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data((stamp + "\n").utf8), to: path)
            _ = await crossing.cross(line, watch: "clock:day", reason: "the day came round",
                                     id: "clock:day:" + dayKey(start), says: line, agent: nil)
        } catch is CancellationError {
            return
        } catch {
            nativeLog("Day perception unavailable: %@", error.localizedDescription)
        }
    }

    private static func calendarAllowed(dataRoot: URL) async throws -> Bool {
        guard try await MacIntegrationPermissionStore(dataRoot: dataRoot).allows(
            MacIntegrationID.calendar, mode: .read
        ) else { return false }
        return LocalPIMConnectorActions.authorizationAllowsRead(EKEventStore.authorizationStatus(for: .event))
    }

    private static func calendarWords(dataRoot: URL, start: Date) async throws -> String? {
        guard try await calendarAllowed(dataRoot: dataRoot),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        var remaining = 6
        var days: [String] = []
        for (label, date) in [("today", start), ("tomorrow", tomorrow)] {
            guard remaining > 0 else { break }
            try Task.checkCancellation()
            guard try await calendarAllowed(dataRoot: dataRoot) else { return nil }
            var words: [String] = []
            let result = try await LocalPIMConnectorActions.calendarListUpcoming(input: [
                "day": .string(dayKey(date)), "limit": .int(Int64(remaining))
            ], titlesOnly: true, handsBack: true)
            guard case .array(let events)? = result.objectValue?["events"] else {
                throw CocoaError(.fileReadNoPermission)
            }
            for event in events.prefix(remaining) {
                guard let row = event.objectValue, let title = row["title"]?.stringValue else { continue }
                if row["allDay"] == .bool(true) {
                    // Deduplicate a shared holiday across calendars.
                    if !words.contains(title) { words.append(title) }
                } else if let raw = row["startAt"]?.stringValue,
                          let date = ISO8601DateFormatter().date(from: raw) {
                    let timed = formatter("HH:mm").string(from: date) + " " + title
                    if !words.contains(timed) { words.append(timed) }
                }
            }
            remaining -= words.count
            days.append(label + ": " + (words.isEmpty ? "nothing scheduled" : words.joined(separator: ", ")))
        }
        return days.isEmpty ? nil : " On the calendar " + days.joined(separator: "; ") + "."
    }
}
