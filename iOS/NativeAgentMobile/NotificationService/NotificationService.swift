import UserNotifications

// The system expiry callback races donation. The lock owns both retained
// fields and makes delivery exactly once across those callbacks.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                            withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // UNNotificationContent is immutable; its ObjC declaration lacks
        // Sendable. Do not carry the framework-owned request into the task.
        nonisolated(unsafe) let content = MobileNotificationRouting.categorized(request.content)
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
                    NSLog("[NativeAgentMobile] Communication notification unavailable: %@", error.localizedDescription)
                    alert = routed
                }
            }
            catch {
                NSLog("[NativeAgentMobile] Notification routing unavailable: %@", error.localizedDescription)
                alert = content
            }
            finish(alert)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        NSLog("[NativeAgentMobile] Communication notification service deadline expired")
        finish(nil)
    }

    private func retainForExpiry(_ content: UNNotificationContent) {
        lock.lock()
        if handler != nil { original = content }
        lock.unlock()
    }

    @discardableResult
    private func finish(_ content: UNNotificationContent?) -> Bool {
        lock.lock()
        let callback = handler
        let result = content ?? original
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
