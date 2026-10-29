import AuthoredCapabilities
import Foundation
@preconcurrency import EventKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import MacIntegration
import ToolExecution
// Blueprint: | `LocalPIMConnectorActions+Calendar.swift` | Calendar CRUD, bounded event snapshots and calendar day/range interpretation on the existing LocalPIMStore |

extension LocalPIMConnectorActions {
    struct CalendarListWindow: Equatable, Sendable {
        let start: Date
        let end: Date
        let hoursAhead: Int
        let day: String?
    }

    public static func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        let window = try calendarListWindow(input: input)
        let store = LocalPIMStore()
        let granted = try await store.requestCalendarAccess(.read)
        try Task.checkCancellation()
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.calendar_list_upcoming",
                source: "calendar",
                status: calendarAuthorizationState()
            )
        }

        let limit = MacAppleScriptBridge.clampedInt(input["limit"] ?? input["max"], defaultValue: 20, min: 1, max: 100)
        let calendarName = (input["calendar_name"] ?? input["calendarName"])?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarID = input["calendar_id"]?.scalarText
        if let calendarID, !store.calendars(for: .event).contains(where: { $0.calendarIdentifier == calendarID }) {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("Unknown calendar_id.")])
        }
        let events = try await upcomingEventRows(window: window, calendarName: calendarName, calendarID: calendarID,
            query: input["query"]?.scalarText ?? "", limit: limit)

        var payload: [String: JSONValue] = [
            "status": .string("completed"),
            "actionId": .string("mac.calendar_list_upcoming"),
            "source": .string("eventkit"),
            "access": .string(calendarAuthorizationState()),
            "rangeStart": .string(iso(window.start)),
            "rangeEnd": .string(iso(window.end)),
            "timeZone": .string(TimeZone.current.identifier),
            "count": .int(Int64(events.count)),
            "events": .array(Array(events)),
        ]
        // One window, said once: a day or range names itself; hours only when hours were the ask.
        if let day = window.day {
            payload["day"] = .string(day)
        } else {
            payload["hoursAhead"] = .int(Int64(window.hoursAhead))
        }
        return .object(payload)
    }

    /// Read EventKit off-actor in its own store; cancellation still awaits enumeration and returns its JSON.
    nonisolated private static func upcomingEventRows(
        window: CalendarListWindow,
        calendarName: String?,
        calendarID: String?,
        query: String,
        limit: Int
    ) async throws -> [JSONValue] {
        try Task.checkCancellation()
        let read = Task.detached(priority: .userInitiated) { () throws -> [JSONValue] in
            try Task.checkCancellation()
            let calendarMatches: (@Sendable (String) -> Bool)? = calendarName.flatMap { name in
                guard !name.isEmpty else { return nil }
                let needle = name.lowercased()
                return { $0.lowercased().contains(needle) }
            }
            let rows = LocalPIMStore.withEvents(start: window.start, end: window.end, calendarIDs: calendarID.map { [$0] }, calendarMatches: calendarMatches) { events, _ -> [JSONValue] in
                return events
                    .filter { query.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(query)
                        || ($0.notes ?? "").localizedCaseInsensitiveContains(query) }
                    .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                    .prefix(limit)
                    .map { eventJSON($0) }
            }
            return rows
        }
        return try await withTaskCancellationHandler {
            try await settle { await read.result }.get()
        } onCancel: { read.cancel() }
    }

    public static func calendarCalendars(input: [String: JSONValue]) async throws -> JSONValue {
        let store = LocalPIMStore()
        guard try await store.requestCalendarAccess(.read) else {
            return permissionEnvelope(actionId: "mac.calendar_calendars", source: "calendar", status: calendarAuthorizationState())
        }
        return .object(["status": .string("completed"), "calendars": .array(store.calendars(for: .event).map {
            .object(["calendarId": .string($0.calendarIdentifier), "title": .string($0.title),
                     "source": .string($0.source.title), "writable": .bool($0.allowsContentModifications)])
        })])
    }

    public static func calendarFreeBusy(input: [String: JSONValue]) async throws -> JSONValue {
        // calendar_ids omitted means every calendar on this Mac.
        let values: [JSONValue]
        switch input["calendar_ids"] {
        case nil, .null?: values = []
        case .array(let given)?: values = given
        default: values = [.null]
        }
        guard values.count <= 50, values.allSatisfy({ $0.scalarText?.isEmpty == false }),
              let start = parseInputDate(input["start"]), let end = parseInputDate(input["end"]),
              end > start, end.timeIntervalSince(start) <= 31 * 86_400 else {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("Provide a valid start/end window of at most 31 days, and optionally up to 50 exact calendar_ids (omit for all calendars).")])
        }
        let store = LocalPIMStore()
        guard try await store.requestCalendarAccess(.read) else {
            return permissionEnvelope(actionId: "mac.calendar_free_busy", source: "calendar", status: calendarAuthorizationState())
        }
        try Task.checkCancellation()
        let calendars = store.calendars(for: .event)
        let titles = Dictionary(calendars.map { ($0.calendarIdentifier, $0.title) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let calendarIDs = values.isEmpty ? calendars.map(\.calendarIdentifier) : values.compactMap { $0.scalarText }.filter { seen.insert($0).inserted }
        let unknown = calendarIDs.filter { titles[$0] == nil }
        guard unknown.isEmpty else {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("Unknown calendar_id: \(unknown.joined(separator: ", ")). Omit calendar_ids to check every calendar.")])
        }
        let read = Task.detached(priority: .userInitiated) { () throws -> [JSONValue] in
            try Task.checkCancellation()
            return LocalPIMStore.withEvents(start: start, end: end, calendarIDs: calendarIDs, calendarMatches: nil) { events, observedCalendarIDs -> [JSONValue] in
                let byCalendar = Dictionary(grouping: events.filter { $0.status != .canceled && $0.availability != .free }, by: { $0.calendar.calendarIdentifier })
                return calendarIDs.map { calendarID -> JSONValue in
                    let intervals = byCalendar[calendarID] ?? []
                    let unknown = !observedCalendarIDs.contains(calendarID)
                        || intervals.contains { eventAvailability($0.availability) == "unknown" || $0.startDate == nil || $0.endDate == nil }
                    return .object(["calendarId": .string(calendarID), "calendar": .string(titles[calendarID] ?? ""),
                        "availability": .string(unknown ? "unknown" : intervals.isEmpty ? "free" : "busy"),
                        "intervals": .array(intervals.map { event in .object([
                            "start": event.startDate.map { .string(iso(max(start, $0))) } ?? .null,
                            "end": event.endDate.map { .string(iso(min(end, $0))) } ?? .null,
                            "timeZone": .string(TimeZone.current.identifier),
                            "availability": .string(eventAvailability(event.availability))]) })])
                }
            }
        }
        let rows = try await withTaskCancellationHandler {
            try await settle { await read.result }.get()
        } onCancel: { read.cancel() }
        return .object(["status": .string("completed"), "scope": .string("local_events"), "start": .string(iso(start)), "end": .string(iso(end)), "timeZone": .string(TimeZone.current.identifier), "calendars": .array(rows)])
    }

    public static func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        let store = LocalPIMStore()
        let granted = try await store.requestCalendarAccess(.write)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.calendar_create_event",
                source: "calendar",
                status: calendarAuthorizationState(), mode: .write
            )
        }

        guard let title = input["title"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("Missing required field: title"),
            ])
        }
        guard let startDate = parseInputDate(input["start"]) else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("start needs a time like 2026-09-25T15:00 (local), one with Z or an offset, or epoch seconds."),
            ])
        }
        let endDate = parseInputDate(input["end"]) ?? startDate.addingTimeInterval(3600)
        guard endDate > startDate, input["end"] == nil || parseInputDate(input["end"]) != nil else {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("end must be a valid time after start.")])
        }
        let notes = input["notes"]?.scalarText
        let location = input["location"]?.scalarText
        let calendarNameField = input["calendar_name"] ?? input["calendarName"]
        let calendarName = calendarNameField?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if input["calendar_id"] != nil, input["calendar_id"]?.scalarText?.isEmpty != false {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("Unknown calendar_id.")])
        }
        let calendarNameSupplied: Bool = {
            guard let calendarNameField else { return false }
            if case .null = calendarNameField { return false }
            return true
        }()
        if calendarNameSupplied, (calendarName ?? "").isEmpty {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("Choose an explicit calendar_id or a unique exact calendar_name."),
            ])
        }

        let isWriteOnly = LocalPIMStore.calendarIsWriteOnly
        let pickedCalendar: EKCalendar?
        if let calendarID = input["calendar_id"]?.scalarText, !calendarID.isEmpty {
            let calendars = isWriteOnly ? store.defaultCalendarForNewEvents.map { [$0] } ?? [] : store.calendars(for: .event)
            guard let matched = calendars.first(where: { $0.calendarIdentifier == calendarID }),
                  calendarName == nil || matched.title.caseInsensitiveCompare(calendarName!) == .orderedSame else {
                return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("calendar_id is unavailable or does not match calendar_name.")])
            }
            pickedCalendar = matched
        } else if isWriteOnly {
            guard input["calendar_id"] == nil || input["calendar_id"] == .null else {
                return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("calendar_id is unavailable or does not match calendar_name.")])
            }
            if let calendarName, !calendarName.isEmpty {
                return .object([
                    "status": .string("failed"),
                    "effects": .string("none"),
                    "actionId": .string("mac.calendar_create_event"),
                    "reason": .string(
                        "calendar_name '\(calendarName)' cannot be honoured: Calendar access is "
                        + "write-only, so calendars cannot be enumerated. Omit calendar_name to "
                        + "use the default calendar, or grant full Calendar access."
                    ),
                ])
            }
            pickedCalendar = store.defaultCalendarForNewEvents
        } else if let calendarName, !calendarName.isEmpty {
            let calendars = store.calendars(for: .event)
            let matches = calendars.filter { $0.title.caseInsensitiveCompare(calendarName) == .orderedSame }
            guard matches.count == 1, let matched = matches.first else {
                return .object([
                    "status": .string("failed"),
                    "effects": .string("none"),
                    "actionId": .string("mac.calendar_create_event"),
                    "reason": .string("Calendar name is missing or ambiguous; choose an exact calendar_id."),
                    "available": .array(calendars.map { .object(["title": .string($0.title), "calendarId": .string($0.calendarIdentifier)]) }),
                ])
            }
            pickedCalendar = matched
        } else {
            pickedCalendar = store.defaultCalendarForNewEvents
        }
        guard let targetCalendar = pickedCalendar else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("No calendar available to write to"),
            ])
        }

        guard isWriteOnly || targetCalendar.allowsContentModifications else {
            return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("The selected calendar is read-only.")])
        }

        let event = store.makeEvent()
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        if let notes, !notes.isEmpty { event.notes = notes }
        if let location, !location.isEmpty { event.location = location }
        event.calendar = targetCalendar

        do {
            try store.save(event)
        } catch {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string(error.localizedDescription),
            ])
        }

        return .object([
            "status": .string("completed"),
            "actionId": .string("mac.calendar_create_event"),
            "source": .string("eventkit"),
            "eventId": .string(event.eventIdentifier ?? ""),
            "title": .string(title),
            "start": event.startDate.map { .string(iso($0)) } ?? .null,
            "end": event.endDate.map { .string(iso($0)) } ?? .null,
            "timeZone": .string(TimeZone.current.identifier),
            "calendar": .string(targetCalendar.title),
            "calendarId": .string(targetCalendar.calendarIdentifier),
            "usedDefaultCalendar": .bool(input["calendar_id"] == nil && !calendarNameSupplied),
            "invitations": .string("not_sent"),
        ])
    }

    struct CalendarModifyArguments {
        let id: String
        var title: String?
        var start: Date?
        var end: Date?
        var notes: String?
        var location: String?
        var fields: [String] = []
    }

    /// Resolve list-result and caller spellings once, for both pure parsing and execution.
    private static func calendarEventID(input: [String: JSONValue]) -> String? {
        for key in ["id", "event_id", "eventId"] {
            if let id = input[key]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                return id
            }
        }
        return nil
    }

    static func calendarModifyArguments(input: [String: JSONValue]) throws(CalendarArgumentError) -> CalendarModifyArguments {
        func invalid(_ reason: String) -> CalendarArgumentError {
            CalendarArgumentError(action: "mac.calendar_modify_event", reason: reason)
        }
        guard let id = calendarEventID(input: input) else {
            throw invalid("Missing required field: id")
        }
        var arguments = CalendarModifyArguments(id: id)
        if input.keys.contains("title") {
            guard let title = input["title"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                throw invalid("Invalid field: title (must be non-empty)")
            }
            arguments.title = title
            arguments.fields.append("title")
        }
        if input.keys.contains("start") {
            guard let start = parseInputDate(input["start"]) else {
                throw invalid("start needs a time like 2026-09-25T15:00 (local), one with Z or an offset, or epoch seconds.")
            }
            arguments.start = start
            arguments.fields.append("start")
        }
        if input.keys.contains("end") {
            guard let end = parseInputDate(input["end"]) else {
                throw invalid("end needs a time like 2026-09-25T16:00 (local), one with Z or an offset, or epoch seconds.")
            }
            arguments.end = end
            arguments.fields.append("end")
        }
        if input.keys.contains("notes") {
            arguments.notes = input["notes"]?.scalarText ?? ""
            arguments.fields.append("notes")
        }
        if input.keys.contains("location") {
            arguments.location = input["location"]?.scalarText ?? ""
            arguments.fields.append("location")
        }
        guard !arguments.fields.isEmpty else {
            throw invalid("Provide at least one of: title, start, end, notes, location")
        }
        return arguments
    }

    /// Modify only explicitly supplied fields on the exact event. Calendar membership is preserved; notes/location may be empty to clear them.
    public static func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        let arguments: CalendarModifyArguments
        do { arguments = try calendarModifyArguments(input: input) }
        catch { return error.result }
        let store = LocalPIMStore()
        // Modifying an event requires full access to read it first.
        let granted = try await store.requestCalendarAccess(.read)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.calendar_modify_event",
                source: "calendar",
                status: calendarAuthorizationState()
            )
        }

        guard let event = store.event(withIdentifier: arguments.id) else {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "actionId": .string("mac.calendar_modify_event"),
                "reason": .string("event_not_found"),
                "detail": .string("No calendar event has that id, so nothing changed. List the calendar for current ids."),
            ])
        }

        // Empty notes/location clears the field; absence leaves it alone.
        if let title = arguments.title { event.title = title }
        if let start = arguments.start { event.startDate = start }
        if let end = arguments.end { event.endDate = end }
        if let notes = arguments.notes { event.notes = notes }
        if let location = arguments.location { event.location = location }

        do {
            try store.save(event)
        } catch {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_modify_event"),
                "reason": .string(error.localizedDescription),
            ])
        }

        return .object([
            "status": .string("completed"),
            "actionId": .string("mac.calendar_modify_event"),
            "source": .string("eventkit"),
            "eventId": .string(event.eventIdentifier ?? arguments.id),
            "start": event.startDate.map { .string(iso($0)) } ?? .null,
            "end": event.endDate.map { .string(iso($0)) } ?? .null,
            "timeZone": .string(TimeZone.current.identifier),
            "fields_updated": .array(arguments.fields.map { .string($0) }),
        ])
    }

    /// Preconditions deliberately precede permission prompting and mutation.
    static func calendarDeleteExpectation(input: [String: JSONValue]) throws(CalendarArgumentError) -> (id: String, title: String, start: Date) {
        guard let id = calendarEventID(input: input), let title = input["expected_title"]?.scalarText,
              let start = parseInputDate(input["expected_start"]) else {
            throw CalendarArgumentError(action: "mac.calendar_delete_event",
                reason: "Provide exact id, expected_title, and expected_start from mac_calendar_list_upcoming.")
        }
        return (id, title, start)
    }

    static func calendarDeleteMatches(title: String?, start: Date?, expectedTitle: String, expectedStart: Date) -> Bool {
        guard let start else { return false }
        return (title ?? "") == expectedTitle && abs(start.timeIntervalSince(expectedStart)) < 1
    }

    public static func calendarDeleteEvent(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.calendar_delete_event"
        // Refusals before `remove` changed nothing; a failed remove reports itself.
        func failed(_ reason: String, effects: String = "none") -> JSONValue {
            .object(["status": .string("failed"), "actionId": .string(actionId), "effects": .string(effects), "reason": .string(reason)])
        }
        let expected: (id: String, title: String, start: Date)
        do { expected = try calendarDeleteExpectation(input: input) }
        catch { return error.result }
        let store = LocalPIMStore()
        guard try await store.requestCalendarAccess(.read) else {
            return permissionEnvelope(actionId: actionId, source: "calendar", status: calendarAuthorizationState())
        }
        guard let event = store.event(withIdentifier: expected.id) else {
            return failed("event_not_found")
        }
        guard calendarDeleteMatches(title: event.title, start: event.startDate,
                                    expectedTitle: expected.title, expectedStart: expected.start) else {
            return failed("event_changed: refresh the event and confirm the intended occurrence before retrying")
        }
        guard event.calendar.allowsContentModifications else { return failed("calendar_read_only") }
        do {
            try store.remove(event)
        } catch {
            return failed(error.localizedDescription, effects: "unknown")
        }
        return .object([
            "status": .string("completed"), "actionId": .string(actionId),
            "source": .string("eventkit"), "eventId": .string(expected.id),
            "scope": .string("this_event"),
        ])
    }

    static func filteredCalendars(_ calendars: [EKCalendar], matching name: String?) -> [EKCalendar]? {
        guard let name, !name.isEmpty else { return nil }
        let needle = name.lowercased()
        let filtered = calendars.filter { $0.title.lowercased().contains(needle) }
        return filtered.isEmpty ? [] : filtered
    }


    nonisolated private static func eventAvailability(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .free: "free"
        case .busy: "busy"
        case .tentative: "tentative"
        case .unavailable: "unavailable"
        default: "unknown"
        }
    }

    nonisolated private static func eventJSON(_ event: EKEvent) -> JSONValue {
        var obj: [String: JSONValue] = [
            // Event identifiers let callers modify listed events.
            "id": .string(event.eventIdentifier ?? ""),
            "title": .string(NativeAppSecretRedactor.redactText(event.title ?? "(Untitled event)")),
            "calendar": .string(event.calendar.title),
            "calendarId": .string(event.calendar.calendarIdentifier),
            "availability": .string(eventAvailability(event.availability)),
            "allDay": .bool(event.isAllDay),
            "timeZone": .string(TimeZone.current.identifier),
        ]
        if let start = event.startDate { obj["startAt"] = .string(iso(start)) }
        if let end = event.endDate { obj["endAt"] = .string(iso(end)) }
        if let location = event.location, !location.isEmpty {
            obj["location"] = .string(NativeAppSecretRedactor.redactText(location))
        }
        if let notes = event.notes, !notes.isEmpty {
            obj["notesPreview"] = .string(NativeAppSecretRedactor.redactText(String(notes.prefix(300))))
        }
        return .object(obj)
    }

    static func calendarListWindow(
        input: [String: JSONValue],
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> CalendarListWindow {
        var input = input
        // days:N spans the next N days; day names one calendar day.
        if input["range"] == nil, let days = input["days"]?.scalarText.flatMap({ Int($0) }), (1...30).contains(days) {
            input["range"] = .string("next \(days) days")
        }
        if let range = input["range"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: " "), !range.isEmpty {
            // Next week spans its calendar week.
            if range == "next week", let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
               let next = calendar.dateInterval(of: .weekOfYear, for: thisWeek.end) {
                return CalendarListWindow(start: next.start, end: next.end,
                    hoursAhead: max(1, Int(ceil(next.end.timeIntervalSince(now) / 3600))), day: nil)
            }
            if range == "today" || range == "tomorrow",
               let scoped = calendarDayWindow(range, now: now, calendar: calendar) {
                return CalendarListWindow(start: scoped.start, end: scoped.end,
                    hoursAhead: max(1, Int(ceil(scoped.end.timeIntervalSince(scoped.start) / 3600))), day: scoped.label)
            }
            let end: Date?
            let words = range.split(separator: " ")
            if range == "this week" { end = calendar.dateInterval(of: .weekOfYear, for: now)?.end }
            else if words.count == 3, words[0] == "next", ["day", "days"].contains(words[2]),
                    let days = Int(words[1]), (1...30).contains(days) {
                end = calendar.date(byAdding: .day, value: days, to: now)
            } else { end = nil }
            guard let end else {
                throw NSError(domain: "NativeAgentCalendar", code: -400, userInfo: [
                    NSLocalizedDescriptionKey: "range must be today, tomorrow, this week, next week, or next N days (1–30)."])
            }
            return CalendarListWindow(start: now, end: end,
                hoursAhead: max(1, Int(ceil(end.timeIntervalSince(now) / 3600))), day: nil)
        }
        let hoursAhead = MacAppleScriptBridge.clampedInt(
            input["hours_ahead"] ?? input["hoursAhead"],
            defaultValue: 24,
            min: 1,
            max: 24 * 30
        )
        let dayValue =
            input["day"] ??
                input["date"] ??
                input["date_scope"] ??
                input["dateScope"]
        if let dayValue {
            guard let dayRaw = dayValue.scalarText,
                  let scoped = calendarDayWindow(dayRaw, now: now, calendar: calendar) else {
                throw NSError(domain: "NativeAgentCalendar", code: -400, userInfo: [
                    NSLocalizedDescriptionKey: "day must be today, tomorrow, or an exact calendar date (YYYY-MM-DD)."])
            }
            let hours = max(1, Int(ceil(scoped.end.timeIntervalSince(scoped.start) / 3600)))
            return CalendarListWindow(
                start: scoped.start,
                end: scoped.end,
                hoursAhead: hours,
                day: scoped.label
            )
        }

        let end = calendar.date(byAdding: .hour, value: hoursAhead, to: now) ??
            now.addingTimeInterval(TimeInterval(hoursAhead) * 3600)
        return CalendarListWindow(start: now, end: end, hoursAhead: hoursAhead, day: nil)
    }

    private static func calendarDayWindow(
        _ raw: String,
        now: Date,
        calendar: Calendar
    ) -> (label: String, start: Date, end: Date)? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dayStart: Date
        let label: String
        switch lower {
        case "today":
            dayStart = calendar.startOfDay(for: now)
            label = "today"
        case "tomorrow":
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            dayStart = tomorrow
            label = "tomorrow"
        default:
            let fields = lower.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.map(\.count) == [4, 2, 2],
                  fields.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
            let parts = fields.compactMap { Int($0) }
            guard parts.count == 3, (1...9999).contains(parts[0]),
                  (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
            var comps = DateComponents()
            comps.calendar = calendar
            comps.timeZone = calendar.timeZone
            comps.year = parts[0]
            comps.month = parts[1]
            comps.day = parts[2]
            guard let parsed = calendar.date(from: comps) else { return nil }
            let actual = calendar.dateComponents([.year, .month, .day], from: parsed)
            guard actual.year == comps.year, actual.month == comps.month, actual.day == comps.day else { return nil }
            dayStart = calendar.startOfDay(for: parsed)
            label = String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
        }

        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }
        return (label, dayStart, nextDay.addingTimeInterval(-1))
    }
}
