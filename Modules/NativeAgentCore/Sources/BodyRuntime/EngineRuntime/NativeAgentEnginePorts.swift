import Synchronization
import Foundation
import SenseCore
import DeskCore
import NativeAgentCore
import MacNerves
import MindCore
import PersistenceCore
import NativeAgentShared
import os
// Blueprint: | `NativeAgentEnginePorts.swift` | Mac app ports supplied at engine construction |

/// Supply platform hosts once; dispatch and chat policy remain in the engine.
public struct NativeAgentEnginePorts: Sendable {
    public let backgroundWork: any EngineBackgroundWorkHost
    public let connectorStatus: AppConnectorStatusPlatform
    public let deviceSyncPlatform: any EngineDeviceSyncPlatform
    public let macIntegration: any ChatMacIntegrationToolBridge
    public let a2aPushConfiguration: @Sendable (AgentPeerContact) async throws -> JSONValue
    public let completionSender: @Sendable (URL, @escaping @Sendable () throws -> NativeAgentEngine) -> any AgentBridgeCompletionSending
    public let standingBotQueue: BotRunQueue
    public let appTools: @Sendable (SwiftNativeSecurityCenter, Bool, NativeAgentEngine) -> AppToolExecutor
    public let browserRoutes: BrowserActionRoutes
    public let connectorActions: @Sendable (NativeAgentEngine) -> any ConnectorActionPlatform
    public let interactionPlatform: @Sendable (@escaping @Sendable () throws -> NativeAgentEngine) -> any InlineInteractionPlatformPort
    public let chatPlatform: ChatToolPlatformPort

    public init(
        backgroundWork: any EngineBackgroundWorkHost,
        connectorStatus: AppConnectorStatusPlatform,
        deviceSyncPlatform: any EngineDeviceSyncPlatform,
        macIntegration: any ChatMacIntegrationToolBridge,
        a2aPushConfiguration: @escaping @Sendable (AgentPeerContact) async throws -> JSONValue,
        completionSender: @escaping @Sendable (URL, @escaping @Sendable () throws -> NativeAgentEngine) -> any AgentBridgeCompletionSending,
        standingBotQueue: BotRunQueue,
        appTools: @escaping @Sendable (SwiftNativeSecurityCenter, Bool, NativeAgentEngine) -> AppToolExecutor,
        browserRoutes: BrowserActionRoutes,
        connectorActions: @escaping @Sendable (NativeAgentEngine) -> any ConnectorActionPlatform,
        interactionPlatform: @escaping @Sendable (@escaping @Sendable () throws -> NativeAgentEngine) -> any InlineInteractionPlatformPort,
        chatPlatform: ChatToolPlatformPort
    ) {
        self.backgroundWork = backgroundWork
        self.connectorStatus = connectorStatus
        self.deviceSyncPlatform = deviceSyncPlatform
        self.macIntegration = macIntegration
        self.a2aPushConfiguration = a2aPushConfiguration
        self.completionSender = completionSender
        self.standingBotQueue = standingBotQueue
        self.appTools = appTools
        self.browserRoutes = browserRoutes
        self.connectorActions = connectorActions
        self.interactionPlatform = interactionPlatform
        self.chatPlatform = chatPlatform
    }
}

extension NativeAgentEnginePorts {
    private struct AppPorts: Sendable {
        let make: @Sendable (URL) -> NativeAgentEnginePorts
    }
    private static let appPorts = Mutex<AppPorts?>(nil)

    public static func installAppPorts(_ factory: @escaping @Sendable (URL) -> Self) {
        PeerTrust.install()
        appPorts.withLock {
            precondition($0 == nil, "App ports are already installed")
            AppToolExecutor.bindDeclarations()
            $0 = AppPorts(make: factory)
        }
    }

    public static func app(dataRoot: URL) -> Self {
        let factory = appPorts.withLock {
            guard let appPorts = $0 else { preconditionFailure("Install app ports before constructing the engine") }
            return appPorts
        }
        return factory.make(dataRoot)
    }
}
