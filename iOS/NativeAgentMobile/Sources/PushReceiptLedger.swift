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
    struct Reading {
        var entries: [PushReceiptEntry]
        var failure: String?
    }
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
        let reading = load()
        guard reading.failure == nil else {
            NSLog("[PushReceiptLedger] Receipt history unavailable; retained existing bytes: %@", reading.failure ?? "")
            NotificationCenter.default.post(name: didChange, object: nil)
            return entry
        }
        var entries = reading.entries
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

    static func load() -> Reading {
        do { return Reading(entries: try MobileLocalStorage.restore([PushReceiptEntry].self, key: key, defaults: .standard) ?? []) }
        catch { return Reading(entries: [], failure: "Push receipt history could not be read: \(error.localizedDescription). Its saved bytes are retained; repair this iPhone's receipt storage before recording further receipts.") }
    }
}
