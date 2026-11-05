import Foundation
import DeviceSync
import Experiences
import Synchronization
import UserNotifications
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AttentionRouter+MacNotifications.swift` | Mac banners: UI-physics posts, and the Mac door's post whose OS callback settles its delivery |

/// Banner clicks only open the item; they never approve, run or close it.
public enum NativeAgentNotificationRoute {
    public static let pageKey = "pageRoute"
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
                error: authError
                    ?? "NativeAgent does not have permission to show notifications. Open System Settings > Notifications > NativeAgent to allow them."
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
    private static let soundEvidence = "macos/notification_sound"
    private static let delivery = Mutex<(stopped: Bool, posts: [UUID: Task<Void, Never>], watch: Task<Void, Never>?)>((false, [:], nil))

    /// The engine's one delivery watch lives until producer shutdown; OS posts keep their independent settlement.
    public static func keepDeliveryWatch(_ task: Task<Void, Never>) {
        delivery.withLock { state in
            guard !state.stopped, state.watch == nil else { task.cancel(); return }
            state.watch = task
        }
    }

    /// Close admission without joining OS callbacks during shutdown; accepted banners settle at their callback.
    public static func shutdown() {
        delivery.withLock { state in
            state.stopped = true
            state.watch?.cancel()
            state.watch = nil
        }
    }

    /// Bind reply routing when posting so a later visible conversation cannot receive another turn's answer.
    public static func postMessage(title: String, body: String, soundName: String? = nil, router: AttentionRouter,
                                   turn: Turn?, deadline: ContinuousClock.Instant?) async -> NativeAgentNotificationPostResult {
        let id = "mac_notify:" + UUID().uuidString.lowercased()
        guard !Task.isCancelled, deadline.map({ ContinuousClock.now < $0 }) != false else {
            return .from(.notDelivered(reason: "The notification's admission deadline ended"), id: id)
        }
        let finished = ContinuationOnce<NativeAgentNotificationPostResult>()
        let task = Task {
            do {
                let matter = Matter(id: id, form: .words, from: "mac_notify", title: title, summary: body,
                    open: turn?.verifiedSessionID.map { "chat:" + $0 },
                    evidence: soundName.map { [.init(source: soundEvidence, id: $0)] } ?? [])
                let outcome = try await router.tell(matter, reach: .pinned(.mac, from: nil), turn: turn)
                guard let verdict = outcome.destinationOutcomes["mac"] else {
                    finished.resume(.from(.notDelivered(reason: "The matter has no Mac door"), id: id))
                    return
                }
                finished.resume(.from(verdict, id: id, held: outcome.deferredForQuietHours))
            } catch {
                finished.resume(.from(.unknown(sent: false, reason: error.localizedDescription), id: id))
            }
        }
        let ceiling = ContinuousClock.now.advanced(by: .seconds(5))
        let until = deadline.map { min($0, ceiling) } ?? ceiling
        return await finished.wait(budget: .init(deadline: until), cancellingWith: .from(.unknown(sent: false,
            reason: "The matter's Mac delivery is still pending"), id: id),
            onCancel: { if ContinuousClock.now < until { task.cancel() } })
    }

    public static func post(title: String, body: String, userInfo: [String: String] = [:], deadline: ContinuousClock.Instant?) {
        delivery.withLock { state in
            guard !state.stopped else { return }
            let id = UUID()
            state.posts[id] = Task {
                let result = await postAndReport(title: title, body: body, userInfo: userInfo, deadline: deadline)
                if let error = result.error { nativeLog("notification %@: %@", result.identifier, error) }
                _ = delivery.withLock { $0.posts.removeValue(forKey: id) }
            }
        }
    }

    /// A banner on this Mac, as UI physics where the person just acted; anything for the person is told through the router and reaches the Mac as its door.
    public static func postAndReport(
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        soundName: String? = nil,
        deadline: ContinuousClock.Instant?
    ) async -> NativeAgentNotificationPostResult {
        await banner(title: title, body: body, userInfo: userInfo, soundName: soundName, identifier: UUID().uuidString.lowercased(),
                     deadline: deadline)
    }

    /// One post, joined for at most five seconds; an OS callback that lands later is still the post's own (the router settles its door from it).
    static func banner(title: String, body: String, userInfo: [String: String], soundName: String? = nil, identifier: String,
                       dataRoot: URL = PersistenceCore.defaultDataRoot(),
                       deadline outerDeadline: ContinuousClock.Instant? = nil) async -> NativeAgentNotificationPostResult {
        let finished = ContinuationOnce<NativeAgentNotificationPostResult>()
        let operation = UUID()
        let task: Task<Void, Never>? = delivery.withLock { state in
            guard !state.stopped, !Task.isCancelled else { return nil }
            let task = Task {
                var info = userInfo
                info["eventId"] = info["eventId"] ?? identifier
                if let session = info["sessionId"] { info[NativeAgentNotificationActions.sessionKey] = session }
                if let handle = info["taskId"] { info[NativeAgentNotificationRoute.deskHandleKey] = handle }
                if info["source"] == "mac_notify", info[NativeAgentNotificationActions.sessionKey] == nil {
                    info[NativeAgentNotificationActions.newConversationKey] = "true"
                }
                var sound = soundName
                if userInfo["eventId"] == identifier {
                    do {
                        guard let matter = try await ForPerson.at(dataRoot).matter(identifier) else { throw CocoaError(.fileReadNoSuchFile) }
                        if let open = matter.face?.row?.open, open.hasPrefix("page:") {
                            info[NativeAgentNotificationRoute.pageKey] = String(open.dropFirst(5))
                        }
                        if let requested = matter.evidence.first(where: { $0.source == soundEvidence }) { sound = requested.id }
                    } catch {
                        finished.resume(.from(.notDelivered(reason: error.localizedDescription), id: identifier))
                        _ = delivery.withLock { $0.posts.removeValue(forKey: operation) }
                        return
                    }
                }
                let result = await postAccepted(title: title, body: body, userInfo: info, soundName: sound, identifier: identifier)
                if result.posted, userInfo["eventId"] == identifier {
                    await settle {
                        do {
                            try await ForPerson.at(dataRoot).accepted(identifier, .mac,
                                evidence: .init(source: "macos/notifications", id: identifier))
                        } catch { nativeLog("Mac banner %@ receipt unavailable: %@", identifier, error.localizedDescription) }
                    }
                }
                finished.resume(result)
                _ = delivery.withLock { $0.posts.removeValue(forKey: operation) }
            }
            state.posts[operation] = task
            return task
        }
        guard let task else { return .from(.notDelivered(reason: "Engine shutdown; banner not admitted"), id: identifier) }
        let ceiling = ContinuousClock.now.advanced(by: .seconds(5))
        let deadline = outerDeadline.map { min($0, ceiling) } ?? ceiling
        return await finished.wait(budget: .init(deadline: deadline), cancellingWith: .from(.unknown(sent: false,
                reason: "Native notification outcome is still pending"), id: identifier),
                onCancel: { if ContinuousClock.now < deadline { task.cancel() } })
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
