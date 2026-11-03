import Foundation
import Synchronization
import UserNotifications
import NativeAgentCore
import PersistenceCore
import NotificationInbox
import DeviceSync
import NativeAgentShared
// Blueprint: | `AttentionRouter+MacNotifications.swift` | Native banner claim and OS acknowledgement share the delivery ledger; retained operations outlive a five-second response deadline and settle once; shutdown closes admission without joining callbacks |

/// The identity a banner carries and what a click on it does. A click OPENS
/// the item — it never approves, runs, or closes anything.
public enum NativeAgentNotificationRoute {
    public static let pageKey = "pageRoute"
    /// userInfo key: the Desk handle a reminder is about.
    public static let deskHandleKey = "deskHandle"

    public static func deskHandle(in userInfo: [AnyHashable: Any]) -> String? {
        guard let handle = userInfo[deskHandleKey] as? String,
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return handle
    }
}

extension NativeAgentNotifications {
    private static func postAccepted(
        title: String, body: String, userInfo: [String: String], soundName: String?, identifier: String
    ) async -> NativeAgentNotificationPostResult {
        let notificationTitle = NativeAgentNotificationDefaults.title(title)
        var settings = await notificationSettings()
        var authError: String?
        if settings.authorizationStatus == .notDetermined {
            authError = await requestAuthorizationError()
            settings = await notificationSettings()
        }

        let visibleAlertsEnabled = settings.alertSetting == .enabled
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
            return NativeAgentNotificationPostResult(
                identifier: identifier,
                status: "blocked",
                delivery: "macos_notifications_not_authorized",
                posted: false,
                visibleAlertsEnabled: false,
                authorizationStatus: string(settings.authorizationStatus),
                alertSetting: string(settings.alertSetting),
                soundSetting: string(settings.soundSetting),
                badgeSetting: string(settings.badgeSetting),
                error: authError ?? "NativeAgent does not have permission to show notifications. Open System Settings > Notifications > NativeAgent to allow them."
            )
        }

        guard !Task.isCancelled else {
            return NativeAgentNotificationPostResult(identifier: identifier, status: "cancelled", delivery: "task_cancelled",
                posted: false, visibleAlertsEnabled: visibleAlertsEnabled, authorizationStatus: string(settings.authorizationStatus),
                alertSetting: string(settings.alertSetting), soundSetting: string(settings.soundSetting), badgeSetting: string(settings.badgeSetting),
                error: CancellationError().localizedDescription)
        }
        let addError = await addNotification(
            identifier: identifier, title: notificationTitle, body: body,
            category: NativeAgentNotificationActions.category(for: userInfo),
            userInfo: userInfo, soundName: soundName
        )
        if let addError {
            return NativeAgentNotificationPostResult(
                identifier: identifier,
                status: "failed",
                delivery: "macos_notification_add_failed",
                posted: false,
                visibleAlertsEnabled: visibleAlertsEnabled,
                authorizationStatus: string(settings.authorizationStatus),
                alertSetting: string(settings.alertSetting),
                soundSetting: string(settings.soundSetting),
                badgeSetting: string(settings.badgeSetting),
                error: addError
            )
        }

        return NativeAgentNotificationPostResult(
            identifier: identifier,
            status: "completed",
            delivery: visibleAlertsEnabled
                ? "posted_to_macos_notification_center"
                : "posted_to_macos_notification_center_alerts_disabled",
            posted: true,
            visibleAlertsEnabled: visibleAlertsEnabled,
            authorizationStatus: string(settings.authorizationStatus),
            alertSetting: string(settings.alertSetting),
            soundSetting: string(settings.soundSetting),
            badgeSetting: string(settings.badgeSetting),
            error: nil
        )
    }
}

public enum NativeAgentNotifications {
    private static let delivery = Mutex<(stopped: Bool, posts: [UUID: Task<Void, Never>])>((false, [:]))

    /// Already accepted banners finish and retire at the OS callback, including
    /// errors. Close admission immediately; never join the OS during shutdown.
    public static func shutdown() {
        delivery.withLock { $0.stopped = true }
    }

