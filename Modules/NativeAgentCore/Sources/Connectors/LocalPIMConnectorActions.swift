import Foundation
import NativeAgentCore
import PersistenceCore
import Privacy
import MacIntegration

@MainActor
public enum LocalPIMConnectorActions<Store: LocalPIMStore> {
    struct CalendarListWindow: Equatable, Sendable {
        let start: Date
        let end: Date
        let hoursAhead: Int
        let day: String?
    }

    public static func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        let granted = try await store.requestCalendarAccess(.read)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.calendar_list_upcoming",
                source: "calendar",
                status: calendarAuthorizationState()
            )
        }

        let window = calendarListWindow(input: input)
        let limit = clampedInt(input["limit"] ?? input["max"], defaultValue: 20, min: 1, max: 100)
        let calendarName = inputString(input["calendar_name"] ?? input["calendarName"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarID = inputString(input["calendar_id"])
        if let calendarID, !store.calendars(for: .event).contains(where: { $0.calendarIdentifier == calendarID }) {
            return .object(["status": .string("failed"), "reason": .string("Unknown calendar_id.")])
        }
        let events = await upcomingEventRows(window: window, calendarName: calendarName, calendarID: calendarID, limit: limit)

        var payload: [String: JSONValue] = [
            "status": .string("completed"),
            "actionId": .string("mac.calendar_list_upcoming"),
            "source": .string("eventkit"),
            "access": .string(calendarAuthorizationState()),
            "hoursAhead": .int(Int64(window.hoursAhead)),
            "rangeStart": .string(iso(window.start)),
            "rangeEnd": .string(iso(window.end)),
            "count": .int(Int64(events.count)),
            "events": .array(Array(events)),
        ]
        if let day = window.day {
            payload["day"] = .string(day)
        }
        return .object(payload)
    }

    /// The EventKit read for `calendarListUpcoming`, off the main actor.
    ///
    /// 2026-09-06: `store.events(matching:)` is a synchronous enumeration, and
    /// running it (plus the sort over EVERY event in the window, before the
    /// limit) on `@MainActor` froze the UI for the length of the query. EventKit
    /// reads are safe off the main thread when the caller owns its own store
    /// instance — process-wide authorization is unchanged — so the query runs in
    /// a detached task and only the rendered JSON comes back.
    nonisolated private static func upcomingEventRows(
        window: CalendarListWindow,
        calendarName: String?,
        calendarID: String?,
        limit: Int
    ) async -> [JSONValue] {
        await Task.detached(priority: .userInitiated) { () -> [JSONValue] in
            let calendarMatches: (@Sendable (String) -> Bool)? = calendarName.flatMap { name in
                guard !name.isEmpty else { return nil }
                let needle = name.lowercased()
                return { $0.lowercased().contains(needle) }
            }
            return Store.withEvents(start: window.start, end: window.end, calendarIDs: calendarID.map { [$0] }, calendarMatches: calendarMatches) { events, _ in
                events
                    .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                    .prefix(limit)
                    .map { eventJSON($0) }
            }
        }.value
    }

    public static func calendarCalendars(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        guard try await store.requestCalendarAccess(.read) else {
            return permissionEnvelope(actionId: "mac.calendar_calendars", source: "calendar", status: calendarAuthorizationState())
        }
        return .object(["status": .string("completed"), "calendars": .array(store.calendars(for: .event).map {
            .object(["calendarId": .string($0.calendarIdentifier), "title": .string($0.title),
                     "source": .string($0.sourceTitle), "writable": .bool($0.allowsContentModifications)])
        })])
    }

    public static func calendarFreeBusy(input: [String: JSONValue]) async throws -> JSONValue {
        guard case .array(let values)? = input["calendar_ids"], !values.isEmpty, values.count <= 50,
              values.allSatisfy({ inputString($0)?.isEmpty == false }),
              let start = parseInputDate(input["start"]), let end = parseInputDate(input["end"]),
              end > start, end.timeIntervalSince(start) <= 31 * 86_400 else {
            return .object(["status": .string("failed"), "reason": .string("Provide 1-50 exact calendar_ids and a valid start/end window of at most 31 days.")])
        }
        let calendarIDs = values.compactMap { inputString($0) }
        guard Set(calendarIDs).count == calendarIDs.count else {
            return .object(["status": .string("failed"), "reason": .string("Unknown calendar_id.")])
        }
        let store = Store()
        guard try await store.requestCalendarAccess(.read) else {
            return permissionEnvelope(actionId: "mac.calendar_free_busy", source: "calendar", status: calendarAuthorizationState())
        }
        let available = Set(store.calendars(for: .event).map(\.calendarIdentifier))
        guard Set(calendarIDs).isSubset(of: available) else {
            return .object(["status": .string("failed"), "reason": .string("Unknown calendar_id; enumerate calendars before checking availability.")])
        }
        let rows = await Task.detached(priority: .userInitiated) {
            Store.withEvents(start: start, end: end, calendarIDs: calendarIDs, calendarMatches: nil) { events, observedCalendarIDs in
                calendarIDs.map { calendarID -> JSONValue in
                    let intervals = events.filter { $0.calendarIdentifier == calendarID && !$0.isCancelled && $0.availability != "free" }
                    let unknown = !observedCalendarIDs.contains(calendarID)
                        || intervals.contains { $0.availability == "unknown" || $0.startDate == nil || $0.endDate == nil }
                    return .object(["calendarId": .string(calendarID), "availability": .string(unknown ? "unknown" : intervals.isEmpty ? "free" : "busy"),
                        "intervals": .array(intervals.map { event in .object([
                            "start": event.startDate.map { .string(iso(max(start, $0))) } ?? .null,
                            "end": event.endDate.map { .string(iso(min(end, $0))) } ?? .null,
                            "availability": .string(event.availability)]) })])
                }
            }
        }.value
        return .object(["status": .string("completed"), "scope": .string("local_events"), "start": .string(iso(start)), "end": .string(iso(end)), "calendars": .array(rows)])
    }

    public static func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        let granted = try await store.requestReminderAccess(allowPrompt: true)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_list_due_today",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        let includeCompleted = inputBool(input["include_completed"] ?? input["includeCompleted"], defaultValue: false)
        let limit = clampedInt(input["limit"] ?? input["max"], defaultValue: 50, min: 1, max: 200)
        let listName = inputString(input["list_name"] ?? input["listName"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendars = filteredCalendars(
            store.calendars(for: .reminder),
            matching: listName
        )
        let endOfToday = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date().addingTimeInterval(24 * 3600)
        guard let reminders = await fetchDueReminderJSON(
            store: store,
            calendars: calendars,
            includeCompleted: includeCompleted,
            endOfToday: endOfToday,
            limit: limit
        ) else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_list_due_today"),
                "reason": .string("Reminders read is unavailable."),
            ])
        }

        return .object([
            "status": .string("completed"),
            "actionId": .string("mac.reminders_list_due_today"),
            "source": .string("eventkit"),
            "access": .string(reminderAuthorizationState()),
            "includeCompleted": .bool(includeCompleted),
            "count": .int(Int64(reminders.count)),
            "reminders": .array(Array(reminders)),
        ])
    }

    public static func remindersQuery(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_query"
        let start = parseInputDate(input["due_start"])
        let end = parseInputDate(input["due_end"])
        let undatedOnly = inputBool(input["undated_only"], defaultValue: false)
        guard (input["due_start"] == nil || start != nil),
              (input["due_end"] == nil || end != nil),
              !(undatedOnly && (start != nil || end != nil)),
              start == nil || end == nil || start! < end! else {
            return .object(["status": .string("failed"), "actionId": .string(actionId),
                "reason": .string("Provide valid due_start/due_end with start before end; undated_only cannot be combined with a due range.")])
        }
        let store = Store()
        guard try await store.requestReminderAccess(allowPrompt: true) else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        let includeCompleted = inputBool(input["include_completed"], defaultValue: false)
        let query = inputString(input["query"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let listName = inputString(input["list_name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendars = filteredCalendars(store.calendars(for: .reminder), matching: listName)
        let offset = clampedInt(input["offset"], defaultValue: 0, min: 0, max: Int.max)
        let limit = clampedInt(input["limit"], defaultValue: 20, min: 1, max: 100)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(in: calendars, incompleteOnly: !includeCompleted) { reminders in
                guard let reminders else {
                    continuation.resume(returning: .object(["status": .string("failed"), "actionId": .string(actionId),
                        "reason": .string("Reminders read is unavailable.")]))
                    return
                }
                let matching = reminders.filter { reminder in
                    if !includeCompleted && reminder.isCompleted { return false }
                    if let listName, !listName.isEmpty, !reminder.calendarTitle.localizedCaseInsensitiveContains(listName) { return false }
                    if !query.isEmpty && !(reminder.title ?? "").localizedCaseInsensitiveContains(query)
                        && !(reminder.notes ?? "").localizedCaseInsensitiveContains(query) { return false }
                    let due = reminder.dueDateComponents?.date
                    if undatedOnly { return due == nil }
                    if start != nil || end != nil {
                        guard let due else { return false }
                        if let start, due < start { return false }
                        if let end, due >= end { return false }
                    }
                    return true
                }.sorted {
                    let left = $0.dueDateComponents?.date ?? .distantFuture
                    let right = $1.dueDateComponents?.date ?? .distantFuture
                    return left == right ? $0.calendarItemIdentifier < $1.calendarItemIdentifier : left < right
                }
                let rows = matching.dropFirst(offset).prefix(limit).map { Self.reminderJSON($0) }
                let next = offset + rows.count
                continuation.resume(returning: .object([
                    "status": .string("completed"), "actionId": .string(actionId), "source": .string("eventkit"),
                    "includeCompleted": .bool(includeCompleted), "count": .int(Int64(rows.count)),
                    "total": .int(Int64(matching.count)), "offset": .int(Int64(offset)),
                    "next_offset": next < matching.count ? .int(Int64(next)) : .null,
                    "reminders": .array(rows),
                ]))
            }
        }
    }

    public static func remindersRead(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_read"
        guard let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return .object(["status": .string("failed"), "actionId": .string(actionId), "reason": .string("Provide an exact reminder id.")])
        }
        let store = Store()
        guard try await store.requestReminderAccess(allowPrompt: true) else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        guard let reminder = store.reminder(withIdentifier: id) else {
            return .object(["status": .string("failed"), "actionId": .string(actionId), "reason": .string("The exact reminder was not found.")])
        }
        return .object(["status": .string("completed"), "actionId": .string(actionId), "source": .string("eventkit"),
            "reminder": liveReminderJSON(reminder)])
    }

    private struct ReminderUpdateArguments {
        let id: String
        var title: String?
        var notes: String?
        var due: DateComponents?
        var changesDue = false
    }

    private static func reminderUpdateArguments(input: [String: JSONValue]) throws(CalendarArgumentError) -> ReminderUpdateArguments {
        func invalid(_ reason: String) -> CalendarArgumentError { .init(action: "mac.reminders_update", reason: reason) }
        guard case .string(let rawID)? = input["id"], !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("Provide an exact reminder id.")
        }
        var arguments = ReminderUpdateArguments(id: rawID.trimmingCharacters(in: .whitespacesAndNewlines))
        var cleared: Set<String> = []
        if let raw = input["clear_fields"] {
            guard case .array(let fields) = raw else { throw invalid("clear_fields must be an array containing only notes or due_date.") }
            for field in fields {
                guard case .string(let name) = field, ["notes", "due_date"].contains(name) else {
                    throw invalid("clear_fields must be an array containing only notes or due_date.")
                }
                cleared.insert(name)
            }
        }
        if let raw = input["title"] {
            guard case .string(let title) = raw, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("title must be a nonempty string.")
            }
            arguments.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let raw = input["notes"] {
            guard case .string(let notes) = raw else { throw invalid("notes must be a string; use clear_fields to remove them.") }
            guard !cleared.contains("notes") || notes.isEmpty else { throw invalid("Do not both set and clear notes.") }
            arguments.notes = notes
        }
        if cleared.contains("notes") { arguments.notes = "" }
        if let raw = input["due_date"] {
            arguments.changesDue = true
            if raw != .string("") || !cleared.contains("due_date") {
                guard !cleared.contains("due_date") else { throw invalid("Do not both set and clear due_date.") }
                guard let due = parseInputDate(raw) else { throw invalid("due_date must be an ISO-8601 date or epoch seconds; use clear_fields to remove it.") }
                arguments.due = reminderDueComponents(from: due, input: raw)
            }
        }
        if cleared.contains("due_date") { arguments.changesDue = true }
        guard arguments.title != nil || arguments.notes != nil || arguments.changesDue else {
            throw invalid("Provide at least one of: title, notes, due_date, clear_fields.")
        }
        return arguments
    }

    public static func remindersUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_update"
        let arguments: ReminderUpdateArguments
        do { arguments = try reminderUpdateArguments(input: input) }
        catch { return error.result }
        let store = Store()
        guard try await store.requestReminderAccess(allowPrompt: true) else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        guard let reminder = store.reminder(withIdentifier: arguments.id) else {
            return .object(["status": .string("failed"), "actionId": .string(actionId), "reason": .string("The exact reminder was not found.")])
        }
        guard reminder.calendar.allowsContentModifications else {
            return .object(["status": .string("failed"), "actionId": .string(actionId), "reason": .string("The reminder list is read-only.")])
        }
        if let title = arguments.title { reminder.title = title }
        if let notes = arguments.notes { reminder.notes = notes }
        if arguments.changesDue {
            reminder.dueDateComponents = arguments.due
        }
        try Task.checkCancellation()
        do { try store.save(reminder) }
        catch {
            return .object(["status": .string("failed"), "actionId": .string(actionId), "reason": .string(error.localizedDescription)])
        }
        return .object(["status": .string("completed"), "actionId": .string(actionId), "source": .string("eventkit"),
            "reminderId": .string(reminder.calendarItemIdentifier), "reminder": liveReminderJSON(reminder)])
    }

    private static func liveReminderJSON(_ reminder: Store.Reminder) -> JSONValue {
        .object([
            "id": .string(reminder.calendarItemIdentifier),
            "title": .string(NativeAppSecretRedactor.redactText(reminder.title ?? "(Untitled reminder)")),
            "list": .string(reminder.calendar.title), "listId": .string(reminder.calendar.calendarIdentifier),
            "completed": .bool(reminder.isCompleted),
            "dueAt": reminder.dueDateComponents?.date.map { .string(iso($0)) } ?? .null,
            "completedAt": reminder.completionDate.map { .string(iso($0)) } ?? .null,
            "notes": .string(NativeAppSecretRedactor.redactText(reminder.notes ?? "")),
        ])
    }

    public static func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        let granted = try await store.requestCalendarAccess(.write)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.calendar_create_event",
                source: "calendar",
                status: calendarAuthorizationState()
            )
        }

        guard let title = inputString(input["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("Missing required field: title"),
            ])
        }
        guard let startDate = parseInputDate(input["start"]) else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("start needs a time like 2026-09-25T15:00 (local), one with Z or an offset, or epoch seconds."),
            ])
        }
        let endDate = parseInputDate(input["end"]) ?? startDate.addingTimeInterval(3600)
        guard endDate > startDate, input["end"] == nil || parseInputDate(input["end"]) != nil else {
            return .object(["status": .string("failed"), "reason": .string("end must be a valid time after start.")])
        }
        let notes = inputString(input["notes"])
        let location = inputString(input["location"])
        let calendarNameField = input["calendar_name"] ?? input["calendarName"]
        let calendarName = inputString(calendarNameField)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if input["calendar_id"] != nil, inputString(input["calendar_id"])?.isEmpty != false {
            return .object(["status": .string("failed"), "reason": .string("Unknown calendar_id.")])
        }
        let calendarNameSupplied: Bool = {
            guard let calendarNameField else { return false }
            if case .null = calendarNameField { return false }
            return true
        }()
        if calendarNameSupplied, (calendarName ?? "").isEmpty {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("Choose an explicit calendar_id or a unique exact calendar_name."),
            ])
        }

        let isWriteOnly = Store.calendarIsWriteOnly
        let pickedCalendar: Store.Calendar?
        if let calendarID = inputString(input["calendar_id"]), !calendarID.isEmpty {
            let calendars = isWriteOnly ? store.defaultCalendarForNewEvents.map { [$0] } ?? [] : store.calendars(for: .event)
            guard let matched = calendars.first(where: { $0.calendarIdentifier == calendarID }),
                  calendarName == nil || matched.title.caseInsensitiveCompare(calendarName!) == .orderedSame else {
                return .object(["status": .string("failed"), "reason": .string("calendar_id is unavailable or does not match calendar_name.")])
            }
            pickedCalendar = matched
        } else if isWriteOnly {
            guard input["calendar_id"] == nil || input["calendar_id"] == .null else {
                return .object(["status": .string("failed"), "reason": .string("calendar_id is unavailable or does not match calendar_name.")])
            }
            if let calendarName, !calendarName.isEmpty {
                return .object([
                    "status": .string("failed"),
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
                    "actionId": .string("mac.calendar_create_event"),
                    "reason": .string("Calendar name is missing or ambiguous; choose an exact calendar_id."),
                    "available": .array(calendars.map { .object(["title": .string($0.title), "calendarId": .string($0.calendarIdentifier)]) }),
                ])
            }
            pickedCalendar = matched
        } else {
            return .object(["status": .string("failed"), "reason": .string("Choose an explicit calendar_id or a unique exact calendar_name.")])
        }
        guard let targetCalendar = pickedCalendar else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("No calendar available to write to"),
            ])
        }

        guard isWriteOnly || targetCalendar.allowsContentModifications else {
            return .object(["status": .string("failed"), "reason": .string("The selected calendar is read-only.")])
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
            "start": .string(iso(startDate)),
            "end": .string(iso(endDate)),
            "calendar": .string(targetCalendar.title),
            "calendarId": .string(targetCalendar.calendarIdentifier),
            "invitations": .string("not_sent"),
        ])
    }

    private struct CalendarArgumentError: Error {
        let action: String
        let reason: String
        var result: JSONValue {
            .object(["status": .string("failed"), "actionId": .string(action), "reason": .string(reason)])
        }
    }

    private struct CalendarModifyArguments {
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
            if let id = inputString(input[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                return id
            }
        }
        return nil
    }

    private static func calendarModifyArguments(input: [String: JSONValue]) throws(CalendarArgumentError) -> CalendarModifyArguments {
        func invalid(_ reason: String) -> CalendarArgumentError {
            CalendarArgumentError(action: "mac.calendar_modify_event", reason: reason)
        }
        guard let id = calendarEventID(input: input) else {
            throw invalid("Missing required field: id")
        }
        var arguments = CalendarModifyArguments(id: id)
        if input.keys.contains("title") {
            guard let title = inputString(input["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
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
            arguments.notes = inputString(input["notes"]) ?? ""
            arguments.fields.append("notes")
        }
        if input.keys.contains("location") {
            arguments.location = inputString(input["location"]) ?? ""
            arguments.fields.append("location")
        }
        guard !arguments.fields.isEmpty else {
            throw invalid("Provide at least one of: title, start, end, notes, location")
        }
        return arguments
    }

    /// The executor's parsers, without constructing a store or requesting access.
    public static func argumentRefusal(tool: String, input: [String: JSONValue]) -> JSONValue? {
        do throws(CalendarArgumentError) {
            switch tool {
            case "mac_calendar_modify_event": _ = try calendarModifyArguments(input: input)
            case "mac_calendar_delete_event": _ = try calendarDeleteExpectation(input: input)
            case "mac_reminders_delete": _ = try reminderDeleteExpectation(input: input)
            case "mac_reminders_update": _ = try reminderUpdateArguments(input: input)
            default: break
            }
            return nil
        } catch {
            return error.result
        }
    }

    /// Modify only explicitly supplied fields on the exact event. Calendar
    /// membership is preserved; notes/location may be empty to clear them.
    public static func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        let arguments: CalendarModifyArguments
        do { arguments = try calendarModifyArguments(input: input) }
        catch { return error.result }
        let store = Store()
        // gpt-5.5 review NEEDS_FIX: modify requires READING the existing event
        // (`store.event(withIdentifier:)` is a read op), so `.writeOnly` users
        // can't actually fetch it. Require full access for modify (vs the
        // write-only-tolerant path that create uses).
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
                "actionId": .string("mac.calendar_modify_event"),
                "reason": .string("event_not_found"),
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
            "fields_updated": .array(arguments.fields.map { .string($0) }),
        ])
    }

    /// Preconditions deliberately precede permission prompting and mutation.
    private static func calendarDeleteExpectation(input: [String: JSONValue]) throws(CalendarArgumentError) -> (id: String, title: String, start: Date) {
        guard let id = calendarEventID(input: input), let title = inputString(input["expected_title"]),
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
        func failed(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "actionId": .string(actionId), "reason": .string(reason)])
        }
        let expected: (id: String, title: String, start: Date)
        do { expected = try calendarDeleteExpectation(input: input) }
        catch { return error.result }
        let store = Store()
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
            return failed(error.localizedDescription)
        }
        return .object([
            "status": .string("completed"), "actionId": .string(actionId),
            "source": .string("eventkit"), "eventId": .string(expected.id),
            "scope": .string("this_event"),
        ])
    }

    public static func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        let granted = try await store.requestReminderAccess(allowPrompt: true)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_create",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        guard let title = inputString(input["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "reason": .string("Missing required field: title"),
            ])
        }
        let notes = inputString(input["notes"])
        let dueDateField = input["due_date"] ?? input["dueDate"]
        let dueDate = parseInputDate(dueDateField)
        guard dueDateField == nil || dueDate != nil else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "reason": .string("due_date could not be parsed. Supply a valid date or omit due_date for an undated reminder."),
            ])
        }
        let listNameField = input["list_name"] ?? input["listName"]
        let listName = inputString(listNameField)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 2026-09-06: same contract as calendar_create_event — supplied-but-
        // empty is an error, only an absent key selects the default list.
        let listNameSupplied: Bool = {
            guard let listNameField else { return false }
            if case .null = listNameField { return false }
            return true
        }()
        if listNameSupplied, (listName ?? "").isEmpty {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "reason": .string(
                    "list_name was supplied but names no reminder list. Omit list_name to use "
                    + "the default list, or pass the name of a real one."
                ),
            ])
        }

        // 2026-09-06: same contract as calendar_create_event — the default list
        // applies when `list_name` is OMITTED, not when a supplied name misses.
        let pickedList: Store.Calendar?
        if let listName, !listName.isEmpty {
            let lists = store.calendars(for: .reminder)
            let matches = lists.filter { $0.title.lowercased() == listName.lowercased() }
            guard let matched = matches.first else {
                return .object([
                    "status": .string("failed"),
                    "actionId": .string("mac.reminders_create"),
                    "reason": .string("No reminder list named '\(listName)'"),
                    "available": .array(lists.map { .string($0.title) }),
                ])
            }
            guard matches.count == 1 else {
                return .object([
                    "status": .string("failed"),
                    "actionId": .string("mac.reminders_create"),
                    "reason": .string("Multiple reminder lists are named '\(listName)'. Give the intended list a unique name before retrying."),
                ])
            }
            pickedList = matched
        } else {
            pickedList = store.defaultCalendarForNewReminders()
        }
        guard let targetList = pickedList else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "reason": .string("No reminder list available to write to"),
            ])
        }

        let reminder = store.makeReminder()
        reminder.title = title
        if let notes, !notes.isEmpty { reminder.notes = notes }
        if let dueDate {
            reminder.dueDateComponents = reminderDueComponents(from: dueDate, input: dueDateField)
        }
        reminder.calendar = targetList

        do {
            try store.save(reminder)
        } catch {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "reason": .string(error.localizedDescription),
            ])
        }

        var payload: [String: JSONValue] = [
            "status": .string("completed"),
            "actionId": .string("mac.reminders_create"),
            "source": .string("eventkit"),
            "reminderId": .string(reminder.calendarItemIdentifier),
            "title": .string(title),
            "list": .string(targetList.title),
        ]
        if let dueDate {
            payload["dueDate"] = .string(iso(dueDate))
        }
        return .object(payload)
    }

    private static func reminderDueComponents(from date: Date, input: JSONValue?) -> DateComponents {
        let dateOnly = inputString(input)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
        let fields: Set<Calendar.Component> = dateOnly
            ? [.calendar, .year, .month, .day]
            : [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second]
        return Calendar(identifier: .gregorian).dateComponents(fields, from: date)
    }

    public static func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        let granted = try await store.requestReminderAccess(allowPrompt: true)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_complete",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = inputString(input["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func failed(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "actionId": .string("mac.reminders_complete"), "reason": .string(reason)])
        }
        guard !id.isEmpty || !title.isEmpty else {
            return failed("Give the reminder's title (or its id from mac_reminders_list_due_today).")
        }
        var found = id.isEmpty ? nil : store.reminder(withIdentifier: id)
        if found == nil {
            // By title among open reminders: exactly one exact match, never a
            // containing one ("pay bill" must not complete "Do not pay bill").
            let wanted = (title.isEmpty ? id : title).lowercased()
            let open = await openReminderTitles(store: store)
            let exact = open.filter { $0.title.lowercased() == wanted }
            guard exact.count == 1 else {
                let near = exact.isEmpty ? open.filter { $0.title.lowercased().contains(wanted) } : exact
                let names = near.prefix(5).map { "\"\($0.title)\"" }.joined(separator: ", ")
                return failed(exact.count > 1
                    ? "\(exact.count) open reminders are titled \"\(title.isEmpty ? id : title)\"; give the id from mac_reminders_list_due_today."
                    : "No open reminder is titled exactly \"\(title.isEmpty ? id : title)\"." + (near.isEmpty ? "" : " Close: \(names). Give one of those exactly."))
            }
            found = store.reminder(withIdentifier: exact[0].id)
        }
        guard let reminder = found else { return failed("That reminder is gone; mac_reminders_list_due_today shows the current ones.") }

        let completedAt = Date()
        reminder.isCompleted = true
        reminder.completionDate = completedAt

        do {
            try store.save(reminder)
        } catch {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_complete"),
                "reason": .string(error.localizedDescription),
            ])
        }

        return .object([
            "status": .string("completed"),
            "actionId": .string("mac.reminders_complete"),
            "source": .string("eventkit"),
            "reminderId": .string(reminder.calendarItemIdentifier),
            "title": .string(NativeAppSecretRedactor.redactText(reminder.title ?? "")),
            "completedAt": .string(iso(completedAt)),
        ])
    }

    private static func reminderDeleteExpectation(input: [String: JSONValue]) throws(CalendarArgumentError) -> (id: String, title: String) {
        guard let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let title = inputString(input["expected_title"]), !title.isEmpty else {
            throw CalendarArgumentError(action: "mac.reminders_delete",
                reason: "Provide exact id and expected_title from mac_reminders_create or mac_reminders_list_due_today.")
        }
        return (id, title)
    }

    public static func remindersDelete(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_delete"
        func failed(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "actionId": .string(actionId), "reason": .string(reason)])
        }
        let expected: (id: String, title: String)
        do { expected = try reminderDeleteExpectation(input: input) }
        catch { return error.result }
        let store = Store()
        guard try await store.requestReminderAccess(allowPrompt: true) else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        guard let reminder = store.reminder(withIdentifier: expected.id) else { return failed("reminder_not_found") }
        guard reminder.title == expected.title else {
            return failed("reminder_changed: refresh the reminder and confirm it before retrying")
        }
        guard reminder.calendar.allowsContentModifications else { return failed("reminder_list_read_only") }
        do { try store.remove(reminder) }
        catch { return failed(error.localizedDescription) }
        return .object([
            "status": .string("completed"), "actionId": .string(actionId),
            "source": .string("eventkit"), "reminderId": .string(expected.id),
        ])
    }

    /// Open reminders' ids and titles, made Sendable on EventKit's queue.
    private static func openReminderTitles(store: Store) async -> [(id: String, title: String)] {
        return await withCheckedContinuation { continuation in
            store.fetchReminders(in: nil, incompleteOnly: true) { reminders in
                continuation.resume(returning: (reminders ?? []).map { ($0.calendarItemIdentifier, $0.title ?? "") })
            }
        }
    }

    public static func authorizationStatusPayload(localId: String) -> [String: JSONValue] {
        switch localId {
        case "local_calendar":
            return statusPayload(source: "calendar", state: calendarAuthorizationState())
        case "local_reminders":
            return statusPayload(source: "reminders", state: reminderAuthorizationState())
        default:
            return [:]
        }
    }

    private static func parseInputDate(_ raw: JSONValue?) -> Date? {
        switch raw {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let d = formatter.date(from: trimmed) { return d }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: trimmed) { return d }
            if let epoch = TimeInterval(trimmed) {
                return Date(timeIntervalSince1970: epoch)
            }
            // A local time without a zone, or a bare day (midnight local).
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = .current
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                local.dateFormat = format
                if let d = local.date(from: trimmed) { return d }
            }
            return nil
        case .int(let i):
            return Date(timeIntervalSince1970: TimeInterval(i))
        case .double(let d):
            return Date(timeIntervalSince1970: d)
        default:
            return nil
        }
    }

    private static func calendarAuthorizationState() -> String {
        Store.authorizationState(for: .event)
    }

    private static func reminderAuthorizationState() -> String {
        Store.authorizationState(for: .reminder)
    }

    private static func statusPayload(source: String, state: String) -> [String: JSONValue] {
        switch state {
        case "ready":
            return [
                "status": .string("ready"),
                "detail": .string("NativeAgent has read access to local \(source) data through EventKit."),
            ]
        case "probe_needed":
            return [
                "status": .string("probe_needed"),
                "detail": .string("NativeAgent can request local \(source) access directly from macOS."),
                "nextStep": .string("Open NativeAgent > Mac Integration and click Grant beside \(source.capitalized) to open the macOS permission prompt."),
            ]
        case "needs_permission":
            return [
                "status": .string("needs_permission"),
                "detail": .string("macOS has not granted NativeAgent read access to local \(source) data."),
                "nextStep": .string("Enable \(source.capitalized) access for NativeAgent in System Settings > Privacy & Security."),
            ]
        default:
            return [
                "status": .string(state),
                "detail": .string("NativeAgent could not determine local \(source) access."),
            ]
        }
    }

    private static func permissionEnvelope(actionId: String, source: String, status: String) -> JSONValue {
        // A skill never opens a macOS prompt or asks for a grant: it hands back to her.
        if SkillRunContext.handsBack { return SkillRunContext.handBack("macOS \(source.capitalized) permission") }
        let message: String
        if status == "probe_needed" {
            message = "Open NativeAgent > Mac Integration and click Grant beside \(source.capitalized) so macOS can register the permission request."
        } else {
            message = "NativeAgent needs macOS \(source.capitalized) permission before this local read action can run."
        }
        return .object([
            "status": .string("needs_permission"),
            "actionId": .string(actionId),
            "source": .string("eventkit"),
            "access": .string(status),
            "message": .string(message),
        ])
    }

    private static func filteredCalendars(_ calendars: [Store.Calendar], matching name: String?) -> [Store.Calendar]? {
        guard let name, !name.isEmpty else { return nil }
        let needle = name.lowercased()
        let filtered = calendars.filter { $0.title.lowercased().contains(needle) }
        return filtered.isEmpty ? [] : filtered
    }

    private static func fetchDueReminderJSON(
        store: Store,
        calendars: [Store.Calendar]?,
        includeCompleted: Bool,
        endOfToday: Date,
        limit: Int
    ) async -> [JSONValue]? {
        // Read views stay on EventKit's queue; filter and render to Sendable
        // values before resuming Core, preserving the platform's isolation.
        await withCheckedContinuation { continuation in
            store.fetchReminders(in: calendars, incompleteOnly: false) { reminders in
                guard let reminders else {
                    continuation.resume(returning: nil)
                    return
                }
                let values = Self.processReminders(
                    reminders,
                    includeCompleted: includeCompleted,
                    endOfToday: endOfToday,
                    limit: limit
                )
                continuation.resume(returning: values)
            }
        }
    }

    /// Process reminder values on the platform completion queue.
    nonisolated private static func processReminders(
        _ reminders: [Store.ReminderRead],
        includeCompleted: Bool,
        endOfToday: Date,
        limit: Int
    ) -> [JSONValue] {
        return reminders
            .filter { reminder in
                if !includeCompleted && reminder.isCompleted { return false }
                guard let due = reminder.dueDateComponents?.date else { return false }
                return due < endOfToday
            }
            .sorted {
                ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
            }
            .prefix(limit)
            .map { reminderJSON($0) }
            .map { $0 }
    }

    nonisolated private static func eventJSON(_ event: Store.EventRead) -> JSONValue {
        var obj: [String: JSONValue] = [
            // gpt-5.5 review BLOCKING: include eventIdentifier so callers can
            // pass it back into mac_calendar_modify_event. Without this the
            // modify tool requires an `id` that the list tool never exposed.
            "id": .string(event.eventIdentifier ?? ""),
            "title": .string(NativeAppSecretRedactor.redactText(event.title ?? "(Untitled event)")),
            "calendar": .string(event.calendarTitle),
            "calendarId": .string(event.calendarIdentifier),
            "availability": .string(event.availability),
            "allDay": .bool(event.isAllDay),
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

    nonisolated private static func reminderJSON(_ reminder: Store.ReminderRead) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(reminder.calendarItemIdentifier),
            "title": .string(NativeAppSecretRedactor.redactText(reminder.title ?? "(Untitled reminder)")),
            "list": .string(reminder.calendarTitle),
            "completed": .bool(reminder.isCompleted),
            "priority": .int(Int64(reminder.priority)),
        ]
        if let due = reminder.dueDateComponents?.date {
            obj["dueAt"] = .string(iso(due))
        }
        if let completedAt = reminder.completionDate {
            obj["completedAt"] = .string(iso(completedAt))
        }
        if let notes = reminder.notes, !notes.isEmpty {
            obj["notesPreview"] = .string(NativeAppSecretRedactor.redactText(String(notes.prefix(300))))
        }
        return .object(obj)
    }

    private static func clampedInt(_ raw: JSONValue?, defaultValue: Int, min: Int, max: Int) -> Int {
        let value: Int
        switch raw {
        case .int(let i):
            value = Int(i)
        case .double(let d):
            value = Int(exactly: d.rounded(.towardZero)) ?? defaultValue
        case .string(let s):
            value = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        default:
            value = defaultValue
        }
        return Swift.max(min, Swift.min(max, value))
    }

    private static func inputBool(_ raw: JSONValue?, defaultValue: Bool) -> Bool {
        switch raw {
        case .bool(let b):
            return b
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(t) { return true }
            if ["0", "false", "no", "off"].contains(t) { return false }
            return defaultValue
        default:
            return defaultValue
        }
    }

    private static func inputString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func calendarListWindow(
        input: [String: JSONValue],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CalendarListWindow {
        let hoursAhead = clampedInt(
            input["hours_ahead"] ?? input["hoursAhead"],
            defaultValue: 24,
            min: 1,
            max: 24 * 30
        )
        let dayRaw = inputString(
            input["day"] ??
                input["date"] ??
                input["date_scope"] ??
                input["dateScope"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let dayRaw,
           let scoped = calendarDayWindow(dayRaw, now: now, calendar: calendar) {
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
            let parts = lower.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var comps = DateComponents()
            comps.calendar = calendar
            comps.timeZone = calendar.timeZone
            comps.year = parts[0]
            comps.month = parts[1]
            comps.day = parts[2]
            guard let parsed = calendar.date(from: comps) else { return nil }
            dayStart = calendar.startOfDay(for: parsed)
            label = String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
        }

        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }
        return (label, dayStart, nextDay.addingTimeInterval(-1))
    }

    nonisolated private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
