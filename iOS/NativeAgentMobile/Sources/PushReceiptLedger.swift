// PushReceiptLedger.swift — records every remote push the app actually
// receives from APNS, so "Mac sent it (HTTP 200) but nothing showed" can be
// split into its two very different causes:
//   • entry present  → delivered to the device, but silenced on-screen
//     (Focus / Scheduled Summary / notification settings)
//   • entry absent   → never reached the app (APNS drop, token mismatch,
//     force-quit app can't be woken, network)
// Written from didReceiveRemoteNotification (2026-07-04, lock-screen
// notification debugging). Best-effort: a force-quit app is never woken for
// remote pushes, so absence here is strong but not absolute evidence.

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
