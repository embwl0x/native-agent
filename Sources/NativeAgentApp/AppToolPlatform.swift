import EngineRuntime
import Privacy
import Foundation
import ApprovalTransactions
import AttentionRouting
import Agents
import Cognition
import CognitiveSubstrate
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import ChatToolRuntime
import ChatTurnContracts
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
import Browser
// Blueprint: | `AppToolPlatform.swift` | Browser, notification and away bindings; shared speech client |

extension AppToolExecutor {
    /// Distinguish reading a retained report from explicitly running checks or repair.
    @MainActor
    static func doctorStatus(repair: Bool?, checkID: String?, turn: Turn) async throws -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else {
            return AppToolExecutor.unattachedFailure()
        }
        if let repair {
            if case .unavailable(let reason) = await appModel.runDoctor(repair: repair, repairScope: .button, checkID: checkID, turn: turn) {
                return AppToolExecutor.failure("doctor_unavailable", "Doctor did not run: \(reason)")
            }
        }
        return try await appModel.engine.doctor.toolStatusEnvelope(turn: turn)
    }

    convenience init(
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        enforceAutonomySecurity: Bool = true,
        browserActionRunner: (@Sendable (String, Bool, [String: JSONValue], Turn, AppActionExecution) async throws -> JSONValue)? = nil,
        mobileNotificationSender: @escaping @Sendable (String, String, [String: String], Turn) async throws -> AttentionOutcome = {
            title, body, userInfo, turn in
            try await AppToolExecutor.defaultMobileNotificationSender(
                title: title, body: body, userInfo: userInfo, router: AttentionRouter.shared, turn: turn)
        },
        macNotificationSender: @escaping @Sendable (String, String, Turn, ContinuousClock.Instant?) async throws -> NativeAgentNotificationPostResult = {
            title, body, turn, deadline in
            await NativeAgentNotifications.postMessage(title: title, body: body, router: .shared, turn: turn, deadline: deadline)
        },
        macIntegrationPermissionStore: MacIntegrationPermissionStore = .shared,
        doctorStatusProvider: (@Sendable (_ repair: Bool?, _ checkID: String?, _ turn: Turn) async throws -> JSONValue)? = nil,
        telegramStatusProvider: (@Sendable () async throws -> JSONValue)? = nil,
        humanConversationReplyHandler: (@Sendable ([String: JSONValue], Turn) async throws -> JSONValue)? = nil
    ) {
        self.init(
            securityCenter: securityCenter, enforceAutonomySecurity: enforceAutonomySecurity,
            browserActionRunner: browserActionRunner ?? { actionId, dryRun, input, turn, execution in
                try await Self.defaultBrowserActionRunner(actionId: actionId, dryRun: dryRun, input: input,
                    dataRoot: securityCenter.dataRoot, turn: turn, execution: execution)
            },
            chrome: { NativeAgentEngine.live.chrome },
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            mobileNotificationSender: mobileNotificationSender,
            macNotificationSender: macNotificationSender,
            macIntegrationPermissionStore: macIntegrationPermissionStore,
            doctorStatusProvider: doctorStatusProvider ?? { try await Self.doctorStatus(repair: $0, checkID: $1, turn: $2) },
            telegramStatusProvider: telegramStatusProvider ?? { try await TelegramFacade(dataRoot: PersistenceCore.defaultDataRoot()).toolStatusEnvelope() },
            humanConversationReplyHandler: humanConversationReplyHandler ?? { input, turn in
                try await NativeAgentEngine.live.agents.humanReplies.reply(turn: turn, input: input)
            },
            proactiveSpeechClient: { NativeAgentEngine.forRoot($0).chatClient(profile: .background) },
            attention: { AttentionRouter.shared },
            // Her window is one window: a turn from any door works the window that is attached.
            quietHost: {
                ApplicationLifetime.shared.appModel.map { model in
                    (try? BodyFacePresentation.current(model: model)).map { AppQuietToolHost(model, face: $0) } ?? AppQuietToolHost(model)
                }
            },
            presentation: AppQuietToolPresentation(),
            actionExecution: .init(invocation: .init(), deadlines: .init(), turnWork: .init()),
            bindPresentation: { turn in
                guard let model = ApplicationLifetime.shared.appModel else { throw FaceWireError.disconnected }
                let target: BodyFacePresentation
                if let connection = turn[FacePresentationPart.self] {
                    target = BodyFacePresentation(connection: connection, model: model)
                } else if let attached = try? BodyFacePresentation.current(model: model) {
                    target = attached
                } else { return nil }
                return AppToolPresentationBinding(host: { AppQuietToolHost(model, face: target) }, presentation: target)
            }
        )
    }
    static func defaultBrowserActionRunner(
        actionId: String,
        dryRun: Bool,
        input: [String: JSONValue], dataRoot: URL, turn: Turn, execution: AppActionExecution
    ) async throws -> JSONValue {
        return try await defaultBrowserActionRunner(
            actionId: actionId, dryRun: dryRun, input: input,
            chrome: { NativeAgentEngine.forRoot(dataRoot).chrome },
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            platform: BrowserToolPlatformPort(
                setUpChrome: {
                    (try await ChromeExtensionFolder.setUp(turn: turn,
                        context: execution.macOperation(dataRoot: NativeAgentEngine.live.dataRoot)), "Chrome connected.")
                },
                readStatus: {
                    try await BrowserActionRoutes.app.visibleBrowserStatus(JSONValue.fromEncodable(
                        try await RuntimeReadouts.getBrowserStatus(dataRoot: dataRoot)))
                },
                runNativeAction: { actionId, dryRun, input, turn, execution in
                    let receipt = try await NativeActionRoutes.runNativeAction(
                        id: actionId, dryRun: dryRun, input: try jsonObjectToAny(input), dataRoot: dataRoot, browser: .app,
                        turn: turn, execution: execution)
                    return try JSONValue.fromEncodable(receipt)
                }
            ), dataRoot: dataRoot, turn: turn, execution: execution)
    }

    private static func jsonObjectToAny(_ input: [String: JSONValue]) throws -> [String: Any] {
        let data = try JSONValue.object(input).serializedData(pretty: false)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolFailureError("The native action arguments did not serialize as an object. Nothing ran.",
                effects: .none, code: "invalid_arguments")
        }
        return object
    }


}
