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

/// A compatibility caller asking for only trace rows must not receive a
/// success-shaped empty array when the canonical evidence feed was damaged or
/// only partially readable. Mounted timeline consumers use
/// `CapabilityTraceFeed.State` directly and can render the richer state.
enum NativeClientRuntimeReadError: LocalizedError, Equatable {
    case traceEvidencePartial(rejectedRows: Int)
    case traceEvidenceUnavailable(String)
    case unreadableFeed(String)

    var errorDescription: String? {
        switch self {
        case .traceEvidencePartial(let rejectedRows):
            return "Trace evidence is partial: \(rejectedRows) malformed \(rejectedRows == 1 ? "row" : "rows") were withheld."
        case .traceEvidenceUnavailable(let detail):
            return "Trace evidence is unavailable: \(detail)"
        case .unreadableFeed(let detail):
            return detail
        }
    }
}

extension NativeClient {
    /// The panel observes the native status owner and app-local PIM adapters.
    private func makeAppMacAssistantStatusClient() -> any MacAssistantStatusClient {
        Self.makeAppMacAssistantStatusClient(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    /// Every provider reads local state the app already owns — no network.
    static func makeAppMacAssistantStatusClient(root: URL) -> any MacAssistantStatusClient {
        makeMacAssistantStatusClient(
            proofs: NativeAppConnectorProofProvider(root: root),
            push: NativeAppMobilePushStatusProvider(),
            dispatcherTools: StaticDispatcherToolAvailabilityProvider(
                availableTools: SwiftToolDispatcher.catalogRegisteredToolNames
            ),
            localPIM: NativeAppLocalPIMStatusProvider(root: root)
        )
    }

    func getMacAssistantStatus() async throws -> MacAssistantStatusResult {
        let impl = makeAppMacAssistantStatusClient()
        // UI consumes the full access/template lists — request non-lightweight.
        return try await impl.macAssistantStatus(lightweight: false)
    }

    func getWorkflows() async throws -> [WorkflowRecord] {
        let impl = makeWorkflowOrchestrationClient(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let rows = try await impl.listWorkflows()
        let data = try JSONValue.array(rows).serializedData(pretty: false)
        return try JSONDecoder().decode([WorkflowRecord].self, from: data)
    }

    // 2026-09-01: `getWorkflowRuns()` retired with the workflow run engine
    // (User authorized). It was polled on every AppModel refresh to render a
    // ledger frozen since 2026-05-08. data/workflows/runs.jsonl stays on disk
    // as history; nothing reads it.

    func getMCPServers() async throws -> [MCPServerRecord] {
        return try await swiftListMCPServers()
    }

    func getMCPConsent() async throws -> [MCPConsentRecord] {
        return try await swiftListMCPConsents()
    }

    // Live tool discovery is routed through SwiftNativeMCPDispatcher. Stdio
    // uses the subprocess pool; built-in native/http servers read their Swift
    // cache/tool descriptors.
    func getMCPTools(serverId: String) async throws -> MCPToolsResponse {
        return try await swiftListMCPToolsLive(serverId: serverId)
    }

    // Live resource enumeration — same dispatcher contract as getMCPTools.
    func getMCPResources(serverId: String) async throws -> MCPResourcesResponse {
        return try await swiftListMCPResourcesLive(serverId: serverId)
    }

    func getTraces() async throws -> [RuntimeTrace] {
        try await RuntimeReadProjection.getTraces(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            partial: NativeClientRuntimeReadError.traceEvidencePartial,
            unavailable: NativeClientRuntimeReadError.traceEvidenceUnavailable
        )
    }

    /// The Capabilities timeline is backed by the shared durable ledger used
    /// by routing, workflows, catalog writes, and tool dispatch. It carries a
    /// stateful result so its view can distinguish absent/empty/corrupt input.
    func getCapabilityTraceTimeline() -> CapabilityTraceFeed.State {
        CapabilityTraceFeed.read(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    func getAgentGraph() async throws -> AgentGraph {
        let projection = try await Self.canonicalAgentGraphProjection(
            graphPath: knowledgeGraphPath
        )
        let executionCount = try? await DeskFacade(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()).taskRows().count
        return Self.agentGraph(from: projection, executionCount: executionCount)
    }

    func getGraphEntities() async throws -> [GraphEntity] {
        try await Self.canonicalAgentGraphProjection(graphPath: knowledgeGraphPath).entities
    }

    func getGraphStatus() async throws -> GraphIndexStatus {
        let projection = try await Self.canonicalAgentGraphProjection(
            graphPath: knowledgeGraphPath
        )
        return Self.graphIndexStatus(from: projection)
    }

    func searchGraph(query: String) async throws -> GraphSearchResponse {
        try await KnowledgeGraphReadProjection.searchGraph(query: query, graphPath: knowledgeGraphPath)
    }

    func getAutonomyKernel() async throws -> AutonomyKernelSummary {
        try await RuntimeReadProjection.getAutonomyKernel(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(), improvements: { try await getImprovements() })
    }

    func getPersonalOS() async throws -> PersonalOSSummary {
        try await RuntimeReadProjection.getPersonalOS(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(), unreadableFeed: NativeClientRuntimeReadError.unreadableFeed)
    }

    // PORTED wave 30 W07 (2026-06-01): `.capabilityTrust` snapshot routes
    // GET /v1/capability-catalog through the SwiftNative `listCapabilityCatalog`
    // free function (TrustCenter/CapabilityRecords+Dynamic.swift:630) — the same
    // port already consumed by the trust-network aggregator. The seam is the
    // canonical JSONValue→Data→Decodable round-trip used by getCapabilityTrust.
    //
    // PARITY CARVE (documented, benign): the Swift `listCapabilityCatalog` is
    // READ-ONLY — it does NOT write the merged registry back to
    // <dataRoot>/catalog/registry.json on every read the way Python's
    // `list_capability_catalog()` did. The write-back
    // was an idempotent default-merge no-op; a re-read converges to the same
    // bytes. Same carve already accepted for the workflows port
    // (CapabilityRecords+Dynamic.swift:629). Sort + merge + default-overlay
    // semantics are byte-identical to Python.
    func getCapabilityCatalog() async throws -> [CapabilityCatalogItem] {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let merged = try await listCapabilityCatalog(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            nowISO: nowISO
        )
        let data = try JSONValue.array(merged.map { JSONValue.object($0) })
            .serializedData(pretty: false)
        return try JSONDecoder().decode([CapabilityCatalogItem].self, from: data)
    }

    // PORTED wave 30 W07 (2026-06-01): `.capabilityTrust` snapshot routes
    // GET /v1/capability-catalog/sources through the SwiftNative
    // `SwiftNativeCatalogSources` actor (TrustCenter/CapabilityCatalog.swift),
    // the same strict read owner consumed by the trust-network aggregator.
    // Missing state receives in-memory defaults; an existing damaged store
    // throws and is never rewritten by a GET. Default-overlay and stable merge
    // semantics remain compatible on valid input.
    func getCapabilityCatalogSources() async throws -> [CapabilityCatalogSource] {
        let actor = SwiftNativeCatalogSources(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            persistence: SwiftNativePersistenceCore()
        )
        let merged = try await actor.catalogSources()
        let data = try JSONValue.array(merged.map { JSONValue.object($0) })
            .serializedData(pretty: false)
        return try JSONDecoder().decode([CapabilityCatalogSource].self, from: data)
    }

    // PORTED wave 31 W15 (2026-06-01): `.capabilityTrust` snapshot routes
    // GET /v1/capability-catalog/installs through the SwiftNativeCatalogWrites
    // lock-free reader (TrustCenter/CapabilityCatalog.swift). Read-only of
    // <dataRoot>/catalog/installs.json with the same stable-reverse sort by
    // installedAt||createdAt the Python route uses. No
    // write-back, no flock (matching Python's unlocked read_json), so this is a
    // pure read flip with zero cross-process coordination concern.
    func getCapabilityPackInstalls() async throws -> [CapabilityPackInstall] {
        let writes = SwiftNativeCatalogWrites(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            persistence: SwiftNativePersistenceCore()
        )
        let rows = try await writes.listCapabilityPackInstalls()
        let data = try JSONValue.array(rows.map { JSONValue.object($0) })
            .serializedData(pretty: false)
        return try JSONDecoder().decode([CapabilityPackInstall].self, from: data)
    }
}
