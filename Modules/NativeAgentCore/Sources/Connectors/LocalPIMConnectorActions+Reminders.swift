import AuthoredCapabilities
import Foundation
@preconcurrency import EventKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import MacIntegration
import ToolExecution
// Blueprint: | `LocalPIMConnectorActions+Reminders.swift` | Reminder CRUD, due-date splitting and paging on the existing LocalPIMStore |

extension LocalPIMConnectorActions {
    /// The requesting root's part owns the local-day view; the query below remains the native permission, EventKit confinement and serialization boundary.
    public static func remindersListDueToday(input: [String: JSONValue], dataRoot: URL) async throws -> JSONValue {
        let packet: JSONValue = .object(["request": .object(input),
            "now": .string(iso(Date())), "timeZone": .string(TimeZone.current.identifier)])
        switch await Parts(root: dataRoot).call(id: "due-reminders", input: packet, as: JSONValue.self) {
        case .success(let value): return NativeAppSecretRedactor.redactValue(value)
        case .failure(let error):
            throw PartCallError(code: NativeAppSecretRedactor.redactText(error.code),
                message: NativeAppSecretRedactor.redactText(error.message))
        }
    }

    public static func remindersQuery(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_query"
        let start = parseInputDate(input["due_start"])
        let end = parseInputDate(input["due_end"])
        let split = parseInputDate(input["split_due_at"])
        let undatedOnly = inputBool(input["undated_only"], defaultValue: false)
        guard (input["due_start"] == nil || start != nil),
              (input["due_end"] == nil || end != nil),
              (input["split_due_at"] == nil || split != nil),
              !(undatedOnly && (start != nil || end != nil || split != nil)),
              start == nil || end == nil || start! < end! else {
            return .object(["status": .string("failed"), "actionId": .string(actionId), "effects": .string("none"),
                "reason": .string("Provide valid due_start/due_end/split_due_at with start before end; undated_only cannot be combined with a due range or split.")])
        }
        let store = LocalPIMStore()
        guard try await store.requestReminderAccess() else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        let includeCompleted = inputBool(input["include_completed"], defaultValue: false)
        let query = input["query"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let listName = input["list_name"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendars = filteredCalendars(store.calendars(for: .reminder), matching: listName)
        let offset = MacAppleScriptBridge.clampedInt(input["offset"], defaultValue: 0, min: 0, max: Int.max)
        let limit = MacAppleScriptBridge.clampedInt(input["limit"], defaultValue: 20, min: 1, max: 200)
        let access = reminderAuthorizationState()
        let timeZone = TimeZone.current.identifier
        return await withCheckedContinuation { continuation in
            // Completed reminders are fetched too, so a query that only matches finished ones says so instead of reading as "nothing".
            store.fetchReminders(in: calendars, incompleteOnly: false) { reminders in
                guard let reminders else {
                    continuation.resume(returning: .object(["status": .string("failed"), "effects": .string("none"), "actionId": .string(actionId),
                        "reason": .string("Reminders read is unavailable.")]))
                    return
                }
                let matchingAny = reminders.filter { reminder in
                    if let listName, !listName.isEmpty, !reminder.calendar.title.localizedCaseInsensitiveContains(listName) { return false }
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
                let matching = includeCompleted ? matchingAny : matchingAny.filter { !$0.isCompleted }
                let completedHidden = matchingAny.count - matching.count
                func page(_ reminders: [EKReminder]) -> [String: JSONValue] {
                    let rows = reminders.dropFirst(offset).prefix(limit).map { Self.reminderJSON($0) }
                    let next = offset + rows.count
                    return ["count": .int(Int64(rows.count)), "total": .int(Int64(reminders.count)),
                        "offset": .int(Int64(offset)), "next_offset": next < reminders.count ? .int(Int64(next)) : .null,
                        "reminders": .array(rows)]
                }
                var result = page(matching)
                result.merge([
                    "status": .string("completed"), "actionId": .string(actionId), "source": .string("eventkit"),
                    "access": .string(access), "timeZone": .string(timeZone),
                    "includeCompleted": .bool(includeCompleted),
                ]) { _, value in value }
                if completedHidden > 0 {
                    result["completed_hidden"] = .int(Int64(completedHidden))
                    result["hint"] = .string("\(completedHidden) completed reminder\(completedHidden == 1 ? "" : "s") also match\(completedHidden == 1 ? "es" : ""); include_completed:true shows them.")
                }
                if let split {
                    // Both pages are slices of this fetch, never offsets from fresh reads.
                    result["before"] = .object(page(matching.filter {
                        guard let due = $0.dueDateComponents?.date else { return false }
                        return due < split
                    }))
                    result["on_or_after"] = .object(page(matching.filter {
                        guard let due = $0.dueDateComponents?.date else { return false }
                        return due >= split
                    }))
                }
                continuation.resume(returning: .object(result))
            }
        }
    }

    /// Every reminder list with its open count: "which list has the most left" is one read, not an inference from each reminder's `list`.
    public static func remindersLists(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_lists"
        let store = LocalPIMStore()
        guard try await store.requestReminderAccess() else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        let lists = store.calendars(for: .reminder)
        let open: [String: Int] = await withCheckedContinuation { continuation in
            store.fetchReminders(in: lists, incompleteOnly: true) { reminders in
                var counts: [String: Int] = [:]
                for reminder in reminders ?? [] { counts[reminder.calendar.calendarIdentifier, default: 0] += 1 }
                continuation.resume(returning: counts)
            }
        }
        return .object(["status": .string("completed"), "actionId": .string(actionId), "source": .string("eventkit"),
            "count": .int(Int64(lists.count)),
            "lists": .array(lists.map {
                .object(["listId": .string($0.calendarIdentifier), "title": .string($0.title), "source": .string($0.source.title),
                         "writable": .bool($0.allowsContentModifications), "open": .int(Int64(open[$0.calendarIdentifier] ?? 0))])
            })])
    }

    public static func remindersRead(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_read"
        guard let id = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return .object(["status": .string("failed"), "actionId": .string(actionId), "effects": .string("none"), "reason": .string("Provide an exact reminder id.")])
        }
        let store = LocalPIMStore()
        guard try await store.requestReminderAccess() else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        guard let reminder = store.reminder(withIdentifier: id) else {
            // A shortened id never matches: say so, instead of "not found" alone.
            let hint = id.count < 30 ? " Ids are the full identifier a query, read or create returned (36 characters or more); a shortened one never matches." : ""
            return .object(["status": .string("failed"), "actionId": .string(actionId), "effects": .string("none"),
                            "reason": .string("The exact reminder was not found." + hint)])
        }
        return .object(["status": .string("completed"), "actionId": .string(actionId), "source": .string("eventkit"),
            "reminder": liveReminderJSON(reminder)])
    }

    struct ReminderUpdateArguments {
        let id: String
        var title: String?
        var notes: String?
        var due: DateComponents?
        var changesDue = false
    }

    static func reminderUpdateArguments(input: [String: JSONValue]) throws(CalendarArgumentError) -> ReminderUpdateArguments {
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
        let store = LocalPIMStore()
        guard try await store.requestReminderAccess() else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        guard let reminder = store.reminder(withIdentifier: arguments.id) else {
            return .object(["status": .string("failed"), "effects": .string("none"), "actionId": .string(actionId), "reason": .string("The exact reminder was not found.")])
        }
        guard reminder.calendar.allowsContentModifications else {
            return .object(["status": .string("failed"), "effects": .string("none"), "actionId": .string(actionId), "reason": .string("The reminder list is read-only.")])
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

    private static func liveReminderJSON(_ reminder: EKReminder) -> JSONValue {
        .object([
            "id": .string(reminder.calendarItemIdentifier),
            "title": .string(NativeAppSecretRedactor.redactText(reminder.title ?? "(Untitled reminder)")),
            "list": .string(reminder.calendar.title), "listId": .string(reminder.calendar.calendarIdentifier),
            "completed": .bool(reminder.isCompleted),
            "dueAt": reminder.dueDateComponents?.date.map { .string(iso($0)) } ?? .null,
            "timeZone": .string(TimeZone.current.identifier),
            "completedAt": reminder.completionDate.map { .string(iso($0)) } ?? .null,
            "notes": .string(NativeAppSecretRedactor.redactText(reminder.notes ?? "")),
        ])
    }

    public static func remindersListRename(input: [String: JSONValue]) async throws -> JSONValue {
        try await remindersListWrite(input: input, rename: true)
    }

    public static func remindersListCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await remindersListWrite(input: input, rename: false)
    }

    public static func remindersListWrite(input: [String: JSONValue], rename: Bool) async throws -> JSONValue {
        let actionId = rename ? "reminders.list_rename" : "reminders.list_create"
        func failed(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "actionId": .string(actionId), "effects": .string("none"), "reason": .string(reason)])
        }
        guard let name = (input[rename ? "new_name" : "name"])?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return failed("A nonempty list name is required.")
        }
        let requested = input["list"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if rename, (requested ?? "").isEmpty { return failed("The exact existing list name is required.") }
        let store = LocalPIMStore()
        guard try await store.requestReminderAccess() else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        let lists = store.calendars(for: .reminder)
        func sameName(_ title: String, _ name: String) -> Bool {
            title.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                == name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let list: EKCalendar
        if rename, let requested {
            let matches = lists.filter { sameName($0.title, requested) }
            guard matches.count == 1, let match = matches.first else {
                return failed(matches.isEmpty ? "No reminder list has that exact name. Lists: " + lists.map(\.title).joined(separator: ", ") + "."
                    : "Multiple reminder lists have that name. Give the intended list a unique name before retrying.")
            }
            guard match.allowsContentModifications else { return failed("The reminder list is read-only.") }
            list = match
        } else {
            guard let defaultList = store.defaultCalendarForNewReminders() else {
                return failed("No default Reminders list is available to choose an account.")
            }
            guard defaultList.allowsContentModifications else { return failed("The default reminder list is read-only.") }
            list = store.makeReminderCalendar(in: defaultList)
        }
        guard !lists.contains(where: { sameName($0.title, name) && $0.calendarIdentifier != list.calendarIdentifier }) else {
            return failed("A reminder list already has that name. Choose a unique name.")
        }
        let previousName = rename ? list.title : nil
        list.title = name
        try Task.checkCancellation()
        do { try store.save(list) }
        catch { return failed(error.localizedDescription) }
        guard let saved = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == list.calendarIdentifier }),
              saved.title == name else {
            return .object(["status": .string("unverified"), "actionId": .string(actionId),
                "list_id": .string(list.calendarIdentifier), "name": .string(name),
                "reason": .string("EventKit accepted the write, but the saved list could not be read back. Verify before claiming success.")])
        }
        var result: [String: JSONValue] = ["status": .string("completed"), "actionId": .string(actionId),
            "source": .string("eventkit"), "list_id": .string(saved.calendarIdentifier),
            "name": .string(saved.title), "account": .string(saved.source.title)]
        if let previousName { result["previous_name"] = .string(previousName) }
        return .object(result)
    }

