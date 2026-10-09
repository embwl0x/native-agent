import Foundation

/// One row of the Mac's settings registry as the phone shows it. The Mac
/// reads and writes every value through the row its own page control uses;
/// the phone only renders it and sends back one new value at a time.
public struct MobileAppSetting: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var page: String
    public var label: String
    /// `boolean`, `text`, `choice`, `number` or `list`.
    public var type: String
    public var choices: [String]
    public var writable: Bool
    /// The value as text: `true`/`false`, the number, the choice, or one list
    /// entry per line. A set sends the same spelling back.
    public var value: String

    public init(id: String, page: String, label: String, type: String,
                choices: [String], writable: Bool, value: String) {
        self.id = id; self.page = page; self.label = label; self.type = type
        self.choices = choices; self.writable = writable; self.value = value
    }
}
