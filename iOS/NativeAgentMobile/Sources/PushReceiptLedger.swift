// APNS receipt presence proves delivery to the app; absence is inconclusive after force-quit.

import Foundation

struct PushReceiptEntry: Codable, Identifiable {
    let receivedAt: Date
    let source: String
    let screen: String
    let itemId: String
    let eventId: String?

    var id: String { eventId ?? "\(receivedAt.timeIntervalSince1970)-\(itemId)" }
}

enum PushReceiptLedger {
    private static let key = "NativeAgentMobile.pushReceipts"
    private static let capacity = 20
    static let didChange = Notification.Name("NativeAgentMobile.pushReceiptLedgerDidChange")

    @discardableResult
    static func record(userInfo: [AnyHashable: Any]) -> PushReceiptEntry {
        let entry = PushReceiptEntry(
            receivedAt: Date(),
            source: (userInfo["source"] as? String) ?? "unknown",
            screen: (userInfo["screen"] as? String) ?? "",
            itemId: (userInfo["itemId"] as? String) ?? "",
            eventId: NativeAgentNotificationEventGate.eventID(in: userInfo)
        )
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries = Array(entries.prefix(capacity)) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        NSLog("[PushReceiptLedger] push received source=%@ itemId=%@ eventId=%@",
              entry.source, entry.itemId, entry.eventId ?? "none")
        return entry
    }

    static func load() -> [PushReceiptEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([PushReceiptEntry].self, from: data) else {
            return []
        }
        return entries
    }
}
