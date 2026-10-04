import Foundation
import AttentionRouting
import GitHubConnector
import NativeAgentCore
import PersistenceCore

extension GitHubApprovalEdgeNotifier {
    static let shared = GitHubApprovalEdgeNotifier { eventId, title, body, userInfo in
        let outcome = try await AttentionRouter.shared.route(
            eventId: eventId, importance: .informational,
            title: title, body: body, userInfo: userInfo
        )
        let delivery = outcome.deliveryProjection
        if delivery.reachedAChannel { return .delivered }
        if delivery == .previouslyHandled { return .previouslyHandled }
        return .undelivered
    }
}

extension GitHubCommandRuntime {
    static let shared = GitHubCommandRuntime.live()

    static func live(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> GitHubCommandRuntime {
        let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
        return GitHubCommandRuntime(
            dataRoot: dataRoot,
            observationLoader: { item in
                try await GitHubConnectorActions.commandObservation(for: item, dataRoot: dataRoot)
            },
            notificationSender: { intent in
                guard usesLiveAppBody else {
                    throw NSError(
                        domain: "GitHubCommandRuntime",
                        code: 503,
                        userInfo: [NSLocalizedDescriptionKey: "canonical notification body unavailable for alternate data root"]
                    )
                }
                // Item 26: a GitHub command notification is Agent handing User a
                // decision — owner-waiting. Payload unchanged.
                let outcome = try await AttentionRouter.shared.route(
                    eventId: "github_command:\(intent.dedupKey)",
                    importance: .ownerWaiting,
                    title: intent.title,
                    body: intent.body,
                    userInfo: [
                        "kind": "github_command",
                        "githubCommandItemId": intent.itemId,
                        "dedupKey": intent.dedupKey,
                    ]
                )
                let delivery = outcome.deliveryProjection
                if let receipt = outcome.receipt {
                    let fields = JSONValue.object(receipt.deliveryFields())
                    return (delivery.rawValue, Self.failureDetail(fields))
                }
                let detail: String
                switch delivery {
                case .accepted, .queued: detail = "routed to \(outcome.delivery.rawValue)"
                case .previouslyHandled: detail = "already delivered under \(intent.dedupKey)"
                case .deferred: detail = "Not sent during quiet hours."
                case .noChannel: detail = "No notification channel was used."
                case .failed: detail = "Notification delivery failed."
                }
                return (delivery.rawValue, detail)
            },
            outcomeObserver: { model in
                guard usesLiveAppBody else { return }
                await NativeAgentEngine.liveCognition.observeMotorActionState(model)
            }
        )
    }

    private static func failureDetail(_ value: JSONValue) -> String {
        (try? value.serialize(pretty: false)).map { String($0.prefix(1_000)) } ?? "unknown bridge result"
    }
}
