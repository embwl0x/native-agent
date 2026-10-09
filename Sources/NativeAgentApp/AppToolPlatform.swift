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
import ApprovalInbox
import WorkshopExecution

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
        doctorStatusProvider: (@Sendable (_ repair: Bool?) async throws -> JSONValue)? = nil,
        telegramStatusProvider: (@Sendable () async throws -> JSONValue)? = nil,
        humanConversationReplyHandler: (@Sendable ([String: JSONValue]) async throws -> JSONValue)? = nil
    ) {
        self.init(
            securityCenter: securityCenter, enforceAutonomySecurity: enforceAutonomySecurity,
            browserActionRunner: browserActionRunner ?? Self.defaultBrowserActionRunner,
            chrome: { NativeAgentEngine.live.chrome },
            macPersonAway: Self.macPersonAway,
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            mobileNotificationSender: mobileNotificationSender,
            macNotificationSender: macNotificationSender,
            macIntegrationPermissionStore: macIntegrationPermissionStore,
            doctorStatusProvider: doctorStatusProvider ?? { try await AppToolHealthHost.doctorStatus(repair: $0) },
            telegramStatusProvider: telegramStatusProvider ?? AppToolHealthHost.telegramStatus,
            humanConversationReplyHandler: humanConversationReplyHandler ?? { input in
                try await NativeAgentEngine.live.agents.humanReplies.reply(input: input)
            },
            workshopStepDecider: Self.decideBlockedWorkshopStep,
            quietHost: { QuietSelfAdmin.shared.appModel.map(AppQuietToolHost.init) },
            presentation: AppQuietToolPresentation(), interactions: AppToolInteractionResolver()
        )
    }
    static func defaultBrowserActionRunner(
        actionId: String,
        dryRun: Bool,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        let client = NativeClient()
        return try await defaultBrowserActionRunner(
            actionId: actionId, dryRun: dryRun, input: input,
            chrome: { NativeAgentEngine.live.chrome }, macPersonAway: Self.macPersonAway,
            motorActionObserver: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) },
            platform: BrowserToolPlatformPort(
                setUpChrome: {
                    let setup = await ChromeExtensionFolder.setUp()
                    return (setup.folder, setup.extensionsPageOpened, setup.message)
                },
                readStatus: {
                    try await NativeClient.browserActionRoutes.visibleBrowserStatus(
                        JSONValue.fromEncodable(try await client.getBrowserStatus()))
                },
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

    /// Deny or Approve on the Desk's waiting step (MacWorkOverviewDetail), for
    /// the agent: the same `rejectStep` / `approveStep`, decided in her name.
    /// Only the step the task is blocked on; approving is User's below Full
    /// Mac, and the door refuses it there.
    static func decideBlockedWorkshopStep(id: String, approve: Bool) async throws -> JSONValue {
        let client = NativeClient()
        guard let execution = try await client.makeWorkshopExecutionRunner().getWorkshopExecution(id) else {
            return .object(["status": .string("not_found"), "id": .string(id),
                "detail": .string("No Desk task has this execution id. app workshop.status lists them.")])
        }
        // "manual" is the person's own: the Desk, the iPhone, Siri. His work is
        // not hers to stop. Hers is "agent" (workshop_submit) or background.
        guard approve || execution.triggerSource != "manual" else {
            return .object(["status": .string("not_yours"), "id": .string(id),
                "detail": .string("The person started this task, so denying its step is his call; nothing was denied. Tell him what is wrong with the step, or ask him to deny it on the Desk.")])
        }
        guard execution.status == "blocked_on_approval", !execution.currentStepId.isEmpty else {
            return .object(["status": .string("not_blocked"), "id": .string(id), "execution_status": .string(execution.status),
                "detail": .string("This task is \(execution.status), not waiting on a step approval, so there is nothing to \(approve ? "approve" : "deny").")])
        }
        let provenance = ApprovalResolutionProvenance.local(
            decidedBy: PersonaCompiler.agentDisplayName(dataRoot: PersistenceCore.defaultDataRoot()))
        if approve {
            let record = try await client.approveStep(executionId: id, stepId: execution.currentStepId, provenance: provenance)
            return .object(["status": .string("approved"), "id": .string(id), "step_id": .string(execution.currentStepId),
                "execution_status": .string(record.status),
                "detail": .string("Approved the waiting step; the task runs on from it.")])
        }
        let record = try await client.rejectStep(executionId: id, stepId: execution.currentStepId, provenance: provenance)
        return .object(["status": .string("rejected"), "id": .string(id), "step_id": .string(execution.currentStepId),
            "execution_status": .string(record.status),
            "detail": .string("Denied the waiting step; the task stops without running it.")])
    }

    static func macPersonAway() -> Bool {
        if MacScreenLock.isLocked() { return true }
        guard let any = CGEventType(rawValue: ~0) else { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        return idle.isFinite && idle >= 180
    }

}
