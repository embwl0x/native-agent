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
        let events = await upcomingEventRows(window: window, calendarName: calendarName, limit: limit)

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
        limit: Int
    ) async -> [JSONValue] {
        await Task.detached(priority: .userInitiated) { () -> [JSONValue] in
            let calendarMatches: (@Sendable (String) -> Bool)? = calendarName.flatMap { name in
                guard !name.isEmpty else { return nil }
                let needle = name.lowercased()
                return { $0.lowercased().contains(needle) }
            }
            return Store.withEvents(start: window.start, end: window.end, calendarMatches: calendarMatches) { events in
                events
                    .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                    .prefix(limit)
                    .map { eventJSON($0) }
            }
        }.value
    }

    public static func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        let granted = try await store.requestReminderAccess(allowPrompt: ReminderCraftBinding.current == nil)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_list_due_today",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        if let binding = ReminderCraftBinding.current {
            return await craftReminderEvidence(store: store, binding: binding)
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
        let reminders = await fetchDueReminderJSON(
            store: store,
            calendars: calendars,
            includeCompleted: includeCompleted,
            endOfToday: endOfToday,
            limit: limit
        )

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
        let notes = inputString(input["notes"])
        let location = inputString(input["location"])
        let calendarNameField = input["calendar_name"] ?? input["calendarName"]
        let calendarName = inputString(calendarNameField)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 2026-09-06: only an ABSENT (or null) key means "use the default
        // calendar". A supplied-but-empty name used to fall through to the
        // default, so `calendar_name: "  "` silently wrote to whatever calendar
        // the default happened to be — the same silent-wrong-destination the
        // no-such-name error above exists to prevent.
        let calendarNameSupplied: Bool = {
            guard let calendarNameField else { return false }
            if case .null = calendarNameField { return false }
            return true
        }()
        if calendarNameSupplied, (calendarName ?? "").isEmpty {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string(
                    "calendar_name was supplied but names no calendar. Omit calendar_name to "
                    + "use the default calendar, or pass the name of a real one."
                ),
            ])
        }

        // gpt-5.5 review NEEDS_FIX: `.writeOnly` users CAN write but CANNOT
        // enumerate calendars. The old code called store.calendars(for:.event)
        // unconditionally, which is a read operation that errors / returns
        // empty under writeOnly. Skip the picker when status is .writeOnly
        // and go straight to defaultCalendarForNewEvents (the only calendar
        // a writeOnly user is allowed to write to anyway).
        let isWriteOnly = Store.calendarIsWriteOnly
        // 2026-09-06: the schema says the default calendar is used when
        // `calendar_name` is OMITTED. A supplied name that matched nothing used
        // to fall back to the default too, so the event silently landed on a
        // different calendar than the one asked for. A named destination that
        // does not exist is an error that names the real ones.
        let pickedCalendar: Store.Calendar?
        if isWriteOnly {
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
            guard let matched = pickCalendar(calendars, named: calendarName) else {
                return .object([
                    "status": .string("failed"),
                    "actionId": .string("mac.calendar_create_event"),
                    "reason": .string("No calendar named '\(calendarName)'"),
                    "available": .array(calendars.map { .string($0.title) }),
                ])
            }
            pickedCalendar = matched
        } else {
            pickedCalendar = store.defaultCalendarForNewEvents
        }
        guard let targetCalendar = pickedCalendar else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("No calendar available to write to"),
            ])
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
        let granted = try await store.requestReminderAccess(allowPrompt: ReminderCraftBinding.current == nil)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_create",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        if let binding = ReminderCraftBinding.current {
            // Re-resolve the list and inspect for an already-landed creation
            // immediately before save, inside the permission-checked owner.
            let observed = await craftReminderEvidence(store: store, binding: binding)
            guard case .object(let evidence) = observed, evidence["ok"] == .bool(true),
                  evidence["state"] == .string("absent"),
                  let list = craftReminderList(store: store, binding: binding),
                  input["title"] == .string(binding.title),
                  input["list_name"] == .string(binding.listName),
                  parseInputDate(input["due_date"]) == binding.dueDate else { return observed }
            try Task.checkCancellation()
            let reminder = store.makeReminder()
            reminder.calendar = list
            reminder.title = binding.title
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            reminder.dueDateComponents = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: binding.dueDate)
            try store.save(reminder)
            return .object(["status": .string("completed"), "reminderId": .string(reminder.calendarItemIdentifier)])
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
        let dueDate = parseInputDate(input["due_date"] ?? input["dueDate"])
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
            guard let matched = pickCalendar(lists, named: listName) else {
                return .object([
                    "status": .string("failed"),
                    "actionId": .string("mac.reminders_create"),
                    "reason": .string("No reminder list named '\(listName)'"),
                    "available": .array(lists.map { .string($0.title) }),
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
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
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

    public static func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        let store = Store()
        let granted = try await store.requestReminderAccess(allowPrompt: ReminderCraftBinding.current == nil)
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

    private static func pickCalendar(_ calendars: [Store.Calendar], named name: String?) -> Store.Calendar? {
        guard let name, !name.isEmpty else { return nil }
        let needle = name.lowercased()
        return calendars.first { $0.title.lowercased() == needle }
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

    private static func craftReminderList(store: Store, binding: ReminderCraftBinding) -> Store.Calendar? {
        let lists = store.calendars(for: .reminder).filter { $0.title == binding.listName }
        guard lists.count == 1, let list = lists.first, list.allowsContentModifications,
              binding.listID == nil || binding.listID == list.calendarIdentifier else { return nil }
        return list
    }

    private static func craftReminderEvidence(store: Store, binding: ReminderCraftBinding) async -> JSONValue {
        guard let list = craftReminderList(store: store, binding: binding) else {
            return .object(["ok": .bool(false), "reason": .string("The exact writable reminder list is missing, ambiguous, or changed.")])
        }
        let listID = list.calendarIdentifier
        return await withCheckedContinuation { continuation in
            store.fetchReminders(in: [list], incompleteOnly: false) { reminders in
                continuation.resume(returning: Self.craftReminderJSON(reminders, binding: binding, listID: listID))
            }
        }
    }

    nonisolated private static func craftReminderJSON(_ reminders: [Store.ReminderRead]?, binding: ReminderCraftBinding, listID: String) -> JSONValue {
        guard let reminders else {
            return .object(["ok": .bool(false), "reason": .string("Reminders readback is unavailable.")])
        }
        let correlated = reminders.filter { $0.calendarItemIdentifier == binding.reminderID }
        let matching = reminders.filter { $0.title == binding.title && $0.dueDateComponents?.date == binding.dueDate }
        var result: [String: JSONValue] = ["ok": .bool(true), "list_id": .string(listID)]
        if correlated.isEmpty, matching.isEmpty, binding.reminderID == nil {
            result["state"] = .string("absent")
        } else if correlated.count == 1, let reminder = correlated.first,
                  matching.count == 1, matching.first?.calendarItemIdentifier == reminder.calendarItemIdentifier,
                  !reminder.isCompleted, reminder.calendarIdentifier == listID {
            result["state"] = .string("verified")
            result["reminder_id"] = .string(reminder.calendarItemIdentifier)
        } else {
            result["state"] = .string("drift")
        }
        return .object(result)
    }

    private static func fetchDueReminderJSON(
        store: Store,
        calendars: [Store.Calendar]?,
        includeCompleted: Bool,
        endOfToday: Date,
        limit: Int
    ) async -> [JSONValue] {
        // Read views stay on EventKit's queue; filter and render to Sendable
        // values before resuming Core, preserving the platform's isolation.
        await withCheckedContinuation { continuation in
            store.fetchReminders(in: calendars, incompleteOnly: false) { reminders in
                let values = Self.processReminders(
                    reminders ?? [],
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
                return due <= endOfToday
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
