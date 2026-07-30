import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry
import GitHubConnector


extension NativeClient {
    func revokeConnector(
        provider: String,
        githubCredentialStore: GitHubCredentialStore = .shared,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        if provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "github" {
            try await githubCredentialStore.deleteCredential(dataRoot: dataRoot)
        }
        let impl = makeConnectorAuthClient(root: dataRoot)
        _ = try await impl.revokeConnector(provider: provider)
        return
    }

    /// Connect-success LOCAL registry mutation — the SAVE half of the connector
    /// OAuth surface (wave 36 W03, CLOSES CUTOVER_PLAN.md §6.137 follow-up #3).
    ///
    /// This is the SYMMETRIC counterpart to `revokeConnector`: write the matching
    /// `connectors/registry.json` record to `enabled=true, authState="connected",
    /// healthStatus="ok"` under the SAME cross-process flock the daemon's
    /// connect-success tail holds (the retired daemon `handle_authcode_callback`
    /// + L20380 the github device-flow poll thread). When `.connectorAuth` is ON
    /// (DEFAULT OFF; leash-held) the write runs in-process via
    /// SwiftNativeConnectorAuthClient against the co-located data root.
    ///
    /// IMPORTANT — this is NOT the browser OAuth start. `NativeOAuthFlow`
    /// drives the connector OAuth network exchange and token persist; this seam
    /// is only the local registry-connect write for future callers that need it
    /// after token persistence. Today the Mac connector wizard and skill OAuth
    /// sheet call `NativeOAuthFlow.startConnectorOAuthFlow(...)` directly.
    func markConnectorConnected(provider: String) async throws {
        let impl = makeConnectorAuthClient(root: PersistenceCore.defaultDataRoot())
        _ = try await impl.connectConnector(provider: provider)
    }

}
