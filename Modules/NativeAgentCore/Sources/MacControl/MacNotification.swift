import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
// Blueprint: | `MacNotification.swift` | Notification posting through the app's injected banner exit with truthful unverified acceptance |

extension SwiftNativeMacControl {
    // MARK: notify

    func handleNotify(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let title = body["title"]?.stringValue ?? ""
        let message = body["message"]?.stringValue ?? ""
        let sound = body["sound"]?.stringValue
        if title.isEmpty && message.isEmpty {
            throw MacControlError.missingField("title or message")
        }
        let started = now()
        let receipt: NotificationPostReceipt
        do {
            guard let notificationCenterAdapter else {
                throw MacControlError.notificationFailed("no Mac notification poster is wired into this client")
            }
            receipt = try await notificationCenterAdapter.postNotificationReceipt(
                title: title,
                message: message,
                soundName: sound
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "notify",
                output: .object(["title": .string(title), "message": .string(message)]),
                error: "notify failed: \(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        let receiptFields: [String: JSONValue] = [
            "submission": .string("accepted_for_delivery"),
            "access": .string(receipt.authorization.rawValue),
            "request_id": receipt.requestIdentifier.map { .string($0) } ?? .null,
            "delivery_observed": .bool(false),
        ]
        let outputFields: [String: JSONValue] = [
            "title": .string(title),
            "message": .string(message),
            "sound": sound.map { .string($0) } ?? .null,
            // `UNUserNotificationCenter.add` acknowledges only that the request was accepted. It cannot prove a banner appeared, sound played, or a person received it; keep the terminal operation receipt explicitly unverified until a
            // distinct observer supplies that evidence.
            "receipt": .object(receiptFields),
        ]
        return MacControlResult(
            ok: true,
            action: "notify",
            output: .object(outputFields),
            error: nil,
            durationMs: durationMs
        )
    }
}
