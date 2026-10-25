import Foundation
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

/// The agent-bridge listener an A2A peer pushes task notifications to.
public protocol EngineAgentBridgePort: Sendable {
    func a2aPushConfiguration(for peer: AgentPeerContact) async -> JSONValue?
}

/// The standing-bot runner that drains queued bot runs.
public protocol EngineStandingBotQueuePort: Sendable {
    func enqueueRun(bot: UUID, question: String?) throws -> BotRunReceipt
}

/// Platform hosts supplied once to Core's composition root. The factories
/// bind existing app adapters; dispatch and chat policy stay in the engine.
public struct NativeAgentEnginePorts: Sendable {
    public let backgroundWork: any EngineBackgroundWorkHost
    public let connectorStatus: any ConnectorStatusPlatform
    public let browserRoutes: BrowserActionRoutes
    public let cognitionHost: any CognitionHost
    public let deviceSyncHost: any DeviceSyncHost
    public let macIntegration: any MacIntegrationToolBridge
    public let agentBridge: any EngineAgentBridgePort
    public let completionSender: @Sendable (URL) -> any AgentBridgeCompletionSending
    public let standingBotQueue: any EngineStandingBotQueuePort
    public let appTools: @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor
    public let interactions: any ToolInteractionResolving
    public let chatPlatform: ChatToolPlatformPort
    public let connectorActionStatuses: @Sendable () async throws -> [String: String]

    public init(
        backgroundWork: any EngineBackgroundWorkHost,
        connectorStatus: any ConnectorStatusPlatform,
        browserRoutes: BrowserActionRoutes,
        cognitionHost: any CognitionHost,
        deviceSyncHost: any DeviceSyncHost,
        macIntegration: any MacIntegrationToolBridge,
        agentBridge: any EngineAgentBridgePort,
        completionSender: @escaping @Sendable (URL) -> any AgentBridgeCompletionSending,
        standingBotQueue: any EngineStandingBotQueuePort,
        appTools: @escaping @Sendable (SwiftNativeSecurityCenter, Bool) -> AppToolExecutor,
        interactions: any ToolInteractionResolving,
        chatPlatform: ChatToolPlatformPort,
        connectorActionStatuses: @escaping @Sendable () async throws -> [String: String]
    ) {
        self.backgroundWork = backgroundWork
        self.connectorStatus = connectorStatus
        self.browserRoutes = browserRoutes
        self.cognitionHost = cognitionHost
        self.deviceSyncHost = deviceSyncHost
        self.macIntegration = macIntegration
        self.agentBridge = agentBridge
        self.completionSender = completionSender
        self.standingBotQueue = standingBotQueue
        self.appTools = appTools
        self.interactions = interactions
        self.chatPlatform = chatPlatform
        self.connectorActionStatuses = connectorActionStatuses
    }
}

extension EngineAgentBridgePort {
    public func a2aPushConfiguration(for peer: AgentPeerContact, activePort port: UInt16) async -> JSONValue? {
        guard port != 0, let secret = try? AgentPeerCredentials.read(peerID: peer.id), !secret.isEmpty else { return nil }
        return .object(["url": .string("http://127.0.0.1:\(port)/a2a/notifications"),
            "authentication": .object(["scheme": .string("Bearer"), "credentials": .string(secret)])])
    }
}

extension BotRunQueue: EngineStandingBotQueuePort {
    public func enqueueRun(bot: UUID, question: String?) throws -> BotRunReceipt {
        try enqueue(bot: bot, context: question)
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
    private static let portsLock = NSLock()
    nonisolated(unsafe) private static var appPorts: (@Sendable (URL) -> Self)?

    public static func installAppPorts(_ factory: @escaping @Sendable (URL) -> Self) {
        portsLock.withLock {
            precondition(appPorts == nil, "App ports are already installed")
            appPorts = factory
        }
    }

    public static func app(dataRoot: URL) -> Self {
        let factory = portsLock.withLock {
            guard let appPorts else { preconditionFailure("Install app ports before constructing the engine") }
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