    public static func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        let store = LocalPIMStore()
        let granted = try await store.requestReminderAccess()
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_create",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        guard let title = input["title"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "effects": .string("none"),
                "reason": .string("Missing required field: title"),
            ])
        }
        let notes = input["notes"]?.scalarText
        let dueDateField = input["due_date"] ?? input["dueDate"]
        let dueDate = parseInputDate(dueDateField)
        guard dueDateField == nil || dueDate != nil else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "effects": .string("none"),
                "reason": .string("due_date could not be parsed. Supply a valid date or omit due_date for an undated reminder."),
            ])
        }
        let listNameField = input["list_name"] ?? input["listName"]
        let listName = listNameField?.scalarText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Supplied list names must be nonempty.
        let listNameSupplied: Bool = {
            guard let listNameField else { return false }
            if case .null = listNameField { return false }
            return true
        }()
        if listNameSupplied, (listName ?? "").isEmpty {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "actionId": .string("mac.reminders_create"),
                "reason": .string(
                    "list_name was supplied but names no reminder list. Omit list_name to use "
                    + "the default list, or pass the name of a real one."
                ),
            ])
        }

        // The default list applies only when no list name is supplied.
        let pickedList: EKCalendar?
        if let listName, !listName.isEmpty {
            let lists = store.calendars(for: .reminder)
            let matches = lists.filter { $0.title.lowercased() == listName.lowercased() }
            guard let matched = matches.first else {
                return .object([
                    "status": .string("failed"),
                    "effects": .string("none"),
                    "actionId": .string("mac.reminders_create"),
                    "reason": .string("No reminder list named '\(listName)'"),
                    "available": .array(lists.map { .string($0.title) }),
                ])
            }
            guard matches.count == 1 else {
                return .object([
                    "status": .string("failed"),
                    "effects": .string("none"),
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
                "effects": .string("none"),
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
            "timeZone": .string(TimeZone.current.identifier),
        ]
        if let dueDate = reminder.dueDateComponents?.date {
            payload["dueDate"] = .string(iso(dueDate))
        }
        return .object(payload)
    }

    private static func reminderDueComponents(from date: Date, input: JSONValue?) -> DateComponents {
        let dateOnly = input?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
        let fields: Set<Calendar.Component> = dateOnly
            ? [.calendar, .year, .month, .day]
            : [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second]
        return Calendar(identifier: .gregorian).dateComponents(fields, from: date)
    }

    public static func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        let store = LocalPIMStore()
        let granted = try await store.requestReminderAccess()
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_complete",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        let id = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = input["title"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Every refusal here precedes the save: nothing changed.
        func failed(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "actionId": .string("mac.reminders_complete"), "effects": .string("none"), "reason": .string(reason)])
        }
        guard !id.isEmpty || !title.isEmpty else {
            return failed("Give the reminder's title (or its id from mac_reminders_list_due_today).")
        }
        var found = id.isEmpty ? nil : store.reminder(withIdentifier: id)
        if found == nil {
            // By title among open reminders: exactly one exact match, never a containing one ("pay bill" must not complete "Do not pay bill").
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
            "timeZone": .string(TimeZone.current.identifier),
        ])
    }

    static func reminderDeleteExpectation(input: [String: JSONValue]) throws(CalendarArgumentError) -> (id: String, title: String) {
        guard let id = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let title = input["expected_title"]?.scalarText, !title.isEmpty else {
            throw CalendarArgumentError(action: "mac.reminders_delete",
                reason: "Provide exact id and expected_title from mac_reminders_create or mac_reminders_list_due_today.")
        }
        return (id, title)
    }

    public static func remindersDelete(input: [String: JSONValue]) async throws -> JSONValue {
        let actionId = "mac.reminders_delete"
        // Refusals before `remove` changed nothing; a failed remove reports itself below.
        func failed(_ reason: String, effects: String = "none") -> JSONValue {
            .object(["status": .string("failed"), "actionId": .string(actionId), "effects": .string(effects), "reason": .string(reason)])
        }
        let expected: (id: String, title: String)
        do { expected = try reminderDeleteExpectation(input: input) }
        catch { return error.result }
        let store = LocalPIMStore()
        guard try await store.requestReminderAccess() else {
            return permissionEnvelope(actionId: actionId, source: "reminders", status: reminderAuthorizationState())
        }
        guard let reminder = store.reminder(withIdentifier: expected.id) else { return failed("reminder_not_found") }
        guard reminder.title == expected.title else {
            return failed("reminder_changed: refresh the reminder and confirm it before retrying")
        }
        guard reminder.calendar.allowsContentModifications else { return failed("reminder_list_read_only") }
        do { try store.remove(reminder) }
        catch { return failed(error.localizedDescription, effects: "unknown") }
        return .object([
            "status": .string("completed"), "actionId": .string(actionId),
            "source": .string("eventkit"), "reminderId": .string(expected.id),
        ])
    }

    /// Open reminders' ids and titles, made Sendable on EventKit's queue.
    private static func openReminderTitles(store: LocalPIMStore) async -> [(id: String, title: String)] {
        return await withCheckedContinuation { continuation in
            store.fetchReminders(in: nil, incompleteOnly: true) { reminders in
                continuation.resume(returning: (reminders ?? []).map { ($0.calendarItemIdentifier, $0.title ?? "") })
            }
        }
    }

    nonisolated private static func reminderJSON(_ reminder: EKReminder) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(reminder.calendarItemIdentifier),
            "title": .string(NativeAppSecretRedactor.redactText(reminder.title ?? "(Untitled reminder)")),
            "list": .string(reminder.calendar.title),
            "completed": .bool(reminder.isCompleted),
            "priority": .int(Int64(reminder.priority)),
            "timeZone": .string(TimeZone.current.identifier),
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
}