    /// Tool-authored messages can be answered. Bind the route at posting time,
    /// never to whichever conversation happens to be visible when Reply lands.
    /// Messages outside a turn own a new, retained notification conversation.
    public static func postMessage(title: String, body: String, soundName: String? = nil) async -> NativeAgentNotificationPostResult {
        return await postAndReport(
            title: title, body: body,
            userInfo: NativeAgentNotificationActions.messageRoute,
            soundName: soundName
        )
    }

    public static func post(title: String, body: String, userInfo: [String: String] = [:]) {
        delivery.withLock { state in
            guard !state.stopped else { return }
            let id = UUID()
            state.posts[id] = Task {
                let result = await postAndReport(title: title, body: body, userInfo: userInfo)
                if let error = result.error { nativeLog("notification %@: %@", result.identifier, error) }
                _ = delivery.withLock { $0.posts.removeValue(forKey: id) }
            }
        }
    }

    /// `userInfo` rides with the banner so a click can land on the thing the
    /// banner is about. Keys are plain strings; `NativeAgentNotificationRoute`
    /// owns the ones this app reads back.
    public static func postAndReport(
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        soundName: String? = nil
    ) async -> NativeAgentNotificationPostResult {
        guard !Task.isCancelled, delivery.withLock({ !$0.stopped }) else {
            return NativeAgentNotificationPostResult(
                identifier: UUID().uuidString, status: "cancelled", delivery: "engine_shutdown",
                posted: false, visibleAlertsEnabled: false, authorizationStatus: "", alertSetting: "",
                soundSetting: "", badgeSetting: "", error: CancellationError().localizedDescription)
        }
        let root = PersistenceCore.defaultDataRoot()
        let event = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        do {
            let ledger = NotificationDeliveryLedger(dataRoot: root)
            let occurrence: NotificationOccurrence
            if let card = userInfo["itemId"] {
                let inbox = LiveNotificationInbox.live(dataRoot: root)
                occurrence = try await SwiftNativePersistenceCore.withFileLock(inbox.path, waitingAtMost: 5) {
                    guard let value = try await inbox.row(id: card), let row = value.objectValue,
                          let currentTitle = (row["held_title"] ?? row["title"])?.stringValue,
                          let currentBody = (row["held_body"] ?? row["summary"])?.stringValue,
                          row["status"] != .string("archived"), row["status"] != .string("dismissed") else {
                        throw ToolFailureError("The native notification's source card is settled or unavailable; nothing was posted.", effects: .none, owner: inbox.path.path)
                    }
                    // A card-bound post consumes its current committed intent,
                    // never a stale caller snapshot identified by matching prose.
                    let draft = try NotificationOccurrence(eventID: event + ":mac", cardID: card,
                        title: currentTitle, body: currentBody, reason: currentBody, userInfo: userInfo,
                        importance: AttentionImportance.ownerWaiting.rawValue, route: AttentionDelivery.none.rawValue,
                        soundName: soundName, destinations: ["mac"], sourceRevision: try LiveNotificationInbox.notificationRevision(value))
                    let id = try await ledger.retain(draft)
                    guard let saved = try ledger.read().entries[id]?.occurrence else { throw CocoaError(.fileReadCorruptFile) }
                    return saved
                }
            } else {
                let draft = try NotificationOccurrence(eventID: event + ":mac", cardID: nil,
                    title: title, body: body, reason: body, userInfo: userInfo,
                    importance: AttentionImportance.ownerWaiting.rawValue, route: AttentionDelivery.none.rawValue,
                    soundName: soundName, destinations: ["mac"])
                let id = try await ledger.retain(draft)
                guard let saved = try ledger.read().entries[id]?.occurrence else { throw CocoaError(.fileReadCorruptFile) }
                occurrence = saved
            }
            if AttentionRouter.holdsResidentWake(session: userInfo[NativeAgentNotificationActions.sessionKey], dataRoot: root) {
                if !NotificationChannelPreference.inApp() {
                    _ = try await ledger.claim(occurrence.id, destination: "mac", suppressedBy: NotificationChannelPreference.inAppKey)
                    guard let row = try ledger.read().entries[occurrence.id]?.rows["mac"] else { throw CocoaError(.fileReadCorruptFile) }
                    return .fromLedger(row.outcome, id: occurrence.id)
                }
                try await LiveNotificationInbox.hold(dataRoot: root, title: title, body: body, ways: [],
                    id: "held:" + occurrence.id, fields: ["notification_occurrence_id": .string(occurrence.id)])
                return .fromLedger(.notDelivered(reason: "held for quiet hours"), id: occurrence.id, held: true)
            }
            return await deliverOccurrence(occurrence.id, dataRoot: root)
        } catch {
            return .fromLedger(.notDelivered(reason: error.localizedDescription), id: event)
        }
    }

