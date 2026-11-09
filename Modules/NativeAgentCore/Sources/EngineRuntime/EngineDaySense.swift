import Cognition
import Connectors
import Experiences
import Foundation
@preconcurrency import EventKit
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

// Blueprint: | `EngineDaySense.swift` | Clock-driven day perception with authorized calendar titles, posted once per local day as a world happening |

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

    /// The day line is one happening per local day: its key is the date, so a second post the same day writes nothing.
    static func post(dataRoot: URL) async {
        guard !posting, !Task.isCancelled else { return }
        posting = true
        defer { posting = false }
        let start = calendar.startOfDay(for: Date())
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
        Attention.post(Happening(.world, subject: "clock:day", door: "clock:day", words: line, once: "clock:day:" + dayKey(start)), dataRoot: dataRoot)
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
