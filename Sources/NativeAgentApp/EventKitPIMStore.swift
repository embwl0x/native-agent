import Foundation
@preconcurrency import EventKit
import Connectors
import PersistenceCore

/// One EventKit session per action. Live objects never leave the main actor;
/// enumeration uses its own store and callback queues render Core results
/// inline through read views before exporting Sendable values.
@MainActor
final class EventKitPIMStore: LocalPIMStore {
    typealias Calendar = EventKitPIMCalendar
    typealias Event = EventKitPIMEvent
    typealias Reminder = EventKitPIMReminder
    typealias EventRead = EventKitPIMEventRead
    typealias ReminderRead = EventKitPIMReminderRead

    private let store = EKEventStore()

    init() {}

    static func authorizationState(for entity: LocalPIMEntity) -> String {
        MacPIMConnectorActions.authorizationState(EKEventStore.authorizationStatus(for: entity == .event ? .event : .reminder))
    }

    static var calendarIsWriteOnly: Bool {
        EKEventStore.authorizationStatus(for: .event) == .writeOnly
    }

    func requestCalendarAccess(_ intent: LocalPIMCalendarAccess) async throws -> Bool {
        switch intent {
        case .read: return try await MacPIMConnectorActions.requestCalendarReadAccess(store: store)
        case .write: return try await MacPIMConnectorActions.requestCalendarWriteAccessIfNeeded(store: store)
        }
    }

    func requestReminderAccess(allowPrompt: Bool) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if MacPIMConnectorActions.authorizationAllowsRead(status) { return true }
        guard status == .notDetermined, allowPrompt, !SkillRunContext.handsBack else { return false }
        return try await store.requestFullAccessToReminders()
    }

    func calendars(for entity: LocalPIMEntity) -> [Calendar] {
        store.calendars(for: entity == .event ? .event : .reminder).map(Calendar.init)
    }

    var defaultCalendarForNewEvents: Calendar? {
        store.defaultCalendarForNewEvents.map(Calendar.init)
    }

    func defaultCalendarForNewReminders() -> Calendar? {
        store.defaultCalendarForNewReminders().map(Calendar.init)
    }

    func event(withIdentifier id: String) -> Event? {
        store.event(withIdentifier: id).map(Event.init)
    }

    func reminder(withIdentifier id: String) -> Reminder? {
        (store.calendarItem(withIdentifier: id) as? EKReminder).map(Reminder.init)
    }

    func makeEvent() -> Event { Event(EKEvent(eventStore: store)) }
    func makeReminder() -> Reminder { Reminder(EKReminder(eventStore: store)) }
    func makeReminderCalendar(in calendar: Calendar) -> Calendar {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.source = calendar.raw.source
        return Calendar(list)
    }
    func save(_ calendar: Calendar) throws { try store.saveCalendar(calendar.raw, commit: true) }
    func save(_ event: Event) throws { try store.save(event.raw, span: .thisEvent, commit: true) }
    func save(_ reminder: Reminder) throws { try store.save(reminder.raw, commit: true) }
    func remove(_ event: Event) throws { try store.remove(event.raw, span: .thisEvent, commit: true) }
    func remove(_ reminder: Reminder) throws { try store.remove(reminder.raw, commit: true) }

    func fetchReminders(in calendars: [Calendar]?, incompleteOnly: Bool,
                        completion: @escaping @Sendable ([ReminderRead]?) -> Void) {
        let rawCalendars = calendars?.map(\.raw)
        let predicate = incompleteOnly
            ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: rawCalendars)
            : store.predicateForReminders(in: rawCalendars)
        store.fetchReminders(matching: predicate) { reminders in
            // EventKit invokes this on its private queue. Never capture an
            // actor-isolated processor (the 2026-06-07 isolation SIGTRAP).
            // Read views stay on this queue; Core resumes with Sendable values.
            completion(reminders?.map(ReminderRead.init))
        }
    }

    nonisolated static func withEvents<Result: Sendable>(
        start: Date, end: Date, calendarIDs: [String]?, calendarMatches: (@Sendable (String) -> Bool)?,
        read: @Sendable ([EventRead], [String]) -> Result
    ) -> Result {
        let store = EKEventStore()
        // Preserve enumeration even when no calendar filter was supplied.
        let available = store.calendars(for: .event)
        let calendars = available.filter { calendar in
            (calendarIDs == nil || calendarIDs!.contains(calendar.calendarIdentifier))
                && (calendarMatches == nil || calendarMatches!(calendar.title))
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return read(store.events(matching: predicate).map(EventRead.init), calendars.map(\.calendarIdentifier))
    }
}

