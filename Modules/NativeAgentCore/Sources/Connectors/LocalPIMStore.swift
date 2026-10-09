import Foundation

public enum LocalPIMEntity { case event, reminder }
public enum LocalPIMCalendarAccess { case read, write }

/// Live objects remain confined to the platform store's main-actor session.
@MainActor public protocol LocalPIMCalendar {
    var title: String { get set }
    var calendarIdentifier: String { get }
    var sourceTitle: String { get }
    var allowsContentModifications: Bool { get }
}

@MainActor public protocol LocalPIMEvent: AnyObject {
    associatedtype Calendar: LocalPIMCalendar
    var eventIdentifier: String? { get }
    var title: String? { get set }
    var startDate: Date? { get set }
    var endDate: Date? { get set }
    var notes: String? { get set }
    var location: String? { get set }
    var calendar: Calendar { get set }
}

@MainActor public protocol LocalPIMReminder: AnyObject {
    associatedtype Calendar: LocalPIMCalendar
    var calendarItemIdentifier: String { get }
    var title: String? { get set }
    var notes: String? { get set }
    var dueDateComponents: DateComponents? { get set }
    var isCompleted: Bool { get set }
    var completionDate: Date? { get set }
    var calendar: Calendar { get set }
}

/// Queue-confined read views, deliberately not Sendable. Core filters and
/// renders inline, accessing detail only after applying the existing limits.
public protocol LocalPIMEventRead: SendableMetatype {
    var eventIdentifier: String? { get }
    var title: String? { get }
    var calendarTitle: String { get }
    var calendarIdentifier: String { get }
    var availability: String { get }
    var isCancelled: Bool { get }
    var isAllDay: Bool { get }
    var startDate: Date? { get }
    var endDate: Date? { get }
    var location: String? { get }
    var notes: String? { get }
}

public protocol LocalPIMReminderRead: SendableMetatype {
    var calendarItemIdentifier: String { get }
    var title: String? { get }
    var calendarTitle: String { get }
    var calendarIdentifier: String { get }
    var isCompleted: Bool { get }
    var priority: Int { get }
    var dueDateComponents: DateComponents? { get }
    var completionDate: Date? { get }
    var notes: String? { get }
}

/// EventKit access and permission prompts. Core owns interpretation, selection,
/// matching and receipts; adapters only access platform objects and map values.
@MainActor public protocol LocalPIMStore: Sendable {
    associatedtype Calendar: LocalPIMCalendar
    associatedtype Event: LocalPIMEvent where Event.Calendar == Calendar
    associatedtype Reminder: LocalPIMReminder where Reminder.Calendar == Calendar
    associatedtype EventRead: LocalPIMEventRead
    associatedtype ReminderRead: LocalPIMReminderRead

    init()
    static func authorizationState(for entity: LocalPIMEntity) -> String
    static var calendarIsWriteOnly: Bool { get }
    func requestCalendarAccess(_ intent: LocalPIMCalendarAccess) async throws -> Bool
    func requestReminderAccess(allowPrompt: Bool) async throws -> Bool
    func calendars(for entity: LocalPIMEntity) -> [Calendar]
    var defaultCalendarForNewEvents: Calendar? { get }
    func defaultCalendarForNewReminders() -> Calendar?
    func event(withIdentifier id: String) -> Event?
    func reminder(withIdentifier id: String) -> Reminder?
    func makeEvent() -> Event
    func makeReminder() -> Reminder
    func makeReminderCalendar(in calendar: Calendar) -> Calendar
    func save(_ calendar: Calendar) throws
    func save(_ event: Event) throws
    func save(_ reminder: Reminder) throws
    func remove(_ event: Event) throws
    func remove(_ reminder: Reminder) throws
    func fetchReminders(in calendars: [Calendar]?, incompleteOnly: Bool,
                        completion: @escaping @Sendable ([ReminderRead]?) -> Void)
    nonisolated static func withEvents<Result: Sendable>(
        start: Date, end: Date, calendarIDs: [String]?, calendarMatches: (@Sendable (String) -> Bool)?,
        read: @Sendable ([EventRead], [String]) -> Result
    ) -> Result
}
