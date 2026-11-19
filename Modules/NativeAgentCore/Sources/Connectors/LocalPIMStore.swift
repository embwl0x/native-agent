import AuthoredCapabilities
import Foundation
@preconcurrency import EventKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LocalPIMStore.swift` | `LocalPIMStore`: main-actor mutations, queue-confined reads and nonisolated callbacks |

public enum LocalPIMCalendarAccess { case read, write }

/// Each action owns its EventKit store; join off-actor occurrence reads before main-actor mutations.
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

    func occurrence(of event: EKEvent, expectedStart: Date?) async throws -> EKEvent? {
        guard event.hasRecurrenceRules || event.isDetached else { return event }
        guard let expectedStart else { return nil }
        try Task.checkCancellation()
        // Keep the occurrence on the store that will save/remove it; this action awaits the read before using either.
        let calendar: EKCalendar = event.calendar
        let read = Task.detached(priority: .userInitiated) { [store, id = event.eventIdentifier] () throws -> EKEvent? in
            try Task.checkCancellation()
            // Calendar rows carry starts at whole-second precision.
            let predicate = store.predicateForEvents(withStart: expectedStart.addingTimeInterval(-1),
                end: expectedStart.addingTimeInterval(1), calendars: [calendar])
            return store.events(matching: predicate).first { occurrence in
                guard let start = occurrence.startDate else { return false }
                return occurrence.eventIdentifier == id && abs(start.timeIntervalSince(expectedStart)) < 1
            }
        }
        return try await withTaskCancellationHandler {
            let occurrence = try await settle { await read.result }.get()
            try Task.checkCancellation()
            return occurrence
        } onCancel: { read.cancel() }
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
    func save(_ calendar: EKCalendar) throws {
        try Task.checkCancellation()
        try store.saveCalendar(calendar, commit: true)
    }
    func save(_ event: EKEvent) throws {
        try Task.checkCancellation()
        try store.save(event, span: .thisEvent, commit: true)
    }
    func save(_ reminder: EKReminder) throws {
        try Task.checkCancellation()
        try store.save(reminder, commit: true)
    }
    func remove(_ event: EKEvent) throws {
        try Task.checkCancellation()
        try store.remove(event, span: .thisEvent, commit: true)
    }
    func remove(_ reminder: EKReminder) throws {
        try Task.checkCancellation()
        try store.remove(reminder, commit: true)
    }

    func fetchReminders(in calendars: [EKCalendar]?, incompleteOnly: Bool,
                        completion: @escaping @Sendable ([EKReminder]?) -> Void) {
        let predicate = incompleteOnly
            ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
            : store.predicateForReminders(in: calendars)
        store.fetchReminders(matching: predicate, completion: Self.reminderCompletion(completion))
    }

    // Create Apple's block outside actor isolation: hopping inside it cannot repair an actor-inferred callback entry.
    nonisolated private static func reminderCompletion(
        _ completion: @escaping @Sendable ([EKReminder]?) -> Void
    ) -> ([EKReminder]?) -> Void {
        { reminders in completion(reminders) }
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