struct EventKitPIMEventRead: LocalPIMEventRead {
    let raw: EKEvent
    init(_ raw: EKEvent) { self.raw = raw }
    var eventIdentifier: String? { raw.eventIdentifier }
    var title: String? { raw.title }
    var calendarTitle: String { raw.calendar.title }
    var calendarIdentifier: String { raw.calendar.calendarIdentifier }
    var isCancelled: Bool { raw.status == .canceled }
    var availability: String {
        switch raw.availability {
        case .free: "free"
        case .busy: "busy"
        case .tentative: "tentative"
        case .unavailable: "unavailable"
        default: "unknown"
        }
    }
    var isAllDay: Bool { raw.isAllDay }
    var startDate: Date? { raw.startDate }
    var endDate: Date? { raw.endDate }
    var location: String? { raw.location }
    var notes: String? { raw.notes }
}

struct EventKitPIMReminderRead: LocalPIMReminderRead {
    let raw: EKReminder
    init(_ raw: EKReminder) { self.raw = raw }
    var calendarItemIdentifier: String { raw.calendarItemIdentifier }
    var title: String? { raw.title }
    var calendarTitle: String { raw.calendar.title }
    var calendarIdentifier: String { raw.calendar.calendarIdentifier }
    var isCompleted: Bool { raw.isCompleted }
    var priority: Int { raw.priority }
    var dueDateComponents: DateComponents? { raw.dueDateComponents }
    var completionDate: Date? { raw.completionDate }
    var notes: String? { raw.notes }
}

@MainActor
struct EventKitPIMCalendar: LocalPIMCalendar {
    let raw: EKCalendar
    init(_ raw: EKCalendar) { self.raw = raw }
    var title: String { get { raw.title } nonmutating set { raw.title = newValue } }
    var calendarIdentifier: String { raw.calendarIdentifier }
    var sourceTitle: String { raw.source.title }
    var allowsContentModifications: Bool { raw.allowsContentModifications }
}

@MainActor
final class EventKitPIMEvent: LocalPIMEvent {
    let raw: EKEvent
    init(_ raw: EKEvent) { self.raw = raw }
    var eventIdentifier: String? { raw.eventIdentifier }
    var title: String? { get { raw.title } set { raw.title = newValue } }
    var startDate: Date? { get { raw.startDate } set { raw.startDate = newValue } }
    var endDate: Date? { get { raw.endDate } set { raw.endDate = newValue } }
    var notes: String? { get { raw.notes } set { raw.notes = newValue } }
    var location: String? { get { raw.location } set { raw.location = newValue } }
    var calendar: EventKitPIMCalendar {
        get { EventKitPIMCalendar(raw.calendar) }
        set { raw.calendar = newValue.raw }
    }
}

@MainActor
final class EventKitPIMReminder: LocalPIMReminder {
    let raw: EKReminder
    init(_ raw: EKReminder) { self.raw = raw }
    var calendarItemIdentifier: String { raw.calendarItemIdentifier }
    var title: String? { get { raw.title } set { raw.title = newValue } }
    var notes: String? { get { raw.notes } set { raw.notes = newValue } }
    var dueDateComponents: DateComponents? { get { raw.dueDateComponents } set { raw.dueDateComponents = newValue } }
    var isCompleted: Bool { get { raw.isCompleted } set { raw.isCompleted = newValue } }
    var completionDate: Date? { get { raw.completionDate } set { raw.completionDate = newValue } }
    var calendar: EventKitPIMCalendar {
        get { EventKitPIMCalendar(raw.calendar) }
        set { raw.calendar = newValue.raw }
    }
}
