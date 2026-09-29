import Privacy
import Foundation
import AttentionRouting
import Agents
import ChatOrchestration
import Cognition
import CognitiveSubstrate
import MacIntegration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ProviderRouting
import ToolRegistry
import TrustCenter
import DeviceSync

import AppToolRuntime
import ChromeControl
import CoreGraphics
import MacControl

extension AppToolExecutor {
    convenience init(
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        enforceAutonomySecurity: Bool = true,
        browserActionRunner: (@Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue)? = nil,
        mobileNotificationSender: @escaping @Sendable (String, String, [String: String]) async throws -> MobileNotificationDeliveryReceipt = { title, body, userInfo in
            try await AppToolExecutor.defaultMobileNotificationSender(
                title: title, body: body, userInfo: userInfo, router: AttentionRouter.shared)
        },
        macNotificationSender: @escaping @Sendable (String, String) async throws -> NativeAgentNotificationPostResult = { title, body in
            await NativeAgentNotifications.postMessage(title: title, body: body)
        },
        macIntegrationPermissionStore: MacIntegrationPermissionStore = .shared,
        doctorStatusProvider: (@Sendable () async throws -> JSONValue)? = nil,
        telegramStatusProvider: (@Sendable () async throws -> JSONValue)? = nil,
        reflexReviewHandler: @escaping @Sendable (
            String,
            OrganismReflexReviewDecision,
            String?,
            String
        ) async -> OrganismReflexReviewApplyOutcome = { candidateID, decision, note, surface in
            await NativeAgentEngine.liveCognition.applyOrganismReflexReview(
                id: candidateID,
                decision: decision,
                note: note,
                reviewedBy: AppToolExecutor.defaultReflexReviewerIdentity(),
                source: "reflex_review:\(surface)"
            )
        },
        humanConversationReplyHandler: (@Sendable ([String: JSONValue]) async throws -> JSONValue)? = nil
    ) {
        self.init(
            securityCenter: securityCenter, enforceAutonomySecurity: enforceAutonomySecurity,
            browserActionRunner: browserActionRunner ?? Self.defaultBrowserActionRunner,
            chrome: { NativeAgentEngine.live.chrome },
            pageIDs: QuietPages.ids, drawOnlyPageIDs: QuietPages.drawOnly.map(\.id),
            macPersonAway: Self.macPersonAway,
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            mobileNotificationSender: mobileNotificationSender,
            macNotificationSender: macNotificationSender,
            macIntegrationPermissionStore: macIntegrationPermissionStore,
            doctorStatusProvider: doctorStatusProvider ?? AppToolHealthHost.doctorStatus,
            telegramStatusProvider: telegramStatusProvider ?? AppToolHealthHost.telegramStatus,
            reflexReviewHandler: reflexReviewHandler,
            humanConversationReplyHandler: humanConversationReplyHandler ?? { input in
                try await NativeAgentEngine.live.agents.humanReplies.reply(input: input)
            },
            quietHost: { QuietSelfAdmin.shared.appModel.map(AppQuietToolHost.init) },
            presentation: AppQuietToolPresentation(), interactions: AppToolInteractionResolver()
        )
    }
    static func defaultBrowserActionRunner(
        actionId: String,
        dryRun: Bool,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        let client = NativeClient(baseURL: "")
        return try await defaultBrowserActionRunner(
            actionId: actionId, dryRun: dryRun, input: input,
            chrome: { NativeAgentEngine.live.chrome }, macPersonAway: Self.macPersonAway,
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            platform: BrowserToolPlatformPort(
                setUpChrome: {
                    let setup = await ChromeExtensionFolder.setUp()
                    return (setup.folder, setup.extensionsPageOpened, setup.message)
                },
                readStatus: { try JSONValue.fromEncodable(try await client.getBrowserStatus()) },
                runNativeAction: { actionId, dryRun, input in
                    let receipt = try await client.runNativeAction(
                        id: actionId, dryRun: dryRun, input: try jsonObjectToAny(input))
                    return try JSONValue.fromEncodable(receipt)
                }
            ))
    }

    private static func jsonObjectToAny(_ input: [String: JSONValue]) throws -> [String: Any] {
        let data = try JSONValue.object(input).serializedData(pretty: false)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func macPersonAway() -> Bool {
        if MacScreenLock.isLocked() { return true }
        guard let any = CGEventType(rawValue: ~0) else { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        return idle.isFinite && idle >= 180
    }

}
