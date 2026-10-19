import AuthoredCapabilities
import Foundation
@preconcurrency import EventKit
import PersistenceCore

public enum LocalPIMCalendarAccess { case read, write }

/// One EventKit session per action. Live objects never leave the main actor;
/// enumeration uses its own store and callback queues render Core results
/// inline before exporting Sendable values.
@MainActor
final class LocalPIMStore {
    private let store = EKEventStore()

    static func authorizationState(for entity: EKEntityType) -> String {
        LocalPIMConnectorActions.authorizationState(EKEventStore.authorizationStatus(for: entity))
    }

    static var calendarIsWriteOnly: Bool {
        EKEventStore.authorizationStatus(for: .event) == .writeOnly
    }

    func requestCalendarAccess(_ intent: LocalPIMCalendarAccess) async throws -> Bool {
        switch intent {
        case .read: return LocalPIMConnectorActions.authorizationAllowsRead(EKEventStore.authorizationStatus(for: .event))
        case .write: return LocalPIMConnectorActions.calendarAuthorizationAction(for: EKEventStore.authorizationStatus(for: .event), intent: .write) == .ready
        }
    }

    func requestReminderAccess() async throws -> Bool {
        LocalPIMConnectorActions.authorizationAllowsRead(EKEventStore.authorizationStatus(for: .reminder))
    }

    func calendars(for entity: EKEntityType) -> [EKCalendar] {
        store.calendars(for: entity)
    }

    var defaultCalendarForNewEvents: EKCalendar? {
        store.defaultCalendarForNewEvents
    }

    func defaultCalendarForNewReminders() -> EKCalendar? {
        store.defaultCalendarForNewReminders()
    }

    func event(withIdentifier id: String) -> EKEvent? {
        store.event(withIdentifier: id)
    }

    func reminder(withIdentifier id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    func makeEvent() -> EKEvent { EKEvent(eventStore: store) }
    func makeReminder() -> EKReminder { EKReminder(eventStore: store) }
    func makeReminderCalendar(in calendar: EKCalendar) -> EKCalendar {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.source = calendar.source
        return list
    }
    func save(_ calendar: EKCalendar) throws { try store.saveCalendar(calendar, commit: true) }
    func save(_ event: EKEvent) throws { try store.save(event, span: .thisEvent, commit: true) }
    func save(_ reminder: EKReminder) throws { try store.save(reminder, commit: true) }
    func remove(_ event: EKEvent) throws { try store.remove(event, span: .thisEvent, commit: true) }
    func remove(_ reminder: EKReminder) throws { try store.remove(reminder, commit: true) }

    func fetchReminders(in calendars: [EKCalendar]?, incompleteOnly: Bool,
                        completion: @escaping @Sendable ([EKReminder]?) -> Void) {
        let predicate = incompleteOnly
            ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
            : store.predicateForReminders(in: calendars)
        store.fetchReminders(matching: predicate) { reminders in
            // EventKit invokes this on its private queue. Never capture an
            // actor-isolated processor (the 2026-06-07 isolation SIGTRAP).
            // Objects stay on this queue; Core resumes with Sendable values.
            completion(reminders)
        }
    }

    nonisolated static func withEvents<Result: Sendable>(
        start: Date, end: Date, calendarIDs: [String]?, calendarMatches: (@Sendable (String) -> Bool)?,
        read: @Sendable ([EKEvent], [String]) -> Result
    ) -> Result {
        let store = EKEventStore()
        // Preserve enumeration even when no calendar filter was supplied.
        let available = store.calendars(for: .event)
        let calendars = available.filter { calendar in
            (calendarIDs == nil || calendarIDs!.contains(calendar.calendarIdentifier))
                && (calendarMatches == nil || calendarMatches!(calendar.title))
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return read(store.events(matching: predicate), calendars.map(\.calendarIdentifier))
    }
}
