import Foundation
import Experiences
import os
import AttentionRouting
import BackgroundWork
import Desk
import NativeAgentCore
import TriggerScheduler
import Connectors
import Browser
import Agents
import AppToolRuntime
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import Cognition
import DreamREMCycle
import CognitiveSubstrate
import DeviceSync
import PersistenceCore
import StandingBots
import TrustCenter
import ToolExecution
import Senses
import NativeAgentShared
import TelegramBot
// Blueprint: | `NativeAgentEnginePorts.swift` | Native host factories and read faces; cognition's shoulder tap tells its conversation matter |

/// Supply platform hosts once; dispatch and chat policy remain in the engine.
public struct NativeAgentEnginePorts: Sendable {
    public let backgroundWork: any EngineBackgroundWorkHost
    public let connectorStatus: AppConnectorStatusPlatform
    public let cognitionHost: any CognitionHost
    public let deviceSyncHost: any DeviceSyncHost
    public let macIntegration: any ChatMacIntegrationToolBridge
    public let a2aPushConfiguration: @Sendable (AgentPeerContact) async throws -> JSONValue
    public let completionSender: @Sendable (URL) -> any AgentBridgeCompletionSending
    public let standingBotQueue: BotRunQueue
    public let appTools: @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor
    public let browserRoutes: BrowserActionRoutes
    public let connectorActions: @Sendable (NativeAgentEngine) -> any ConnectorActionPlatform
    public let chatPlatform: ChatToolPlatformPort

    public init(
        backgroundWork: any EngineBackgroundWorkHost,
        connectorStatus: AppConnectorStatusPlatform,
        cognitionHost: any CognitionHost,
        deviceSyncHost: any DeviceSyncHost,
        macIntegration: any ChatMacIntegrationToolBridge,
        a2aPushConfiguration: @escaping @Sendable (AgentPeerContact) async throws -> JSONValue,
        completionSender: @escaping @Sendable (URL) -> any AgentBridgeCompletionSending,
        standingBotQueue: BotRunQueue,
        appTools: @escaping @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor,
        browserRoutes: BrowserActionRoutes,
        connectorActions: @escaping @Sendable (NativeAgentEngine) -> any ConnectorActionPlatform,
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
        self.browserRoutes = browserRoutes
        self.connectorActions = connectorActions
        self.chatPlatform = chatPlatform
    }
}

extension CognitionHost {
    public func telegramOwnerUserId(dataRoot: URL) throws -> Int64? {
        try TelegramConfig.loadSavedConfiguration(dataRoot: dataRoot, resolveCredential: false)?.ownerUserId
    }

    public func phoneNotificationTargetCount(dataRoot: URL) async throws -> Int {
        try await SwiftNativeAPNSSender().deliverableTargetCount(dataRoot: dataRoot)
    }

    public func readoutFace(id: String, input: JSONValue, version: String, dataRoot: URL) async -> PartCallResult<PartFace> {
        await NativeAgentEngine.forRoot(dataRoot).tools.face(id: id, input: input, version: version)
    }

    public func inQuietHours(at date: Date, dataRoot: URL) -> Bool {
        AttentionRouter.inQuietHours(at: date, dataRoot: dataRoot)
    }

    public func unattendedWorkAllowed(dataRoot: URL) async -> Bool {
        await UnattendedWork.allowed(dataRoot: dataRoot)
    }

    public func backgroundWorkLease(dataRoot: URL) -> any BackgroundWorkLeasing { BackgroundWorkLease(dataRoot: dataRoot) }

    public func backgroundWorkWindow(_ date: Date) -> String { DeskPursuitChoice.windowKey(date) }

    public func backgroundWorkWindowEnd(_ date: Date) -> Date { DeskPursuitChoice.windowEnd(date) }

    public func pursuitChoiceTotal(for item: DeskItem, now: Date) -> Double? {
        DeskPursuitChoice.score(for: item, now: now)?.total
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
        userInfo: [String: String], at date: Date, turn: Turn?
    ) async throws -> String? {
        // Send conversation attention to the phone; Telegram cannot open the referenced Mac conversation.
        let outcome = try await tell(Matter(id: eventId, form: .words, from: userInfo["source"] ?? "cognition",
            title: title, summary: body, open: userInfo["sessionId"].map { "chat:" + $0 }),
            reach: .person(from: nil), at: date, turn: turn)
        let accepted = outcome.destinationOutcomes.filter { $0.value == .delivered }.keys.sorted()
        return accepted.isEmpty ? nil : accepted.joined(separator: ",")
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

    public func runCarriedAction(_ step: DeskStep, handle: String, dataRoot: URL) async -> JSONValue {
        await EnginePartWake.runCarried(step, handle: handle, dataRoot: dataRoot)
    }

    public func callReadPart(id: String, input: JSONValue, actions: Set<String>, dataRoot: URL, origin: String) async throws -> JSONValue {
        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native(origin)) { door in
            switch await Parts(root: dataRoot).call(id: id, input: input,
                within: .init(actions: actions, capabilities: ["app_data_read"]), invocation: door.invocation, as: JSONValue.self) {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }
    public func deliverShoulderTap(
        eventId: String, title: String, body: String, reason: String,
        userInfo: [String: String], at date: Date, turn: Turn?
    ) async throws -> String? {
        try await attention.deliverShoulderTap(
            eventId: eventId, title: title, body: body, reason: reason, userInfo: userInfo, at: date, turn: turn)
    }


    public func backgroundLLMClient(dataRoot: URL, cognition: NativeCognitionRuntime?, assembly: PrivateWorkContextAssembly) -> any LLMClient {
        NativeAgentEngine.makeSharedLLMClient(dataRoot: dataRoot, cognitionRuntime: cognition, assembly: assembly)
    }

    public func studioWanderClient(dataRoot: URL, usesLiveAppBody: Bool) -> any StudioWanderClientPort {
        EngineStudioWanderClient(engine: usesLiveAppBody ? NativeAgentEngine.live : NativeAgentEngine(dataRoot: dataRoot, ports: .app(dataRoot: dataRoot),
            hasBody: false))
    }
}
