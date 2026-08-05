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

extension NativeClient {
    func getNextGenSummary() async throws -> NextGenSummary {
        let phases = try await getNextGenPhases()
        let receipts = try await getNextGenReceipts()
        let sortedPhases = phases.sorted {
            (($0.phaseNumber ?? Int.max), $0.id) < (($1.phaseNumber ?? Int.max), $1.id)
        }
        let readyPhases = sortedPhases.filter {
            $0.ready == true || ["ready", "ok", "passed", "complete", "completed"].contains($0.displayStatus.lowercased())
        }
        let current = sortedPhases.first {
            !readyPhases.contains($0)
        } ?? sortedPhases.last
        let phaseNumbers = sortedPhases.compactMap(\.phaseNumber)
        let status: String = {
            guard !sortedPhases.isEmpty else { return "unavailable" }
            return readyPhases.count == sortedPhases.count ? "ready" : "warn"
        }()
        var obj: [String: Any] = [
            "status": status,
            "readiness": status,
            "roadmap": "Swift-native local next-gen snapshot",
            "readyPhaseCount": readyPhases.count,
            "totalPhaseCount": sortedPhases.count,
            "actionCount": sortedPhases.reduce(0) { $0 + ($1.actions?.count ?? 0) },
            "receiptCount": receipts.count,
            "latestReceipts": receipts.prefix(10).map(Self.nextGenReceiptObject),
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let current {
            obj["currentPhaseId"] = current.id
            obj["currentPhaseName"] = current.displayName
        }
        if let minPhase = phaseNumbers.min(), let maxPhase = phaseNumbers.max() {
            obj["phaseRange"] = ["start": minPhase, "end": maxPhase]
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder.nativeAgent.decode(NextGenSummary.self, from: data)
    }

    func getNextGenPhases() async throws -> [NextGenPhase] {
        // DAEMON-KILL P1: read <dataRoot>/runtime/nextgen_phases.json.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("nextgen_phases.json")
        guard let data = try? Data(contentsOf: path) else { return [] }
        let decoder = JSONDecoder.nativeAgent
        if let response = try? decoder.decode(NextGenPhasesResponse.self, from: data) {
            return response.phases
        }
        if let phases = try? decoder.decode([NextGenPhase].self, from: data) {
            return phases
        }
        return []
    }

    func getNextGenReceipts() async throws -> [NextGenReceipt] {
        let root = PersistenceCore.defaultDataRoot()
        let paths = [
            root
                .appendingPathComponent("nextgen", isDirectory: true)
                .appendingPathComponent("actions", isDirectory: true)
                .appendingPathComponent("receipts.jsonl"),
            root
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("nextgen_receipts.jsonl"),
        ]
        let persistence = SwiftNativePersistenceCore()
        var receipts: [NextGenReceipt] = []
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            // U5 W-A item 1 (:5682): propagate — a swallowed read rendered
            // as "no receipts" (healthy-empty) instead of the real error.
            let rows = try await persistence.tailJSONL(path, limit: 100, maxBytes: nil)
            for row in rows {
                guard let data = try? row.serializedData(pretty: false),
                      let receipt = try? JSONDecoder.nativeAgent.decode(NextGenReceipt.self, from: data) else {
                    continue
                }
                receipts.append(receipt)
            }
        }
        var seen = Set<String>()
        return receipts
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    static func nextGenReceiptObject(_ receipt: NextGenReceipt) -> [String: Any] {
        var obj: [String: Any] = [:]
        if let v = receipt.receiptId { obj["receiptId"] = v }
        if let v = receipt.actionId { obj["actionId"] = v }
        if let v = receipt.phaseId { obj["phaseId"] = v }
        if let v = receipt.name { obj["name"] = v }
        if let v = receipt.status { obj["status"] = v }
        if let v = receipt.dryRun { obj["dryRun"] = v }
        if let v = receipt.approvalId { obj["approvalId"] = v }
        if let v = receipt.detail { obj["detail"] = v }
        if let v = receipt.output { obj["output"] = v }
        if let v = receipt.createdAt { obj["createdAt"] = v }
        if obj["receiptId"] == nil { obj["id"] = receipt.id }
        return obj
    }

    func getPersonalityGrowth() async throws -> PersonalityGrowthSummary {
        return try await swiftPersonalityGrowth()
    }

    func getNativePower() async throws -> NativePowerSummary {
        // DAEMON-KILL P1: empty surfaces summary until SwiftNative port lands.
        return NativePowerSummary(
            surfaces: [],
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
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
        return tailJSONL(path: Self.nativeActionReceiptsPath(), limit: 50)
    }

    func getNativeIntentRegistry() async throws -> NativeIntentRegistry {
        // residue/R5 Swift-native cutover: GET /v1/native/intents retired. No SwiftNative
        // intent registry yet — return an empty envelope.
        return NativeIntentRegistry(
            status: "unavailable",
            source: nil,
            intentCount: 0,
            actionsAvailable: [],
            intents: [],
            receipts: [],
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getNotificationStatus() async throws -> NotificationRuntimeStatus {
        // Subsystem #25b wave 38 W20 (2026-06-02): when .notificationStatus is ON,
        // the in-process SwiftNativeNotificationStatus reads the co-located
        // native_power/notifications/receipts.jsonl (tail 20, newest-first) +
        // counts the pending entries in workflows/approvals/requests.json and
        // serves the same notification_status() envelope without the HTTP
        // round-trip. The reader is a PURE read (no write-back): the daemon only
        // appends to receipts.jsonl (atomic line append) and read_json's the
        // approvals file (its R-M-W is approvals_lock-guarded + write_json is
        // tmp+os.replace atomic), so a status read never sees a torn file — no
        // flock prereq. If the native reader has no data yet, return the empty
        // ready envelope below.
        let client = makeNotificationStatus()
        if let envelope = await client.notificationStatus() {
            return try Self.decodeJSONValue(envelope, as: NotificationRuntimeStatus.self, context: "getNotificationStatus(swiftNative)")
        }
        // Swift-native cutover sweep s3: native returned nil → degrade to a default
        // ready envelope (matches the empty-state UI degraded by getBrowserStatus).
        return NotificationRuntimeStatus(
            status: "ready",
            authorization: "app_requested",
            pendingApprovals: 0,
            receiptCount: 0,
            latestReceipt: nil,
            createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
        )
    }

    func getBrowserStatus() async throws -> BrowserRuntimeStatus {
        // Subsystem #27 wave 33 W17 (2026-06-01): when .browser is ON, the
        // in-process SwiftNativeBrowserClient reads the co-located
        // native_power/browser/{runs.json,receipts.jsonl} + trust-policy
        // approvedDomains and serves the same browser_status() envelope without
        // the HTTP round-trip. The reader is a PURE read (no write-back); the
        // daemon's run/cancel R-M-W of runs.json is flock-guarded this wave so a
        // status read never sees a torn file. If the native reader has no data
        // yet, return the empty idle envelope below.
        let client = makeBrowserClient()
        if let envelope = await client.browserStatus() {
            return try Self.decodeJSONValue(envelope, as: BrowserRuntimeStatus.self, context: "getBrowserStatus(swiftNative)")
        }
        // DAEMON-KILL sweep-s1: when the native client returns nil (no
        // browser data on disk yet), surface a clean "no activity" status
        // so the BrowserView renders an empty state instead of an error.
        return BrowserRuntimeStatus(
            status: "idle",
            profilePath: nil,
            sourcePath: nil,
            screenshotPath: nil,
            approvedDomains: [],
            domainPolicy: "approval_risk_tiering",
            activeRuns: [],
            receiptCount: 0,
            latestReceipt: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getMemoryVectorStatus() async throws -> MemoryVectorStatus {
        // Read <dataRoot>/memory/vector_status.json if present, else return a
        // synthetic unavailable status.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("vector_status.json")
        if let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder.nativeAgent.decode(MemoryVectorStatus.self, from: data) {
            return decoded
        }
        return MemoryVectorStatus(
            status: "unavailable",
            provider: nil,
            providerModel: nil,
            providerConfigured: false,
            providerReason: "vector status not available",
            dimensions: nil,
            nodeCount: nil,
            entityCount: nil,
            updatedAt: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getMemoryV2Status() async throws -> MemoryV2Status {
        // fix3/F2: route truthfully through SwiftNativeMemoryV2.shared. Counts
        // come from MemoryStorage; pinned reads metadata.pinned; pending
        // proposals reads storage.listProposals(status: "pending"); embedding
        // backend reflects the live runtime snapshot — CoreML when MiniLM
        // loaded, mock when the user explicitly opted in (config or env),
        // fail-closed otherwise.
        let dataRoot = PersistenceCore.defaultDataRoot()
        var memCount = 0
        var activeCount = 0
        var pinnedCount = 0
        var pendingProposals: Int? = nil
        if let storage = try? MemoryStorage(dataRoot: dataRoot) {
            if let all = try? await storage.listMemories(persona: nil, status: nil, limit: nil) {
                memCount = all.count
                for m in all {
                    if m.status == "active" { activeCount += 1 }
                    // SQLite schema has no `pinned` column; updateMemory()
                    // encodes the flag under metadata.pinned. Surface the
                    // real count by inspecting the metadata blob.
                    if case .object(let obj)? = m.metadata,
                       case .bool(true)? = obj["pinned"] {
                        pinnedCount += 1
                    }
                }
            }
            if let pending = try? await storage.listProposals(status: "pending") {
                pendingProposals = pending.count
            }
        }
        let modelId = await SwiftNativeMemoryV2.shared.embedderModelId()
        let dims = await SwiftNativeMemoryV2.shared.embedderDimensions()
        // gpt-5.5 review-4 STILL-NEEDS-FIX: `embedderModelId()` returns
        // "all-MiniLM-L6-v2" whenever config requests CoreML — even when the
        // effective runtime is fail-closed (resources missing, embed() throws).
        // Deriving `isReal` from `modelId != "mock"` therefore lied to the UI:
        // a broken install surfaced as `realSemanticAvailable: true` with
        // `fallbackReason: nil`. Drive off the runtime snapshot's
        // `effectiveBackend` instead, which is the single source of truth
        // computed inside ManagedEmbeddingProvider with all the branch logic.
        let runtimeSnapshot = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot()
        let effective = runtimeSnapshot?.effectiveBackend
        let isReal = (effective == ManagedEmbeddingProvider.coreMLBackend)
        let backend = modelId.map { "\($0)\(dims.map { "/d\($0)" } ?? "")" }
        let fallback: String? = {
            guard !isReal else { return nil }
            switch effective {
            case ManagedEmbeddingProvider.mockBackend:
                return "Semantic embeddings are explicitly set to mock (config or NATIVE_AGENT_EMBEDDING_MOCK)"
            case ManagedEmbeddingProvider.failClosedBackend:
                return "CoreML semantic embeddings unavailable; recall is fail-closed until the MiniLM bundle is installed"
            default:
                // Snapshot was nil (runtime not yet wired) — surface that honestly.
                return "Semantic embedding runtime is unavailable"
            }
        }()
        // F2: surface hygiene_last_run.json so the UI can show "last run at X /
        // next ~24h" instead of an empty hygiene slot that reads as "never".
        let hygieneReport = Self.readHygieneLastRun()
        return MemoryV2Status(
            status: memCount > 0 ? "ready" : "empty",
            version: "swift-native",
            embedding: MemoryV2Embedding(
                activeBackend: backend,
                realSemanticAvailable: isReal,
                fallbackReason: fallback
            ),
            counts: MemoryV2Counts(
                memories: memCount,
                active: activeCount,
                pinned: pinnedCount,
                noisyReflections: nil,
                pendingProposals: pendingProposals
            ),
            hygiene: hygieneReport,
            vault: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// F2: Read `<dataRoot>/memory/hygiene_last_run.json` and project it onto
    /// MemoryHygieneReport so the Memory tab shows a real last-run timestamp.
    /// The on-disk payload varies (the audit harness writes `{"createdAt":…}`;
    /// the consolidation loop writes a fuller dict). Be tolerant: any
    /// recognizable timestamp is enough to flip the badge from empty.
    static func readHygieneLastRun() -> MemoryHygieneReport? {
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("memory")
            .appendingPathComponent("hygiene_last_run.json")
        guard let data = try? Data(contentsOf: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let createdAt = (obj["createdAt"] as? String)
            ?? (obj["created_at"] as? String)
            ?? (obj["lastRun"] as? String)
            ?? (obj["last_run"] as? String)
        // Prefer the report's own nextScheduled; derive lastRun + 7d only when
        // absent. The cadence is WEEKLY (MemoryConsolidationHygieneRunner
        // stages one approval card per week) — the old derived +24h made the
        // Memory tab claim hygiene was overdue six days out of seven.
        var nextScheduled: String? = (obj["nextScheduled"] as? String)
            ?? (obj["next_scheduled"] as? String)
        // Honest-status (2026-07-24): a staged/refused run completed nothing —
        // its receipt intentionally carries no "next" stamp, and deriving one
        // here would recreate the false cadence boundary the runner just
        // stopped writing.
        let statusValue = (obj["status"] as? String) ?? "idle"
        if nextScheduled == nil,
           statusValue != "staged", statusValue != "refused",
           let createdAt, let dt = ISO8601DateFormatter().date(from: createdAt) {
            nextScheduled = ISO8601DateFormatter().string(from: dt.addingTimeInterval(7 * 24 * 3600))
        }
        return MemoryHygieneReport(
            id: obj["id"] as? String,
            status: (obj["status"] as? String) ?? "idle",
            reason: obj["reason"] as? String,
            version: obj["version"] as? String,
            createdAt: createdAt,
            beforeCount: obj["beforeCount"] as? Int,
            afterCount: obj["afterCount"] as? Int,
            normalized: obj["normalized"] as? Int,
            archivedDuplicates: obj["archivedDuplicates"] as? Int,
            archivedReflections: obj["archivedReflections"] as? Int,
            distilledFactsAdded: obj["distilledFactsAdded"] as? Int,
            decayedMemories: obj["decayedMemories"] as? Int,
            proposalHygiene: nil,
            nextScheduled: nextScheduled
        )
    }

    func runMemoryHygiene(dryRun: Bool = false) async throws -> MemoryHygieneReport {
        // DAEMON-DEAD PORT (2026-06-03): run the Swift MemoryV2 consolidator
        // as the manual hygiene path. It handles tombstones, duplicate proposal
        // merges, high-durability auto-accepts, and stale active-memory archive.
        let root = PersistenceCore.defaultDataRoot()

        if dryRun {
            let storage = try MemoryStorage(dataRoot: root)
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
                nextScheduled: nextISO
            )
        }

        // U3 wave-1 item 6 + review blocker (2026-06-10): this is the ONLY
        // direct-consolidate entry point, and both of its callers carry an
        // explicit approval — the MemoryView "Run hygiene" button (manual
        // human action) and applyApprovedSelfImprovement's approved
        // run_memory_hygiene op. The weekly background tick does NOT call
        // this; it stages an approval card (MemoryConsolidationHygieneRunner).
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
        tailJSONL(path: Self.connectorActionReceiptsPath(), limit: limit)
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    static func connectorActionRecords(connectors: [ConnectorRecord]) -> [ConnectorActionRecord] {
        var byID: [String: ConnectorRecord] = [:]
        for connector in connectors {
            byID[normalizedConnectorID(connector.id)] = connector
        }
        let nativeConnectors: Set<String> = [
            "mobile", "scheduler", "mac", "mac_assistant",
            "local_files", "searxng", "codex_work", "codex_handoff",
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

    // W-H ImprovementOps-band lift (move-only): private->internal.
    static func connectorActionIDSet() -> Set<String> {
        Set(connectorActionDescriptors().map(\.id))
    }

    static func connectorActionReceiptsPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    func getImprovementGauntlet() async throws -> ImprovementGauntletStatus {
        // wave 33 W09 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        // Reads improvements/gauntlet/runs.json locally (co-located on the Mac).
        // No trust gate on this route in the daemon. iOS keeps HTTP (network-only).
        // See CUTOVER_PLAN §6.96.
        return try await swiftImprovementGauntlet()
    }

    func getProductionHardening() async throws -> ProductionHardeningSummary {
        // DAEMON-KILL P1: read <dataRoot>/runtime/hardening.json if present;
        // otherwise return a neutral synthetic summary.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hardening.json")
        if let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder.nativeAgent.decode(ProductionHardeningSummary.self, from: data) {
            return decoded
        }
        return ProductionHardeningSummary(
            status: "unknown",
            release: nil,
            doctorStatus: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getProductionExports() async throws -> [ProductionExport] {
        // WAVE 31 (2026-06-01): SwiftNative read-only port behind
        // .productionExports. Reads <dataRoot>/production/exports/registry.json
        // locally on the Mac (co-located with the daemon's data files), filters
        // to a list, sorts by createdAt DESC — byte-accurate against
        // list_production_exports. READ-ONLY, so no
        // flock prereq.
        let impl = makeProductionExportsClient()
        let receipts = try await impl.listExports()
        let data = try JSONValue.array(receipts.map { $0.toJSON() }).serializedData(pretty: false)
        return try JSONDecoder().decode([ProductionExport].self, from: data)
    }

    // FIX: high-traffic lists use lossy decode so one malformed element doesn't
    // nuke the whole list (drops + logs the bad element instead).
    func getActivity() async throws -> [ActivityEvent] {
        // DAEMON-KILL P1: tail of <dataRoot>/activity/events.jsonl.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        return tailJSONL(path: path, limit: 200)
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
                lifecycleObserver: NativeCognitionRuntime.shared))
    }

}
