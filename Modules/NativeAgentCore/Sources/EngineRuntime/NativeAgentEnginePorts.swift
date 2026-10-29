import Foundation
import os
import AttentionRouting
import BackgroundWork
import Desk
import NativeAgentCore
import TriggerScheduler
import WorkshopExecution
import Connectors
import Browser
import Agents
import AppToolRuntime
import ChatTurnRuntime
import ChatTurnContracts
import AgentConversations
import Cognition
import CognitiveSubstrate
import DeviceSync
import PersistenceCore
import StandingBots
import TrustCenter
import ToolExecution
import Senses
import NativeAgentShared
// Blueprint: | `NativeAgentEnginePorts.swift` | Once-installed native host factories, body effects and shared EngineCognitionHost defaults; pure readout faces bind the selected Parts version through the no-effect authored host; read-part calls bind the existing ToolsFacade originating door and narrow the pinned candidate to native-permitted read actions/capabilities |

/// Platform hosts supplied once to Core's composition root. The factories
/// bind existing app adapters; dispatch and chat policy stay in the engine.
public struct NativeAgentEnginePorts: Sendable {
    public let backgroundWork: any EngineBackgroundWorkHost
    public let connectorStatus: AppConnectorStatusPlatform
    public let cognitionHost: any CognitionHost
    public let deviceSyncHost: any DeviceSyncHost
    public let macIntegration: any MacIntegrationToolBridge
    public let a2aPushConfiguration: @Sendable (AgentPeerContact) async -> JSONValue?
    public let completionSender: @Sendable (URL) -> any AgentBridgeCompletionSending
    public let standingBotQueue: BotRunQueue
    public let appTools: @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor
    public let chatPlatform: ChatToolPlatformPort

    public init(
        backgroundWork: any EngineBackgroundWorkHost,
        connectorStatus: AppConnectorStatusPlatform,
        cognitionHost: any CognitionHost,
        deviceSyncHost: any DeviceSyncHost,
        macIntegration: any MacIntegrationToolBridge,
        a2aPushConfiguration: @escaping @Sendable (AgentPeerContact) async -> JSONValue?,
        completionSender: @escaping @Sendable (URL) -> any AgentBridgeCompletionSending,
        standingBotQueue: BotRunQueue,
        appTools: @escaping @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor,
        chatPlatform: ChatToolPlatformPort
    ) {
        self.backgroundWork = backgroundWork
        self.connectorStatus = connectorStatus
        self.cognitionHost = cognitionHost
        self.deviceSyncHost = deviceSyncHost
        self.macIntegration = macIntegration
        self.a2aPushConfiguration = a2aPushConfiguration
        self.completionSender = completionSender
        self.standingBotQueue = standingBotQueue
        self.appTools = appTools
        self.chatPlatform = chatPlatform
    }
}

extension CognitionHost {
    public func phoneNotificationTargetCount(dataRoot: URL) async throws -> Int {
        try await SwiftNativeAPNSSender().deliverableTargetCount(dataRoot: dataRoot)
    }

    public func readoutFace(id: String, input: JSONValue, version: String, dataRoot: URL) async -> PartCallResult<PartFace> {
        let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot) { _, _ in nil }
        return await OwnedProgramInvocation.$host.withValue(host) {
            await Parts(root: dataRoot).face(id: id, input: input, version: version)
        }
    }

    public func inQuietHours(at date: Date, dataRoot: URL) -> Bool {
        AttentionRouter.inQuietHours(at: date, dataRoot: dataRoot)
    }

    public func unattendedWorkAllowed(dataRoot: URL) async -> Bool {
        await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
    }

    public func backgroundWorkLease(dataRoot: URL) -> any BackgroundWorkLeasing { BackgroundWorkLease(dataRoot: dataRoot) }

    public func backgroundWorkWindow(_ date: Date) -> String { WorkshopPump.windowKey(date) }

    public func pursuitChoiceTotal(for item: DeskItem, now: Date) -> Double? {
        WorkshopPump.choiceScore(for: item, now: now)?.total
    }

    public func schedulerJobRows(at path: URL) throws -> [JSONValue] {
        try SwiftNativeTriggerScheduler.readJobsChecked(at: path)
    }

    public func archiveSupersededMorningBriefs(dataRoot: URL) async {
        await TriggerNotificationInbox.archiveSupersededMorningBriefs(dataRoot: dataRoot)
    }

}

public struct EngineStudioWanderClient: StudioWanderClientPort {
    let engine: NativeAgentEngine

    public init(engine: NativeAgentEngine) { self.engine = engine }

    public func toolDispatchClient() -> any ToolDispatchClient {
        engine.toolDispatchClient(enforceAppAutonomy: false)
    }

    public func chatClient(tools: any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient {
        engine.chatClient(tools: tools)
    }
}

extension BackgroundWorkLease: BackgroundWorkLeasing {}

extension AttentionRouter {
    public func deliverShoulderTap(
        eventId: String, title: String, body: String, reason: String,
        userInfo: [String: String], at date: Date
    ) async throws -> String? {
        // Her knock points at the conversation the Mac and the phone show, so
        // it goes to the phone, never to a Telegram chat that lacks it.
        let outcome = try await route(
            eventId: eventId, importance: .informational, title: title, body: body,
            reason: reason, userInfo: userInfo, pinnedTo: .phone, at: date
        )
        guard outcome.delivery != .none, !outcome.suppressed else { return nil }
        return outcome.delivery.rawValue
    }
}

extension NativeAgentEnginePorts {
    private static let appPorts = OSAllocatedUnfairLock<(@Sendable (URL) -> Self)?>(initialState: nil)

    public static func installAppPorts(_ factory: @escaping @Sendable (URL) -> Self) {
        appPorts.withLock {
            precondition($0 == nil, "App ports are already installed")
            $0 = factory
        }
    }

    public static func app(dataRoot: URL) -> Self {
        let factory = appPorts.withLock {
            guard let appPorts = $0 else { preconditionFailure("Install app ports before constructing the engine") }
            return appPorts
        }
        return factory(dataRoot)
    }
}

public struct EngineCognitionHost: CognitionHost {
    private let attention: AttentionRouter

    public init(attention: AttentionRouter) { self.attention = attention }

    public func callReadPart(id: String, input: JSONValue, actions: Set<String>, dataRoot: URL, origin: String) async throws -> JSONValue {
        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native(origin)) {
            switch await Parts(root: dataRoot).call(id: id, input: input,
                within: .init(actions: actions, capabilities: ["app_data_read"]), as: JSONValue.self) {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }
    public func deliverShoulderTap(
        eventId: String, title: String, body: String, reason: String,
        userInfo: [String: String], at date: Date
    ) async throws -> String? {
        try await attention.deliverShoulderTap(
            eventId: eventId, title: title, body: body, reason: reason, userInfo: userInfo, at: date)
    }


    public func backgroundLLMClient(dataRoot: URL, cognition: NativeCognitionRuntime?) -> any LLMClient {
        NativeAgentEngine.makeSharedLLMClient(dataRoot: dataRoot, cognitionRuntime: cognition)
    }

    public func studioWanderClient(dataRoot: URL, usesLiveAppBody: Bool) -> any StudioWanderClientPort {
        EngineStudioWanderClient(engine: usesLiveAppBody ? NativeAgentEngine.live : NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot), hasBody: false))
    }
}
