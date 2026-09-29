import Foundation

/// Scoped evidence request through the ordinary Reminders read/write tools.
/// Carries object bindings, never approval or permission.
public struct ReminderCraftBinding: Sendable {
    public let listName: String
    public let title: String
    public let dueDate: Date
    public let listID: String?
    public let reminderID: String?
    public init(listName: String, title: String, dueDate: Date,
                listID: String?, reminderID: String?) {
        self.listName = listName; self.title = title; self.dueDate = dueDate
        self.listID = listID; self.reminderID = reminderID
    }
    @TaskLocal public static var current: ReminderCraftBinding?
}
