import UserNotifications
import NativeAgentShared

// Expiry races donation; one lock makes delivery exactly once and protects both retained fields.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                            withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Immutable UNNotificationContent lacks ObjC Sendable annotation; keep the framework request out of the task.
        nonisolated(unsafe) let content = request.content
        lock.lock()
        handler = contentHandler
        original = content
        lock.unlock()
        Task {
            let alert: UNNotificationContent
            do {
                let routed = try await MobileNotificationRouting.resolvingCloudKitRouting(content)
                retainForExpiry(routed)
                do { alert = try await CommunicationNotification.decorate(routed) }
                catch {
                    ModuleLog(category: "NativeAgentMobile")("[NativeAgentMobile] Communication notification unavailable: %@", error.localizedDescription)
                    alert = Self.unavailable(routed, reason: "Notification identity could not be prepared: \(error.localizedDescription)")
                }
            }
            catch {
                ModuleLog(category: "NativeAgentMobile")("[NativeAgentMobile] Notification routing unavailable: %@", error.localizedDescription)
                alert = Self.unavailable(content, reason: "Notification routing could not be read: \(error.localizedDescription)")
            }
            finish(alert)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        ModuleLog(category: "NativeAgentMobile")("[NativeAgentMobile] Communication notification service deadline expired")
        finish(nil)
    }

    private func retainForExpiry(_ content: UNNotificationContent) {
        lock.lock()
        if handler != nil { original = content }
        lock.unlock()
    }

    private static func unavailable(_ retained: UNNotificationContent, reason: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = retained.title
        content.body = "\(reason). Open NativeAgent and refresh Activity to recover this notification.\n\nRetained message: \(retained.body)"
        // Failed routing cannot truthfully advertise an approval or reply action.
        content.userInfo = ["screen": "activity", "source": "notification_preparation_failed"]
        return content
    }

    @discardableResult
    private func finish(_ content: UNNotificationContent?) -> Bool {
        lock.lock()
        let callback = handler
        let result = content ?? original.map { Self.unavailable($0, reason: "Notification preparation did not finish before iOS's deadline") }
        handler = nil
        original = nil
        lock.unlock()
        if let callback, let result {
            callback(result)
            return true
        }
        return false
    }
}
