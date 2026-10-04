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
import Cognition



extension NativeClient {
    /// All NextGen status projections must read the same root as the client
    /// that mounted them. Falling back to the process default here made an
    /// isolated panel quietly render somebody else's empty/healthy snapshot.
    private var nextGenStatusDataRoot: URL {
        dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }


    func getNextGenSummary() async throws -> NextGenSummary {
        try await NextGenStatusProjection(dataRoot: nextGenStatusDataRoot).getNextGenSummary()
    }

    func getNextGenPhases() async throws -> [NextGenPhase] {
        try await NextGenStatusProjection(dataRoot: nextGenStatusDataRoot).getNextGenPhases()
    }

    func getNextGenReceipts() async throws -> [NextGenReceipt] {
        try await NextGenStatusProjection(dataRoot: nextGenStatusDataRoot).getNextGenReceipts()
    }

    func getPersonalityGrowth() async throws -> PersonalityGrowthSummary {
        return try await swiftPersonalityGrowth()
    }

    func getNativeActionRegistry() async throws -> NativeActionRegistry {
        return NativeActionRegistry(
            status: "ready",
            actions: Self.swiftNativeActionRecords(),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getNativeActionReceipts() async throws -> [NativeActionReceipt] {
        // DAEMON-KILL P1: tail the daemon-native cross-action ledger path.
        // Browser dry-run already appends here; the legacy `native_actions/`
        // path was stale and made the Native Power panel miss real Swift
        // receipts.
        return tailJSONL(path: Self.nativeActionReceiptsPath(dataRoot: nextGenStatusDataRoot), limit: 50)
    }

    func getNotificationStatus() async throws -> NotificationRuntimeStatus {
        try await RuntimeReadProjection.getNotificationStatus(dataRoot: nextGenStatusDataRoot)
    }

    func getBrowserStatus() async throws -> BrowserRuntimeStatus {
        try await RuntimeReadProjection.getBrowserStatus(dataRoot: nextGenStatusDataRoot)
    }

    func getMemoryVectorStatus() async throws -> MemoryVectorStatus {
        try await MemoryStatusProjection.getMemoryVectorStatus(dataRoot: nextGenStatusDataRoot)
    }

    func getMemoryV2Status() async throws -> MemoryV2Status {
        try await MemoryStatusProjection.getMemoryV2Status(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    /// F2: Read `<dataRoot>/memory/hygiene_last_run.json` and project it onto
    /// MemoryHygieneReport so the Memory tab shows a real last-run timestamp.
    /// The on-disk payload varies (the audit harness writes `{"createdAt":…}`;
    /// the consolidation loop writes a fuller dict). Be tolerant: any
    /// recognizable timestamp is enough to flip the badge from empty.
    static func readHygieneLastRun(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> MemoryHygieneReport? {
        MemoryStatusProjection.readHygieneLastRun(dataRoot: dataRoot)
    }

    func runMemoryHygiene(dryRun: Bool = false) async throws -> MemoryHygieneReport {
        // DAEMON-DEAD PORT (2026-06-03): run the Swift MemoryV2 consolidator
        // as the manual hygiene path. It handles tombstones, duplicate proposal
        // merges, high-durability auto-accepts, and stale active-memory archive.
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()

        if dryRun {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: root)
            let before = (try? await storage.listMemories(persona: nil, status: nil, limit: nil).count) ?? 0
            let pending = (try? await storage.listProposals(status: "pending").count) ?? 0
            let now = Date()
            let nowISO = SwiftNativeManifestSigner.isoTimestamp(now)
            let nextISO = SwiftNativeManifestSigner.isoTimestamp(now.addingTimeInterval(7 * 24 * 3600))
            return MemoryHygieneReport(
                id: "hygiene-preview-\(UUID().uuidString.lowercased())",
                status: "dry_run",
                reason: "Preview only; no memory records were changed.",
                version: "swift-memory-v2-consolidator",
                createdAt: nowISO,
                beforeCount: before,
                afterCount: before,
                normalized: pending,
                archivedDuplicates: nil,
                archivedReflections: nil,
                distilledFactsAdded: nil,
                decayedMemories: nil,
                proposalHygiene: MemoryProposalHygiene(rejectedLowValue: nil, nearDuplicates: nil),
                consolidationRunId: nil,
                nextScheduled: nextISO
            )
        }

        // U3 wave-1 item 6 + review blocker (2026-06-10): this is the ONLY
        // direct-consolidate entry point, and both of its callers carry an
        // explicit approval — the Memories upkeep "Run hygiene" button (manual
        // human action) and applyApprovedSelfImprovement's approved
        // run_memory_hygiene op. The weekly tick calls runOnce itself
        // (MemoryConsolidationHygieneRunner, 2026-09-22).
        return try await MemoryConsolidationHygiene.runOnce(
            dataRoot: root, approvedDirectRun: true)
    }

    func getConnectorActions() async throws -> ConnectorActionRegistry {
        // DAEMON-DEAD PORT (2026-06-03): expose the Swift static connector
        // action manifest with the same non-secret readiness overlay the
        // connector list uses. Live execution still fails closed below until
        // the provider/approval executor is ported; this reader is real.
        // U5 W-A item 1 (:6001): propagate — a failed connector read
        // previously rendered the whole registry as "unavailable/empty"
        // with no signal that it was a READ failure.
        let connectors = try await getConnectors()
        let actions = Self.connectorActionRecords(connectors: connectors)
        let receipts = connectorActionReceipts(limit: 50)
        return ConnectorActionRegistry(
            status: actions.isEmpty ? "unavailable" : "ready",
            actions: actions,
            receiptCount: receipts.count,
            latestReceipt: receipts.first,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func connectorActionReceipts(limit: Int) -> [ConnectorActionReceipt] {
        tailJSONL(path: Self.connectorActionReceiptsPath(dataRoot: nextGenStatusDataRoot), limit: limit)
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    static func checkedConnectorActionStatuses(root: URL) async throws -> [String: String] {
        let connectors = try await readConnectorRecords(root: root)
        let ready: Set<String> = ["active", "ready", "ok", "healthy", "connected"]
        return Dictionary(uniqueKeysWithValues: connectorActionRecords(connectors: connectors).map { action in
            let status = action.connectorStatus ?? "needs_setup"
            let capabilityStatus = action.enabled == true
                ? (ready.contains(status) ? "active" : status) : "needs_setup"
            return (action.id, capabilityStatus)
        })
    }

    static func connectorActionRecords(connectors: [ConnectorRecord]) -> [ConnectorActionRecord] {
        var byID: [String: ConnectorRecord] = [:]
        for connector in connectors {
            byID[normalizedConnectorID(connector.id)] = connector
        }
        let nativeConnectors: Set<String> = [
            "mobile", "scheduler", "mac", "mac_assistant",
            "local_files", "codex_work", "codex_handoff",
            "markets",
        ]
        return connectorActionDescriptors().map { descriptor in
            let key = normalizedConnectorID(descriptor.connectorId)
            let connector = byID[key]
            let enabled = connector?.enabled ?? nativeConnectors.contains(key)
            let connectorStatus = connector?.healthStatus ?? (enabled ? "active" : "needs_setup")
            let authState = connector?.authState ?? (enabled ? "not_required" : "not_connected")
            return ConnectorActionRecord(
                id: descriptor.id,
                connectorId: descriptor.connectorId,
                name: descriptor.name ?? descriptor.id,
                risk: descriptor.risk,
                dryRunAvailable: descriptor.dryRunAvailable,
                requiresApproval: descriptor.requiresApproval,
                connectorStatus: connectorStatus,
                authState: authState,
                enabled: enabled
            )
        }
    }

    static func connectorActionIDSet() -> Set<String> {
        Set(connectorActionDescriptors().map(\.id))
    }

    static func connectorActionReceiptsPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    func getImprovementGauntlet() async throws -> ImprovementGauntletStatus {
        // wave 33 W09 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        // Reads improvements/gauntlet/runs.json locally (co-located on the Mac).
        // No trust gate on this route in the daemon. iOS keeps HTTP (network-only).
        return try await swiftImprovementGauntlet()
    }

    func getProductionHardening() async throws -> ProductionHardeningSummary {
        try await DoctorStatusProjection.getProductionHardening(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    func getProductionExports() async throws -> [ProductionExport] {
        // WAVE 31 (2026-06-01): SwiftNative read-only port behind
        // .productionExports. Reads <dataRoot>/production/exports/registry.json
        // locally on the Mac (co-located with the daemon's data files), filters
        // to a list, sorts by createdAt DESC — byte-accurate against
        // list_production_exports. READ-ONLY, so no
        // flock prereq.
        let registryPath = (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("production", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("registry.json")
        let impl = SwiftNativeProductionExportsClient(registryPath: registryPath)
        let receipts = try await impl.listExports()
        let data = try JSONValue.array(receipts.map { $0.toJSON() }).serializedData(pretty: false)
        return try JSONDecoder().decode([ProductionExport].self, from: data)
    }

    // FIX: high-traffic lists use lossy decode so one malformed element doesn't
    // nuke the whole list (drops + logs the bad element instead).
    func getActivity() async throws -> [ActivityEvent] {
        try await getActivity(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    /// Reads the exact activity ledger used by the Status screen. Keeping the
    /// root injectable lets a hermetic caller verify the production decoder
    /// and chronological tail without consulting personal runtime state.
    func getActivity(root: URL) async throws -> [ActivityEvent] {
        try await RuntimeReadProjection.getActivity(root: root)
    }

    func getActivityReadout(root: URL) async throws -> ActivityTailReadout {
        try await RuntimeReadProjection.getActivityReadout(root: root)
    }



    // WAVE 37 (2026-06-02) W20 §6.159: single construction point for the
    // SwiftNative executions read seam. The four read getters (getWorkshopExecutions /
    // getQueuedMissions / getMissionDetail / getMissionTimeline) previously
    // each constructed
    //   WorkshopExecution.SwiftNativeWorkshopRunner(planner: WorkshopExecution.HTTPCodexMissionPlannerLLM())
    // verbatim. Identical wiring, but a 4-way duplicate that drifts: waves 27/28
    // had to thread the OAuth-direct adapters through HTTPCodexMissionPlannerLLM
    // — any future planner change would have had to be mirrored at all four
    // sites. Consolidated here. Behaviour is byte-identical: still a fresh,
    // side-effect-free actor per call (no shared/cached state, so no
    // cleanup-lifecycle obligation), and the planner is never invoked on the
    // pure-read paths. The default `root` resolves to PersistenceCore's data
    // root exactly as the inline construction did.
    func makeWorkshopExecutionRunner() -> WorkshopExecution.SwiftNativeWorkshopRunner {
        // TOOL-AWARE planner: inject the real SwiftToolDispatcher catalog so a
        // submitted execution can plan and run actual tools, not only
        // chat.synthesize (root cause fixed 2026-06-15). This is THE submit
        // path — planning happens here when an execution is submitted.
        WorkshopExecution.SwiftNativeWorkshopRunner(
            planner: WorkshopExecution.SwiftNativeWorkshopPlannerLLM(
                connectorActionsProvider: makeWorkshopPlannerConnectorActionsProvider(),
                lifecycleObserver: NativeAgentEngine.liveCognition))
    }

}
