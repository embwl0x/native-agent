import AttentionRouting
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
            _ = try await SlackConnectorActions.postMessage(input: input, dataRoot: dataRoot)
        }
    ))
}
