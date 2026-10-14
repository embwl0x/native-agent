import EngineRuntime
import Privacy
import Foundation
import ApprovalTransactions
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
import ApprovalInbox
import WorkshopExecution
import Browser

extension AppToolExecutor {
    /// Read the last report, or explicitly run checks (false) or repair (true).
    @MainActor
    static func doctorStatus(repair: Bool?) async throws -> JSONValue {
        guard let appModel = NativeAgentAppCoordinator.shared.appModel else {
            return AppToolExecutor.unattachedFailure()
        }
        if let repair {
            if case .unavailable(let reason) = await appModel.runDoctor(repair: repair, repairScope: .button) {
                return AppToolExecutor.failure("doctor_unavailable", "Doctor did not run: \(reason)")
            }
        }
        return try await appModel.engine.doctor.toolStatusEnvelope()
    }

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
        doctorStatusProvider: (@Sendable (_ repair: Bool?) async throws -> JSONValue)? = nil,
        telegramStatusProvider: (@Sendable () async throws -> JSONValue)? = nil,
        humanConversationReplyHandler: (@Sendable ([String: JSONValue]) async throws -> JSONValue)? = nil
    ) {
        self.init(
            securityCenter: securityCenter, enforceAutonomySecurity: enforceAutonomySecurity,
            browserActionRunner: browserActionRunner ?? Self.defaultBrowserActionRunner,
            chrome: { NativeAgentEngine.live.chrome },
            macPersonAway: MacScreenLock.personAway,
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            mobileNotificationSender: mobileNotificationSender,
            macNotificationSender: macNotificationSender,
            macIntegrationPermissionStore: macIntegrationPermissionStore,
            doctorStatusProvider: doctorStatusProvider ?? { try await Self.doctorStatus(repair: $0) },
            telegramStatusProvider: telegramStatusProvider ?? { try await TelegramFacade(dataRoot: PersistenceCore.defaultDataRoot()).toolStatusEnvelope() },
            humanConversationReplyHandler: humanConversationReplyHandler ?? { input in
                try await NativeAgentEngine.live.agents.humanReplies.reply(input: input)
            },
            workshopStepDecider: { id, approve in
                try await ApprovalTransactionCoordinator.app().decideBlockedWorkshopStep(
                    id: id, approve: approve, runner: { NativeAgentEngine.makeWorkshopExecutionRunner() })
            },
            quietHost: { NativeAgentAppCoordinator.shared.appModel.map(AppQuietToolHost.init) },
            presentation: AppQuietToolPresentation(), interactions: AppToolInteractionResolver()
        )
    }
    static func defaultBrowserActionRunner(
        actionId: String,
        dryRun: Bool,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        return try await defaultBrowserActionRunner(
            actionId: actionId, dryRun: dryRun, input: input,
            chrome: { NativeAgentEngine.live.chrome }, macPersonAway: MacScreenLock.personAway,
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            platform: BrowserToolPlatformPort(
                setUpChrome: {
                    let setup = await ChromeExtensionFolder.setUp()
                    return (setup.folder, setup.extensionsPageOpened, setup.message)
                },
                readStatus: {
                    try await BrowserActionRoutes.app.visibleBrowserStatus(JSONValue.fromEncodable(
                        try await RuntimeReadProjection.getBrowserStatus(dataRoot: PersistenceCore.defaultDataRoot())))
                },
                runNativeAction: { actionId, dryRun, input in
                    let receipt = try await NativeActionRoutes.runNativeAction(
                        id: actionId, dryRun: dryRun, input: try jsonObjectToAny(input), dataRoot: nil, browser: .app)
                    return try JSONValue.fromEncodable(receipt)
                }
            ))
    }

    private static func jsonObjectToAny(_ input: [String: JSONValue]) throws -> [String: Any] {
        let data = try JSONValue.object(input).serializedData(pretty: false)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }


}
