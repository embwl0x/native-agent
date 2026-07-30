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
    func getHealth() async throws -> RuntimeHealth {
        // DAEMON-KILL P1: Mac process IS the runtime. Return a synthetic
        // health snapshot reflecting the in-process state.
        let root = PersistenceCore.defaultDataRoot()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let payload: [String: Any] = [
            "ok": true,
            "app": "NativeAgent",
            "version": version,
            "dataDir": root.path,
            "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder.nativeAgent.decode(RuntimeHealth.self, from: data)
    }

    /// Subsystem #17 cluster C4 / WAVE 5 (2026-05-31): GET /v1/command/palette.
    /// When `.commandPalette` is ON, returns the SwiftNative manifest with
    /// dynamic per-entry values injected from live Swift subsystems
    /// (`PersonaCompiler.loadProfile()` for persona name, `SwiftNativeApprovalInbox`
    /// for pending-approval count, `SwiftNativeTrustCenter.loadTrustPolicy`
    /// for `enableAutonomy`). Fields with no Swift source-of-truth today
    /// (connector/multimodal/mac-assistant/foundry/skill counts) carry the
    /// documented defaults from `CommandPaletteContext.wave2NeutralBaseline` — see the
    /// caveat header in
    /// Modules/NativeAgentCore/Sources/CommandPalette/CommandPalette.swift.
    /// Returned as raw `Data` so MacSyncEngine can write it straight to the
    /// snapshot file the way it does for /v1/trust + friends.
    func fetchCommandPaletteRawData() async -> Data? {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let context = await makeCommandPaletteContext()
        let response = commandPaletteResponse(query: "", limit: 50, context: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(response)
    }

    /// Subsystem #17 cluster C4 / WAVE 5: GET /v1/command/search?q=...&limit=...
    /// Same flag gate as fetchCommandPaletteRawData. SwiftNative path returns
    /// only the entries (the SpotlightOverlay caller only consumes the
    /// `entries` field, not the envelope), matching the field the daemon
    /// response always populates. Dynamic injection via CommandPaletteContext —
    /// see fetchCommandPaletteRawData for the per-field source map.
    func searchCommandPalette(query: String, limit: Int = 25) async throws -> [CoordinationCommandEntry] {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let context = await makeCommandPaletteContext()
        let entries = CommandPalette.searchCommandPalette(query, limit: limit, context: context)
        return entries.map { e in
            CoordinationCommandEntry(
                id: e.id,
                title: e.title,
                subtitle: e.subtitle,
                category: e.category,
                systemImage: e.systemImage,
                route: e.route,
                endpoint: e.endpoint,
                keywords: e.keywords,
                status: e.status,
                count: e.count
            )
        }
    }

    /// Subsystem #17 cluster C4 / WAVE 5 (2026-05-31): builds the
    /// `CommandPaletteContext` consumed by the SwiftNative palette renderer.
    /// Pulls live values from the Swift subsystems that have a port today:
    ///
    ///   - personaName       — current persona display name via
    ///                         `PersonaCompiler.agentDisplayName()` normalizer
    ///                         (generic names like "agent"/"AI" fall back to
    ///                         "NativeAgent"; non-isolated static — no actor
    ///                         hop, no IO beyond a single ~1 KB read).
    ///   - approvalCount     — `SwiftNativeApprovalInbox.list(filter:.pending).count`.
    ///                         Drives BOTH the `approvals` entry's count badge
    ///                         AND the autonomy.counts.pendingApprovals slot
    ///                         (legacy HTTP read them from different sources,
    ///                         but the values are equal by definition).
    ///   - enableAutonomy    — `SwiftNativeTrustCenter.loadTrustPolicy()["enableAutonomy"]`
    ///                         coerced to Bool. Drives the operating-map
    ///                         entry's ready/attention flip.
    ///   - improvementFailedCount — `SwiftNativeSelfImprovement
    ///                         .improvementSummaryLocal().failedCount`.
    ///                         Drives the self-improvement-scoreboard
    ///                         entry's ready/attention flip.
    ///
    /// All other fields default to `CommandPaletteContext.wave2NeutralBaseline` — see
    /// the CAVEAT block in CommandPalette.swift for the per-field carve list.
    /// Errors from the source-of-truth calls are non-fatal: we log via NSLog
    /// and fall back to the default for that field so the palette still renders.
    func makeCommandPaletteContext() async -> CommandPaletteContext {
        // Persona name: read profile.json directly via the non-isolated static
        // so we don't need to spin up a PersonaCompiler actor + cross the
        // boundary just to grab one string.
        let personaName = PersonaCompiler.agentDisplayName()

        // Pending-approval count via SwiftNativeApprovalInbox. Keep this call
        // best-effort: a failure here just means the count badge defaults to 0.
        var approvalsCount = 0
        let inbox = makeApprovalInbox()
        do {
            let pending = try await inbox.list(filter: .pending)
            approvalsCount = pending.count
        } catch {
            NSLog("[CommandPalette] approval inbox count failed: \(error.localizedDescription) — defaulting to 0")
        }

        // enableAutonomy from SwiftNativeTrustCenter. Missing/corrupt authority
        // stays false so a status projection never depicts autonomy as ready
        // while the canonical policy is unavailable.
        var enableAutonomy = false
        // loadTrustPolicy is on the SwiftNative actor — instantiate directly
        // (its init uses PersistenceCore.defaultDataRoot()). We always want the
        // Swift loader here.
        let trust = SwiftNativeTrustCenter()
        let policy = await trust.loadTrustPolicy()
        if case .bool(let b) = policy["enableAutonomy"] {
            enableAutonomy = b
        }

        // improvementFailedCount via SwiftNativeSelfImprovement. The local
        // summary reads runs.json directly via PersistenceCore, so the
        // Best-effort: any failure leaves the count at 0 (the
        // self-improvement-scoreboard entry stays "ready").
        var improvementFailedCount = 0
        let selfImprov = SwiftNativeSelfImprovement()
        do {
            let summary = try await selfImprov.improvementSummaryLocal()
            improvementFailedCount = summary.failedCount ?? 0
        } catch {
            NSLog("[CommandPalette] self-improvement summary failed: \(error.localizedDescription) — defaulting to 0")
        }

        return CommandPaletteContext(
            personaName: personaName,
            telegramHealthStatus: "optional",
            connectorNeedsProof: false,
            macAssistantStatus: "ready",
            macAssistantTemplateAttentionCount: 0,
            foundryReviewCount: 0,
            // Mirror approvalsCount into the Python autonomy.counts.pendingApprovals
            // slot so the `approvals` entry's badge stays correct even without
            // an autonomy_command_center_summary port.
            pendingApprovalsCount: approvalsCount,
            skillDraftCount: 0,
            multimodalStatus: "ready",
            enableAutonomy: enableAutonomy,
            improvementFailedCount: improvementFailedCount
        )
    }

    func getMacAssistantStatus() async throws -> MacAssistantStatusResponse {
        let impl = makeMacAssistantStatusClient(
            dispatcherTools: StaticDispatcherToolAvailabilityProvider(availableTools: [
                "calendar_list_upcoming",
                "reminders_list_due_today",
            ]),
            localPIM: NativeAppLocalPIMStatusProvider()
        )
        // UI consumes the full access/template lists — request non-lightweight.
        let swiftResult = try await impl.macAssistantStatus(lightweight: false)
        let data = try swiftResult.toJSON().serializedData(pretty: false)
        return try JSONDecoder().decode(MacAssistantStatusResponse.self, from: data)
    }

    func getCapabilities() async throws -> CapabilitySummaryResponse {
        // DAEMON-DEAD PORT (2026-06-03): TrustCenter now owns the full
        // capability_records() aggregator in Swift. Project the same records
        // into the Mac app's summary model instead of leaving the panel
        // fail-closed.
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(Date())
        let rawRecords = await capabilityRecordsFull(
            dataRoot: PersistenceCore.defaultDataRoot(),
            nowISO: nowISO
        )
        let data = try JSONValue.array(rawRecords.map { .object($0) }).serializedData(pretty: false)
        let records: [CapabilityRecord] = try Self.decodeLossyArray(data, context: "getCapabilities(swiftNative)")
        var byKind: [String: Int] = [:]
        var active = 0
        var review = 0
        var autoloaded = 0
        let activeStatuses: Set<String> = ["active", "installed", "ready", "configured"]
        let reviewStatuses: Set<String> = ["review", "proposal", "draft", "drafted", "needs_setup"]
        for record in records {
            byKind[record.kind, default: 0] += 1
            let status = (record.status ?? "").lowercased()
            if activeStatuses.contains(status) { active += 1 }
            if reviewStatuses.contains(status) { review += 1 }
            if record.autoload == true { autoloaded += 1 }
        }
        return CapabilitySummaryResponse(
            records: records,
            summary: CapabilityCounts(
                total: records.count,
                active: active,
                review: review,
                autoloaded: autoloaded,
                byKind: byKind
            ),
            createdAt: nowISO
        )
    }

    func getCapabilityFoundry() async throws -> CapabilityFoundrySummary {
        // Swift-native foundry readout for the Mac panel. Backlog
        // implementation is intentionally not a read-side side effect; action
        // execution stays behind explicit self-improvement/promotion gates.
        let impl = makeCapabilityFoundryClient()
        let result = try await impl.capabilityFoundrySummary()
        let data = try result.toJSON().serializedData(pretty: false)
        return try JSONDecoder().decode(CapabilityFoundrySummary.self, from: data)
    }

    func getWorkflows() async throws -> [WorkflowRecord] {
        let impl = makeWorkflowOrchestrationClient(root: PersistenceCore.defaultDataRoot())
        let rows = try await impl.listWorkflows()
        let data = try JSONValue.array(rows).serializedData(pretty: false)
        return try JSONDecoder().decode([WorkflowRecord].self, from: data)
    }

    func getWorkflowRuns() async throws -> [WorkflowRun] {
        let impl = makeWorkflowOrchestrationClient(root: PersistenceCore.defaultDataRoot())
        let rows = try await impl.listWorkflowRuns()
        let data = try JSONValue.array(rows).serializedData(pretty: false)
        return try JSONDecoder().decode([WorkflowRun].self, from: data)
    }

    /// Create/replace a workflow record through the Swift runtime. The
    /// SwiftNative client does the registry read->merge->filter->append->write
    /// plus activity/trace side-effects in-process.
    /// No Mac-UI view calls this yet (the route's only callers are
    /// script/smoke_all.sh + script/test.sh), so it exists to keep the cutover
    /// entry point complete for script and smoke-test callers.
    @discardableResult
    func createWorkflow(_ body: JSONValue) async throws -> WorkflowRecord {
        let impl = makeWorkflowOrchestrationClient(root: PersistenceCore.defaultDataRoot())
        let row = try await impl.createWorkflow(body)
        let data = try row.serializedData(pretty: false)
        return try JSONDecoder().decode(WorkflowRecord.self, from: data)
    }

    func getApprovals() async throws -> [ApprovalRequest] {
        return try await swiftListApprovals()
    }

    func getMCPServers() async throws -> [MCPServerRecord] {
        return try await swiftListMCPServers()
    }

    // Live MCP subprocess lifecycle (warm/restart/session table) is now
    // routed through SwiftNativeMCPDispatcher when .mcpDispatcher is on —
    // see MCPSubprocessClient.swift for the actor pool + 60s cache.
    func getMCPSessions() async throws -> [MCPSessionStatus] {
        return try await swiftListMCPSessions()
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

    func getResearchLabRuns() async throws -> [ResearchLabRun] {
        // Subsystem #17 wave 30 (W17): when .research is on, read the lab runs
        // in-process from data/research/lab/runs.json (sorted newest-first),
        // matching the daemon's research_lab_runs().
        return try await swiftResearchLabRuns()
    }

    func getTraces() async throws -> [RuntimeTrace] {
        // DAEMON-KILL P1: read tail of <dataRoot>/runtime/traces.jsonl.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("traces.jsonl")
        return tailJSONL(path: path, limit: 200)
    }

    func getAgentGraph() async throws -> AgentGraph {
        let projection = try await Self.canonicalAgentGraphProjection()
        let nodes = projection.entities.map {
            AgentGraphNode(id: $0.id, label: $0.name, kind: $0.kind, status: nil)
        }
        let executionCount = (try? await getWorkshopExecutions().count) ?? 0
        return AgentGraph(
            nodes: nodes,
            edges: projection.edges,
            summary: AgentGraphCounts(
                nodes: nodes.count,
                edges: projection.edges.count,
                executions: executionCount,
                capabilities: nil
            ),
            createdAt: projection.updatedAt
        )
    }

    func getGraphEntities() async throws -> [GraphEntity] {
        try await Self.canonicalAgentGraphProjection().entities
    }

    func getGraphStatus() async throws -> GraphIndexStatus {
        let projection = try await Self.canonicalAgentGraphProjection()
        return GraphIndexStatus(
            status: "ready",
            embeddingModel: "swift-memory-v2",
            dimensions: nil,
            nodeCount: projection.entities.count,
            entityCount: projection.entities.count,
            updatedAt: projection.updatedAt
        )
    }

    func searchGraph(query: String) async throws -> GraphSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GraphSearchResponse(
                query: query,
                results: [],
                summary: GraphSearchCounts(resultCount: 0, nodeCount: 0, edgeCount: 0),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        let envelope = try await makeKnowledgeGraphReader().searchChecked(q: trimmed)
        guard case .object(let object) = envelope,
              case .array(let rawResults)? = object["results"] else {
            throw KnowledgeGraphReadError.malformedEnvelope(
                "search projection did not contain a results array"
            )
        }
        let results: [GraphSearchResult] = rawResults.prefix(50).compactMap { value in
            guard case .object(let raw) = value,
                  let id = Self.graphString(raw["id"]),
                  !id.isEmpty else { return nil }
            let entity = Self.graphEntity(id: id, object: raw)
            return GraphSearchResult(
                id: entity.id,
                node: AgentGraphNode(
                    id: entity.id,
                    label: entity.name,
                    kind: entity.kind,
                    status: nil
                ),
                score: Self.graphDouble(raw["score"]) ?? 0,
                matchedTerms: [trimmed],
                matchedEntities: [entity.name],
                relatedEdges: nil,
                explanation: nil
            )
        }
        return GraphSearchResponse(
            query: query,
            results: results,
            summary: GraphSearchCounts(resultCount: results.count, nodeCount: results.count, edgeCount: 0),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getAutonomyKernel() async throws -> AutonomyKernelSummary {
        // DAEMON-DEAD PORT (2026-06-03): summarize the Swift-owned autonomy
        // gates from Trust policy plus local improvement run state. This is a
        // status surface only; action execution remains guarded by its own
        // native engines.
        let policy = try await getTrustPolicy()
        // U5 W-A item 1 (:5156): propagate — a failed improvements read
        // previously rendered as "0 running improvements" (healthy-empty).
        let improvements = try await getImprovements()
        let runningImprovements = improvements.filter {
            ["running", "queued", "planning", "executing"].contains($0.status.lowercased())
        }.count
        let processEnabled = true
        let trustEnabled = policy.enableAutonomy
        let enabled = processEnabled && trustEnabled
        let mode = policy.autonomyDefault ?? "supervised"
        let disabledReason: String? = {
            if !processEnabled { return "App autonomy process gate is disabled" }
            if !trustEnabled { return "Trust Center autonomy is disabled" }
            return nil
        }()

        let outside = policy.filePolicy?.outsideWorkspaceDefault ?? "deny"
        let backupRequired = policy.filePolicy?.requireBackupBeforeWrite ?? true
        let trainingEnabled = policy.trainingPolicy?.autonomous_training ?? false
        let promotionEnabled = policy.promotionPolicy?.enabled ?? false
        let memoryHygiene = policy.memoryPolicy?.hygiene_enabled ?? true

        return AutonomyKernelSummary(
            status: enabled ? "ok" : "off",
            mode: mode,
            enabled: enabled,
            processEnabled: processEnabled,
            trustEnabled: trustEnabled,
            disabledReason: disabledReason,
            guardrails: [
                KernelGuardrail(
                    id: "trust.enableAutonomy",
                    title: "Trust autonomy switch",
                    status: trustEnabled ? "ok" : "off"
                ),
                KernelGuardrail(
                    id: "file.outsideWorkspaceDefault",
                    title: "Outside-workspace file policy",
                    status: outside == "allow" ? "wide" : "guarded"
                ),
                KernelGuardrail(
                    id: "file.requireBackupBeforeWrite",
                    title: "Write backup requirement",
                    status: backupRequired ? "ok" : "warn"
                ),
                KernelGuardrail(
                    id: "training.autonomous_training",
                    title: "Autonomous training",
                    status: trainingEnabled ? "ok" : "off"
                ),
                KernelGuardrail(
                    id: "promotion.enabled",
                    title: "Promotion engine",
                    status: promotionEnabled ? "ok" : "off"
                ),
                KernelGuardrail(
                    id: "memory.hygiene_enabled",
                    title: "Memory hygiene",
                    status: memoryHygiene ? "ok" : "off"
                ),
            ],
            approvalClasses: [
                ApprovalClass(id: "external_send", title: "External sends", requiresApproval: true),
                ApprovalClass(id: "filesystem_write", title: "Filesystem writes", requiresApproval: true),
                ApprovalClass(id: "system_change", title: "System changes", requiresApproval: true),
                ApprovalClass(id: "safe_read", title: "Safe reads", requiresApproval: false),
            ],
            runningImprovements: runningImprovements,
            createdAt: SwiftNativeManifestSigner.isoTimestamp(Date())
        )
    }

    func getPersonalOS() async throws -> PersonalOSSummary {
        /// HONEST MINIMAL: NativeAgent ships a single active persona today
        /// (persona/profile.json), so the PersonalOS summary surfaces exactly
        /// one space derived from that file's `name`/`active` key. The daemon
        /// never aggregated additional spaces — there is no fan-out to port —
        /// so this is the real shape, not a stub. If/when multi-persona
        /// support lands, this aggregator is the seam to extend.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent("profile.json")
        var primaryName: String? = nil
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            primaryName = (obj["name"] as? String) ?? (obj["active"] as? String)
        }
        let spaces: [PersonalOSSpace]
        if let name = primaryName {
            spaces = [PersonalOSSpace(id: "persona", name: name, count: 1, kind: "persona")]
        } else {
            spaces = []
        }
        return PersonalOSSummary(
            spaces: spaces,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
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
        let merged = await listCapabilityCatalog(
            dataRoot: PersistenceCore.defaultDataRoot(),
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
            dataRoot: PersistenceCore.defaultDataRoot(),
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
            dataRoot: PersistenceCore.defaultDataRoot(),
            persistence: SwiftNativePersistenceCore()
        )
        let rows = try await writes.listCapabilityPackInstalls()
        let data = try JSONValue.array(rows.map { JSONValue.object($0) })
            .serializedData(pretty: false)
        return try JSONDecoder().decode([CapabilityPackInstall].self, from: data)
    }

    // SwiftNativeCapabilityTrust now serves the trust network in-process from
    // native capability records, catalog sources, and trust roots.
    func getCapabilityTrust() async throws -> CapabilityTrustNetwork {
        let impl = makeCapabilityTrust()
        let swiftResult = try await impl.network()
        // Bridge TrustCenter.CapabilityTrustNetwork → NativeAgentApp.CapabilityTrustNetwork.
        // Both are Codable with byte-identical shapes (verified 2026-05-31 against
        // CapabilityTrust.swift wire types vs Models.swift L1620). JSON round-trip
        // is the canonical seam — when the eventual full aggregator port lands,
        // this stays one line.
        let data = try JSONEncoder().encode(swiftResult)
        return try JSONDecoder().decode(CapabilityTrustNetwork.self, from: data)
    }

}