    /// The only native banner dispatch boundary, used by direct posts and by
    /// router release. Claim and acknowledgement belong to the SAME ledger row.
    static func deliverOccurrence(_ id: String, dataRoot: URL) async -> NativeAgentNotificationPostResult {
        let finished = ContinuationOnce<NativeAgentNotificationPostResult>()
        let operation = UUID()
        let task: Task<Void, Never>? = delivery.withLock { state in
            guard !state.stopped else { return nil }
            let task = Task {
                let result = await performDelivery(id, dataRoot: dataRoot)
                finished.resume(result)
                _ = delivery.withLock { $0.posts.removeValue(forKey: operation) }
            }
            state.posts[operation] = task
            return task
        }
        guard let task else { return .fromLedger(.notDelivered(reason: "Engine shutdown; banner not admitted"), id: id) }
        let ceiling = ContinuousClock.now.advanced(by: .seconds(5))
        let deadline = TaskWaitDeadline.current.map { min($0, ceiling) } ?? ceiling
        return await TaskWaitDeadline.$current.withValue(deadline) {
            await finished.wait(cancellingWith: .fromLedger(.unknown(sent: false,
                reason: "Native notification outcome is still pending; its original operation retains settlement"), id: id),
                onCancel: { if !TaskWaitDeadline.expired { task.cancel() } })
        }
    }

    private static func performDelivery(_ id: String, dataRoot: URL) async -> NativeAgentNotificationPostResult {
        let ledger = NotificationDeliveryLedger(dataRoot: dataRoot)
        do {
            guard let entry = try ledger.read().entries[id] else { throw CocoaError(.fileReadCorruptFile) }
            if let event = entry.occurrence.userInfo[memoryReviewEventKey],
               UserDefaults.standard.string(forKey: memoryReviewEventKey) != event {
                return .fromLedger(.notDelivered(reason: "Memory-review source changed before dispatch"), id: id)
            }
            let suppression = NotificationChannelPreference.inApp() ? nil : NotificationChannelPreference.inAppKey
            guard let claim = try await ledger.claim(id, destination: "mac", suppressedBy: suppression) else {
                guard let row = try ledger.read().entries[id]?.rows["mac"] else { throw CocoaError(.fileReadCorruptFile) }
                return .fromLedger(row.outcome, id: id)
            }
            var info = claim.occurrence.userInfo
            info["eventId"] = claim.occurrence.id
            let posted = await postAccepted(title: claim.occurrence.title, body: claim.occurrence.body,
                userInfo: info, soundName: claim.occurrence.soundName, identifier: claim.occurrence.id)
            let saved: Result<Void, Error> = await settle {
                do { try await ledger.finish(claim, outcome: posted.notificationOutcome); return .success(()) }
                catch { return .failure(error) }
            }
            do { try saved.get() }
            catch { return .fromLedger(.unknown(sent: posted.posted, reason: "OS outcome could not be retained: " + error.localizedDescription), id: id) }
            return posted
        } catch { return .fromLedger(.notDelivered(reason: error.localizedDescription), id: id) }
    }

    public static func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }

    public static func requestAuthorizationError() async -> String? {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    public static func addNotification(
        identifier: String, title: String, body: String, category: String,
        userInfo: [String: String], soundName: String?
    ) async -> String? {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = soundName.flatMap {
            $0.isEmpty ? nil : UNNotificationSound(named: UNNotificationSoundName(rawValue: $0))
        } ?? .default
        if !userInfo.isEmpty { content.userInfo = userInfo }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    private static func string(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "not_determined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private static func string(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported:
            return "not_supported"
        case .disabled:
            return "disabled"
        case .enabled:
            return "enabled"
        @unknown default:
            return "unknown"
        }
    }

}
