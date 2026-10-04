import AttentionRouting
import Foundation
import SlackConnector
import TelegramBot

extension AttentionRouter {
    static let shared = AttentionRouter(delivery: AttentionDeliveryPorts(
        phone: { title, body, userInfo in
            try await NativeAgentEngine.liveDeviceSync.engine.sendNotificationToPairedDevices(
                title: title,
                body: body,
                userInfo: userInfo
            )
        },
        telegram: { token, destination, text in
            try await TelegramPollLoop.defaultSendMessage(token, destination, text)
        },
        slack: { input, dataRoot in
            let result = try await SlackConnectorActions.postMessage(input: input, dataRoot: dataRoot)
            guard case .object(let envelope) = result, envelope["ok"] == .bool(true) else {
                throw NSError(domain: "AttentionRouter", code: -502, userInfo: [
                    NSLocalizedDescriptionKey: "Slack did not accept the notification."
                ])
            }
        }
    ))
}
