// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: every N seconds writes app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import CryptoKit
import AppKit
import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import KnowledgeGraph
import PersistenceCore

extension MacSyncEngine {
    @discardableResult
    func sendNotificationToPairedDevices(
        title: String,
        body: String,
        userInfo: [String: String] = [:]
    ) async throws -> MobileNotificationDeliveryReceipt {
        try await MacSyncMobileNotificationRelay.sendNotification(
            title: title,
            body: body,
            userInfo: userInfo
        )
    }
}
