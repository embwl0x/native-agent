import Foundation
@preconcurrency import EventKit
import MacAssistantStatus
import NativeAgentCore
import PersistenceCore

struct NativeAppLocalPIMStatusProvider: LocalPIMStatusProvider {
    func localStatus(id: String) async -> [String: JSONValue] {
        await MainActor.run {
            MacPIMConnectorActions.authorizationStatusPayload(localId: id)
        }
    }
}

@MainActor
enum MacPIMConnectorActions {
    enum CalendarAccessIntent: Equatable {
        case read
        case write
    }

    enum CalendarAuthorizationAction: Equatable {
        case ready
        case requestFull
        case requestWriteOnly
        case unavailable
    }

    struct CalendarListWindow: Equatable {
        let start: Date
        let end: Date
        let hoursAhead: Int
        let day: String?
    }

    static func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        let store = EKEventStore()
        let granted = try await requestCalendarAccessIfNeeded(store: store)
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
        let calendars = filteredCalendars(
            store.calendars(for: .event),
            matching: calendarName
        )
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .prefix(limit)
            .map { eventJSON($0) }

        var payload: [String: JSONValue] = [
            "status": .string("completed"),
            "actionId": .string("mac.calendar_list_upcoming"),
            "source": .string("eventkit"),
            "authorization": .string(calendarAuthorizationState()),
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

    static func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue {
        let store = EKEventStore()
        let granted = try await requestReminderAccessIfNeeded(store: store)
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
        let predicate = store.predicateForReminders(in: calendars)
        let reminders = await fetchDueReminderJSON(
            store: store,
            predicate: predicate,
            includeCompleted: includeCompleted,
            endOfToday: endOfToday,
            limit: limit
        )

        return .object([
            "status": .string("completed"),
            "actionId": .string("mac.reminders_list_due_today"),
            "source": .string("eventkit"),
            "authorization": .string(reminderAuthorizationState()),
            "includeCompleted": .bool(includeCompleted),
            "count": .int(Int64(reminders.count)),
            "reminders": .array(Array(reminders)),
        ])
    }

    static func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        let store = EKEventStore()
        let granted = try await requestCalendarWriteAccessIfNeeded(store: store)
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
                "reason": .string("Missing or invalid required field: start (ISO-8601 string or epoch seconds)"),
            ])
        }
        let endDate = parseInputDate(input["end"]) ?? startDate.addingTimeInterval(3600)
        let notes = inputString(input["notes"])
        let location = inputString(input["location"])
        let calendarName = inputString(input["calendar_name"] ?? input["calendarName"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // gpt-5.5 review NEEDS_FIX: `.writeOnly` users CAN write but CANNOT
        // enumerate calendars. The old code called store.calendars(for:.event)
        // unconditionally, which is a read operation that errors / returns
        // empty under writeOnly. Skip the picker when status is .writeOnly
        // and go straight to defaultCalendarForNewEvents (the only calendar
        // a writeOnly user is allowed to write to anyway).
        let currentStatus = EKEventStore.authorizationStatus(for: .event)
        let isWriteOnly: Bool = {
            if #available(macOS 14.0, *) {
                return currentStatus == .writeOnly
            }
            return false
        }()
        let pickedCalendar: EKCalendar?
        if isWriteOnly {
            pickedCalendar = store.defaultCalendarForNewEvents
        } else {
            pickedCalendar = pickCalendar(
                store.calendars(for: .event),
                named: calendarName
            ) ?? store.defaultCalendarForNewEvents
        }
        guard let targetCalendar = pickedCalendar else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_create_event"),
                "reason": .string("No calendar available to write to"),
            ])
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        if let notes, !notes.isEmpty { event.notes = notes }
        if let location, !location.isEmpty { event.location = location }
        event.calendar = targetCalendar

        do {
            try store.save(event, span: .thisEvent, commit: true)
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

    /// Modify an existing EKEvent. Required: "id" (EKEvent.eventIdentifier
    /// from a prior mac_calendar_list_upcoming result). At least one of
    /// "title", "start", "end", "notes", "location" must be present.
    /// Calendar membership is not changed by modify — the event's existing
    /// `.calendar` is preserved, so `.writeOnly` enumeration is a non-issue.
    static func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        let store = EKEventStore()
        // gpt-5.5 review NEEDS_FIX: modify requires READING the existing event
        // (`store.event(withIdentifier:)` is a read op), so `.writeOnly` users
        // can't actually fetch it. Require full access for modify (vs the
        // write-only-tolerant path that create uses).
        let granted = try await requestCalendarAccessIfNeeded(store: store)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.calendar_modify_event",
                source: "calendar",
                status: calendarAuthorizationState()
            )
        }

        guard let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_modify_event"),
                "reason": .string("Missing required field: id"),
            ])
        }

        guard let event = store.event(withIdentifier: id) else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_modify_event"),
                "reason": .string("event_not_found"),
            ])
        }

        // Only mutate fields explicitly present in input. Use input.keys
        // (not the helper return) so absence is distinguishable from a
        // provided-empty value — an empty notes/location string clears the
        // field on purpose; absence leaves it alone.
        var fieldsUpdated: [String] = []

        if input.keys.contains("title") {
            if let newTitle = inputString(input["title"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !newTitle.isEmpty {
                event.title = newTitle
                fieldsUpdated.append("title")
            } else {
                return .object([
                    "status": .string("failed"),
                    "actionId": .string("mac.calendar_modify_event"),
                    "reason": .string("Invalid field: title (must be non-empty)"),
                ])
            }
        }

        if input.keys.contains("start") {
            guard let newStart = parseInputDate(input["start"]) else {
                return .object([
                    "status": .string("failed"),
                    "actionId": .string("mac.calendar_modify_event"),
                    "reason": .string("Invalid field: start (ISO-8601 string or epoch seconds)"),
                ])
            }
            event.startDate = newStart
            fieldsUpdated.append("start")
        }

        if input.keys.contains("end") {
            guard let newEnd = parseInputDate(input["end"]) else {
                return .object([
                    "status": .string("failed"),
                    "actionId": .string("mac.calendar_modify_event"),
                    "reason": .string("Invalid field: end (ISO-8601 string or epoch seconds)"),
                ])
            }
            event.endDate = newEnd
            fieldsUpdated.append("end")
        }

        if input.keys.contains("notes") {
            event.notes = inputString(input["notes"]) ?? ""
            fieldsUpdated.append("notes")
        }

        if input.keys.contains("location") {
            event.location = inputString(input["location"]) ?? ""
            fieldsUpdated.append("location")
        }

        guard !fieldsUpdated.isEmpty else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.calendar_modify_event"),
                "reason": .string("Provide at least one of: title, start, end, notes, location"),
            ])
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
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
            "eventId": .string(event.eventIdentifier ?? id),
            "fields_updated": .array(fieldsUpdated.map { .string($0) }),
        ])
    }

    static func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        let store = EKEventStore()
        let granted = try await requestReminderWriteAccessIfNeeded(store: store)
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
        let dueDate = parseInputDate(input["due_date"] ?? input["dueDate"])
        let listName = inputString(input["list_name"] ?? input["listName"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pickedList = pickCalendar(
            store.calendars(for: .reminder),
            named: listName
        ) ?? store.defaultCalendarForNewReminders()
        guard let targetList = pickedList else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_create"),
                "reason": .string("No reminder list available to write to"),
            ])
        }

        let reminder = EKReminder(eventStore: store)
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
            try store.save(reminder, commit: true)
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

    static func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        let store = EKEventStore()
        let granted = try await requestReminderWriteAccessIfNeeded(store: store)
        guard granted else {
            return permissionEnvelope(
                actionId: "mac.reminders_complete",
                source: "reminders",
                status: reminderAuthorizationState()
            )
        }

        guard let id = inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_complete"),
                "reason": .string("Missing required field: id"),
            ])
        }

        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return .object([
                "status": .string("failed"),
                "actionId": .string("mac.reminders_complete"),
                "reason": .string("Reminder not found for id: \(id)"),
            ])
        }

        let completedAt = Date()
        reminder.isCompleted = true
        reminder.completionDate = completedAt

        do {
            try store.save(reminder, commit: true)
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
            "completedAt": .string(iso(completedAt)),
        ])
    }

    // MARK: - TCC status (for Mac Integration permission wizard)

    /// Returns the current Calendar (EKEvent) authorization status in the
    /// wizard vocabulary: "granted" | "denied" | "restricted" | "limited" |
    /// "not_determined". Does NOT trigger a prompt. `.writeOnly` is mapped to
    /// "limited" since it is a partial grant.
    public static func currentCalendarAuthorizationStatus() -> String {
        ekStatusToWizardString(EKEventStore.authorizationStatus(for: .event))
    }

    /// Returns the current Reminders (EKReminder) authorization status in the
    /// wizard vocabulary. Does NOT trigger a prompt.
    public static func currentReminderAuthorizationStatus() -> String {
        ekStatusToWizardString(EKEventStore.authorizationStatus(for: .reminder))
    }

    /// Triggers the Calendar TCC prompt if status is `.notDetermined`;
    /// otherwise returns current status without prompting. Returns the
    /// post-request status in the wizard vocabulary.
    public static func requestCalendarAccess() async -> String {
        let store = EKEventStore()
        _ = try? await requestCalendarReadAccess(store: store)
        return currentCalendarAuthorizationStatus()
    }

    /// Triggers the Reminders TCC prompt if status is `.notDetermined`;
    /// otherwise returns current status without prompting. Returns the
    /// post-request status in the wizard vocabulary.
    public static func requestReminderAccess() async -> String {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToReminders()
        }
        return currentReminderAuthorizationStatus()
    }

    private static func ekStatusToWizardString(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .authorized, .fullAccess:
            return "granted"
        case .writeOnly:
            return "limited"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "not_determined"
        }
    }

    static func authorizationStatusPayload(localId: String) -> [String: JSONValue] {
        switch localId {
        case "local_calendar":
            return statusPayload(source: "calendar", state: calendarAuthorizationState())
        case "local_reminders":
            return statusPayload(source: "reminders", state: reminderAuthorizationState())
        default:
            return [:]
        }
    }

    private static func requestCalendarAccessIfNeeded(store: EKEventStore) async throws -> Bool {
        try await requestCalendarReadAccess(store: store)
    }

    private static func requestReminderAccessIfNeeded(store: EKEventStore) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if authorizationAllowsRead(status) { return true }
        guard status == .notDetermined else { return false }
        return try await store.requestFullAccessToReminders()
    }

    private static func requestCalendarWriteAccessIfNeeded(store: EKEventStore) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch calendarAuthorizationAction(for: status, intent: .write) {
        case .ready:
            return true
        case .requestWriteOnly:
            return try await store.requestWriteOnlyAccessToEvents()
        case .requestFull, .unavailable:
            return false
        }
    }

    private static func requestCalendarReadAccess(store: EKEventStore) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch calendarAuthorizationAction(for: status, intent: .read) {
        case .ready:
            return true
        case .requestFull:
            return try await store.requestFullAccessToEvents()
        case .requestWriteOnly, .unavailable:
            return false
        }
    }

    static func calendarAuthorizationAction(
        for status: EKAuthorizationStatus,
        intent: CalendarAccessIntent
    ) -> CalendarAuthorizationAction {
        switch intent {
        case .read:
            switch status {
            case .authorized, .fullAccess:
                return .ready
            case .notDetermined, .writeOnly:
                return .requestFull
            case .denied, .restricted:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        case .write:
            switch status {
            case .authorized, .fullAccess, .writeOnly:
                return .ready
            case .notDetermined:
                return .requestWriteOnly
            case .denied, .restricted:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        }
    }

    private static func requestReminderWriteAccessIfNeeded(store: EKEventStore) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if authorizationAllowsRead(status) { return true }
        guard status == .notDetermined else { return false }
        return try await store.requestFullAccessToReminders()
    }

    private static func pickCalendar(_ calendars: [EKCalendar], named name: String?) -> EKCalendar? {
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
        authorizationState(EKEventStore.authorizationStatus(for: .event))
    }

    private static func reminderAuthorizationState() -> String {
        authorizationState(EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func authorizationAllowsRead(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    private static func authorizationState(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .authorized, .fullAccess:
            return "ready"
        case .writeOnly:
            return "needs_permission"
        case .notDetermined:
            return "probe_needed"
        case .denied, .restricted:
            return "needs_permission"
        @unknown default:
            return "unknown"
        }
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
            "authorization": .string(status),
            "message": .string(message),
        ])
    }

    private static func filteredCalendars(_ calendars: [EKCalendar], matching name: String?) -> [EKCalendar]? {
        guard let name, !name.isEmpty else { return nil }
        let needle = name.lowercased()
        let filtered = calendars.filter { $0.title.lowercased().contains(needle) }
        return filtered.isEmpty ? [] : filtered
    }

    private static func fetchDueReminderJSON(
        store: EKEventStore,
        predicate: NSPredicate,
        includeCompleted: Bool,
        endOfToday: Date,
        limit: Int
    ) async -> [JSONValue] {
        // 2026-06-07 crash fix: EventKit fires the completion handler on
        // its own private queue (com.apple.eventkit.reminders.search). When
        // Swift 6's strict isolation runtime checks the executor (via
        // _swift_task_checkIsolatedSwift / dispatch_assert_queue) it trips
        // because the captured closure inherits actor isolation from the
        // enclosing async context but actually runs on the EK queue. SIGTRAP.
        // Crash report: NativeAgentApp-2026-06-07-171115.ips
        //
        // Fix: process the EKReminder objects inline (EKReminder is NOT
        // Sendable so we can't pass them to another Task), but convert to
        // Sendable JSONValue BEFORE resuming the continuation. The
        // continuation resume itself carries actor isolation back to the
        // caller properly because [JSONValue] IS Sendable. The crashy bit
        // was the captured `includeCompleted` and `endOfToday` referenced
        // through main-actor isolation — now passed explicitly to a
        // nonisolated helper so there's no inherited isolation.
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
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

    /// Process EKReminders into [JSONValue]. Called from EventKit's
    /// completion queue with no actor isolation. EKReminder is not Sendable
    /// so this MUST stay scoped to a single function — never escape the
    /// EK array.
    nonisolated private static func processReminders(
        _ reminders: [EKReminder],
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

    private static func eventJSON(_ event: EKEvent) -> JSONValue {
        var obj: [String: JSONValue] = [
            // gpt-5.5 review BLOCKING: include eventIdentifier so callers can
            // pass it back into mac_calendar_modify_event. Without this the
            // modify tool requires an `id` that the list tool never exposed.
            "id": .string(event.eventIdentifier ?? ""),
            "title": .string(NativeAppSecretRedactor.redactText(event.title ?? "(Untitled event)")),
            "calendar": .string(event.calendar.title),
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

    nonisolated private static func reminderJSON(_ reminder: EKReminder) -> JSONValue {
        var obj: [String: JSONValue] = [
            "title": .string(NativeAppSecretRedactor.redactText(reminder.title ?? "(Untitled reminder)")),
            "list": .string(reminder.calendar.title),
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
            value = Int(d)
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
