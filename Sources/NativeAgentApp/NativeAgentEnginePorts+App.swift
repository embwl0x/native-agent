import AppToolRuntime
import ApprovalTransactions
import Privacy
import SchedulerExecution
import Foundation
import TriggerScheduler
import AttentionRouting
import Agents
import ChatOrchestration
import ChromeControl
import Cognition
import MacControl
import CognitiveSubstrate
import Context
import ContextFlow
import DeviceSync
import NativeAgentCore
import PersistenceCore
import Desk
import StandingBots
import TrustCenter
import WorkshopExecution


@_exported import EngineRuntime

// Preserve the app transcript type when ChatOrchestration is also imported.
typealias ChatMessage = EngineRuntime.ChatMessage

extension ToolsFacade {
    nonisolated convenience init(dataRoot: URL) {
        self.init(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot))
    }
}

extension NativeAgentEnginePorts {
    static func app(dataRoot: URL) -> Self {
        Self(
            cognitionHost: AppCognitionHost(),
            deviceSyncHost: AppDeviceSyncHost(),
            macIntegration: MacIntegrationBridgeImpl(),
            agentBridge: AppAgentBridgePort(),
            completionSender: { LiveAgentBridgeCompletionSender(dataRoot: $0) },
            standingBotQueue: AppStandingBotQueuePort(dataRoot: dataRoot),
            appTools: { AppToolExecutor(securityCenter: $0, enforceAutonomySecurity: $1) },
            interactions: AppToolInteractionResolver(),
            chatPlatform: ChatToolPlatformPort(
                grok: { await GrokBotConnection.perform(plan: $0, dataRoot: $1, inner: $2, surface: $3,
                                                       port: AppGrokBotConnectionPort()) },
                desktopChat: { await DesktopChatRoute.perform(plan: $0, dataRoot: $1) },
                desktop: { await NativeAgentEngine.live.agents.desktop.run(plan: $0, inner: $1, surface: $2) }
            ),
            catalogPosture: { await NativeAgentEngine.liveCognition.organismBehaviorPosture() },
            evolutionBridge: { EvolutionToolBridgeImpl(dataRoot: $0) },
            connectorActionStatuses: { try await NativeClient.checkedConnectorActionStatuses(root: dataRoot) }
        )
    }
}

extension NativeAgentEngine {
    static let live: NativeAgentEngine = {
        let dataRoot = PersistenceCore.defaultDataRoot()
        return NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot))
    }()
    /// The running app's mind. The live root is built with the app's body.
    static var liveCognition: NativeCognitionRuntime { live.cognition! }
    /// The running app's device sync; the live root is built with a body.
    static var liveDeviceSync: DeviceSync { live.deviceSync! }

}

private struct AppAgentBridgePort: EngineAgentBridgePort {
    func a2aPushConfiguration(for peer: AgentPeerContact) async -> JSONValue? {
        let port = ClaudeBridge.shared.activePort
        guard port != 0, let secret = try? AgentPeerCredentials.read(peerID: peer.id), !secret.isEmpty else { return nil }
        return .object(["url": .string("http://127.0.0.1:\(port)/a2a/notifications"),
            "authentication": .object(["scheme": .string("Bearer"), "credentials": .string(secret)])])
    }
}

private struct AppStandingBotQueuePort: EngineStandingBotQueuePort {
    let dataRoot: URL
    func enqueueRun(bot: UUID) throws -> UUID {
        try BotRunQueue(dataRoot: dataRoot).enqueueRequest(bot: bot)
    }
}

/// The app-owned pieces the resident mind reaches: the attention router and
/// device sync, the Workshop's lease and pursuit score, the background LLM
/// client, the dream action, the scheduler's jobs file, morning briefs and
/// her Studio hour.
struct AppCognitionHost: CognitionHost {
    func inQuietHours(at date: Date, dataRoot: URL) -> Bool {
        AttentionRouter.inQuietHours(at: date, dataRoot: dataRoot)
    }

    func deliverShoulderTap(
        eventId: String, title: String, body: String, reason: String,
        userInfo: [String: String], at date: Date
    ) async throws -> String? {
        // Her knock points at the conversation the Mac and the phone show, so
        // it goes to the phone, never to a Telegram chat that lacks it.
        let outcome = try await AttentionRouter.shared.route(
            eventId: eventId, importance: .informational, title: title, body: body,
            reason: reason, userInfo: userInfo, pinnedTo: .phone, at: date
        )
        guard outcome.delivery != .none, !outcome.suppressed else { return nil }
        return outcome.delivery.rawValue
    }

    func sendToOwnerTelegram(sessionId: String, text: String, dataRoot: URL) async -> Bool? {
        guard let owner = await ApprovalChatCards.ownerDM(boundTo: sessionId, dataRoot: dataRoot) else { return nil }
        guard let telegram = TelegramApprovalFilerRef.shared.current() else { return false }
        do {
            try await telegram.sendChatCard(text: NativeAppSecretRedactor.redactText(text), chatId: owner,
                                            markup: .object(["inline_keyboard": .array([])]))
            return true
        } catch {
            NSLog("reach: Telegram send failed: %@", error.localizedDescription)
            return false
        }
    }

    func writeSyncSnapshots() async { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }

    func backgroundLLMClient(dataRoot: URL, cognition: NativeCognitionRuntime?) -> any LLMClient {
        BackgroundLoopsAssembly.makeSharedLLMClient(dataRoot: dataRoot, cognitionRuntime: cognition)
    }

    func unattendedWorkAllowed(dataRoot: URL) async -> Bool {
        await BackgroundLoopsAssembly.unattendedWorkAllowed(dataRoot: dataRoot)
    }

    func backgroundWorkLease(dataRoot: URL) -> any BackgroundWorkLeasing { BackgroundWorkLease(dataRoot: dataRoot) }

    func backgroundWorkWindow(_ date: Date) -> String { WorkshopPump.windowKey(date) }

    func pursuitChoiceTotal(for item: DeskItem, now: Date) -> Double? {
        WorkshopPump.choiceScore(for: item, now: now)?.total
    }

    func schedulerJobRows(at path: URL) throws -> [JSONValue] {
        try SchedulerDueJobRunner.readJobRowsChecked(at: path)
    }

    func archiveSupersededMorningBriefs(dataRoot: URL) async {
        await TriggerNotificationInbox.archiveSupersededMorningBriefs(dataRoot: dataRoot)
    }

    func studioWanderClient(dataRoot: URL, usesLiveAppBody: Bool) -> any StudioWanderClientPort {
        AppStudioWanderClient(engine: usesLiveAppBody ? NativeAgentEngine.live : NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot), hasBody: false))
    }
}

private struct AppStudioWanderClient: StudioWanderClientPort {
    let engine: NativeAgentEngine

    func toolDispatchClient() -> any ToolDispatchClient {
        engine.toolDispatchClient(enforceAppAutonomy: false)
    }

    func chatClient(tools: any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient {
        engine.chatClient(tools: tools)
    }
}

extension BackgroundWorkLease: @retroactive BackgroundWorkLeasing {}
