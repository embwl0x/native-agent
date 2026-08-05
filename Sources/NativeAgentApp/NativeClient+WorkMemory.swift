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
    func getWorkshopExecutions() async throws -> [WorkshopExecutionRecord] {
        // WAVE 32 W07: same SwiftNative read as getQueuedMissions(), decoded
        // into the camelCase-tolerant Models.swift WorkshopExecutionRecord via the shared
        // lossy decoder so the native path is decode-equivalent to the HTTP
        // getList (a malformed element drops, not the whole batch).
        // See CUTOVER_PLAN.md §6.82.
        let runner = makeWorkshopExecutionRunner()
        let merged = await runner.listWorkshopExecutionsMerged()
        let data = try JSONValue.array(merged).serializedData(pretty: false)
        return try Self.decodeLossyArray(data, context: "getWorkshopExecutions(swift Workshop; surface=executions)")
    }

    func getRuns() async throws -> [RunRecord] {
        // Lenient contract: any read/decode problem collapses to []. Callers
        // that must distinguish honest-absence from failure (the R25 snapshot
        // lane) use getRunsStrict() instead.
        await getRunsStrict() ?? []
    }

    // R25: strict variant — `[]` means the ledger genuinely doesn't exist (or
    // holds no runs); `nil` means a ledger EXISTS but could not be read or
    // decoded. The snapshot writer skips the write on nil so a corrupt ledger
    // never overwrites last-good runs.json with fabricated-empty state
    // (sync-audit #1 discipline).
    func getRunsStrict() async -> [RunRecord]? {
        // DAEMON-KILL P1: read <dataRoot>/runs/runs.json. The on-disk shape may
        // be a bare array or {"runs": [...]}; try both. Sort newest-first by
        // createdAt and slice to a sane default limit.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("runs.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder.nativeAgent
        var rows: [RunRecord]
        if let arr = try? decoder.decode([RunRecord].self, from: data) {
            rows = arr
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runs = obj["runs"],
                  let runsData = try? JSONSerialization.data(withJSONObject: runs),
                  let arr = try? decoder.decode([RunRecord].self, from: runsData) {
            rows = arr
        } else {
            return nil
        }
        rows.sort { $0.createdAt > $1.createdAt }
        return Array(rows.prefix(200))
    }

    func getMemories() async throws -> [MemoryRecord] {
        // fix2/F1: memory truth is <dataRoot>/memory/memory.sqlite. The
        // legacy <dataRoot>/memory/memory.json fallback was a stale dup the
        // migrator drains into SQLite — reading it here showed stale rows
        // after the daemon was killed. Query MemoryStorage directly, cap at
        // the same 200 the UI list expects, then encode → decode into the
        // NativeAgentShared.MemoryRecord shape the UI uses (its memberwise
        // init is internal, so we round-trip through JSON).
        let dataRoot = PersistenceCore.defaultDataRoot()
        guard let storage = try? MemoryStorage(dataRoot: dataRoot) else { return [] }
        let stored: [StoredMemory]
        do {
            stored = try await storage.listMemories(persona: nil, status: "active", limit: 200)
        } catch {
            return []
        }
        let rows: [[String: Any]] = stored.map { m in
            var dict: [String: Any] = [
                "id": m.id,
                "layer": "semantic",
                "text": m.content,
                "importance": 0.0,
                "confidence": m.confidence,
                "createdAt": m.createdAt,
                "updatedAt": m.updatedAt,
            ]
            if let s = m.source { dict["sourceRunId"] = s }
            dict["status"] = m.status
            // updateMemory() writes metadata.pinned; surface it on the row so
            // the UI's pin badge reflects the real SQLite truth (was always
            // false because the field was dropped on the way out).
            var isPinned = false
            if case .object(let obj)? = m.metadata,
               case .bool(let b)? = obj["pinned"] {
                isPinned = b
            }
            dict["pinned"] = isPinned
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return [] }
        return try Self.decodeLossyArray(data, context: "getMemories(swift sqlite)")
    }

    func getPersonality() async throws -> PersonalityProfile {
        return try await swiftPersonality()
    }

    func getSkills() async throws -> [SkillRecord] {
        let impl = makeSkillsClient(root: PersistenceCore.defaultDataRoot())
        let rows = try await impl.listSkills()
        let data = try JSONValue.array(rows).serializedData(pretty: false)
        // Use the SAME lossy per-row decode the HTTP getList path uses, so a
        // single malformed registry row drops that row instead of blanking
        // the whole list (gpt-5.5 review finding #1, 2026-06-01).
        return try Self.decodeLossyArray(data, context: "getSkills(swiftNative)")
    }

    func getTools() async throws -> [ToolRecord] {
        return try await swiftListTools()
    }

    func getTrustPolicy() async throws -> TrustPolicy {
        // Wave-3 swift gate re-enabled 2026-05-31. SwiftNative
        // TrustCenter._normalize_trust_policy now preserves the retired policy semantics:
        // autonomyDefault validity, filePolicy.outsideWorkspaceDefault
        // backfill, Full-Mac expiry/developerMode/confirmed-at stamps,
        // per-surface providerPolicy fallback_chain backfill with the
        // anthropic_oauth_direct insertion rule, and
        // completion_guard_max_repairs floor. Backed by byte-equivalence
        // tests in TrustCenterTests.
        return try await swiftTrustPolicy()
    }

    func getBackups() async throws -> [BackupRecord] {
        // DAEMON-DEAD PORT (2026-06-03): the old daemon wrote
        // `<dataRoot>/backups/registry.json`; the first Swift read-only port
        // looked only at `index.json`, which hid all existing backups. Read both,
        // de-dupe by id, and sort newest-first for the Mac UI.
        return try Self.readBackupRecords(root: PersistenceCore.defaultDataRoot())
    }

    func getConnectors() async throws -> [ConnectorRecord] {
        // DAEMON-DEAD PORT (2026-06-03): read the Swift-owned connector
        // registry directly and overlay only non-secret runtime readiness
        // signals (token/config presence). This restores the Connectors tab and
        // command-summary counts without routing through a daemon fallback.
        return try await Self.readConnectorRecords(root: PersistenceCore.defaultDataRoot())
    }

    func getWorkspaces() async throws -> [WorkspaceRecord] {
        // Subsystem #24 wave 31 (W14): when .connectors is on, read the saved
        // workspace rows in-process from <dataRoot>/connectors/workspaces.json
        // (pure read, no write-back, no secrets), matching Runtime.list_workspaces.
        let impl = makeConnectorsClient(root: PersistenceCore.defaultDataRoot())
        let rows = try await impl.listWorkspaces()
        let data = try JSONValue.array(rows).serializedData(pretty: false)
        return try JSONDecoder().decode([WorkspaceRecord].self, from: data)
    }

    func getEvals() async throws -> [EvalRun] {
        // wave 31 W09 — Swift-native eval run reader.
        return try await swiftGetEvals()
    }

    func getReleaseChecklist() async throws -> ReleaseChecklist {
        // Swift-native cutover port P2: was GET /v1/release/checklist. Read the same
        // file the daemon served (`<dataRoot>/release/checklist.json`); fall
        // back to a synthesized empty record. ReleaseChecklist's custom
        // init(from:) decodeIfPresent's every field, so `{}` decodes cleanly.
        let url = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("checklist.json")
        return try Self.readLocalJSON(url, fallbackJSON: "{}")
    }

    func getWatchdog() async throws -> WatchdogStatus {
        await BackgroundLoopsManager.shared.start()
        let loopStatuses = await BackgroundLoopsManager.shared.status()
        let running = await BackgroundLoopsManager.shared.isRunning()
        let uptime = await BackgroundLoopsManager.shared.uptimeSeconds()
        let loops: JSONValue = .array(loopStatuses.sorted { $0.loopId < $1.loopId }.map { loop in
            .object([
                "name": .string(loop.loopId),
                "running": .bool(loop.running),
            ])
        })
        let status = BackgroundLoops.WatchdogStatus(
            daemon: "swift",
            uptimeSeconds: uptime,
            daemonLifecycleStatus: running ? "ok" : "stopped",
            daemonLifecycleDetail: running
                ? "Swift background loops are running in NativeAgent.app."
                : "Swift background loops are not running.",
            launchAgentStatus: "not_applicable",
            launchAgentDetail: "NativeAgent.app owns background loops; legacy daemon launch agents are retired.",
            runningImprovements: 0,
            runningExecutions: 0,
            lastActivity: nil,
            repairAvailable: false,
            extras: .object([
                "backend": .string("swift"),
                "source": .string("app_background_loops_manager"),
                "loopCount": .int(Int64(loopStatuses.count)),
                "running": .bool(running),
                "loops": loops,
            ])
        )
        let data = try JSONEncoder().encode(status)
        return try JSONDecoder().decode(WatchdogStatus.self, from: data)
    }

    func getTrainingArtifacts() async throws -> [TrainingArtifact] {
        // Swift-native cutover port P2: was GET /v1/training. Read
        // `<dataRoot>/training/artifacts/index.json`; missing → `[]`.
        let url = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("training", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("index.json")
        return try Self.readLocalJSON(url, fallbackJSON: "[]")
    }

    func getJobs() async throws -> [SchedulerJob] {
        // WAVE 38 W15 (2026-06-02): SwiftNative TriggerScheduler list_jobs reads
        // flock'd jobs.json and decorates nextRunAt epoch values into ISO strings.
        // Decode those rows into [SchedulerJob] for the app UI. See
        // CUTOVER_PLAN.md §6.180.
        let writer = makeSchedulerJobWriter(connectorActionIDs: Self.connectorActionIDSet())
        let rows = try await writer.listJobs()
        let data = try JSONValue.array(rows).serializedData(pretty: false)
        return try JSONDecoder().decode([SchedulerJob].self, from: data)
    }

    func getImprovements() async throws -> [ImprovementRun] {
        // WAVE 37 W04 (§6.159): COMMIT-MARKER verified-fresh local read. The
        // legacy list_improvements() flow ran a write-on-read reconcile, and
        // runs.json is mutated by reconcile/finalize/heartbeat writers; a naive
        // local read could serve a `running`/non-transient row from a window
        // where a writer was mid-update. The verified read runs a seq->runs->seq
        // sandwich against the commit marker (improvements/runs.commit) and
        // returns nil if a writer raced the read (seq moved) or no marker is
        // provable yet; with no verified-fresh native data, the Swift-only UI
        // returns an empty list rather than stale state. Mac-only (iOS has no
        // local runs.json). See CUTOVER_PLAN.md §6.159; closes §6.158 #4.
        // NativeClient.swift wraps
        // the Mac ImprovementRun shape, which round-trips losslessly through the
        // module's ImprovementRun via JSON.
        let actor = NativeClient._trainingPromotionActor()
        if let verified = try? await actor.listImprovementsVerified(),
           // Re-encode the module's ImprovementRun (custom Codable that
           // round-trips all known keys + extras) to JSON, then decode into
           // the Mac app's ImprovementRun (Models.swift) — the same shape
            // the old route returned, so the UI is shape-equivalent. Any
           // encode/decode mismatch (e.g. a run missing a Mac-required key)
            // degrades to nil here and falls through to the Swift-only empty
            // result below rather than throwing.
           let data = try? JSONEncoder().encode(verified),
           let runs = try? JSONDecoder.nativeAgent.decode([ImprovementRun].self, from: data) {
            return runs
        }
        // No verified-fresh native data in the Swift-only runtime; return empty.
        return []
    }

    func getImprovementSummary() async throws -> ImprovementSummary {
        // Swift-native cutover port P2: was GET /v1/improvements/summary. Read
        // `<dataRoot>/improvements/summary.json`; missing → synthesized
        // disabled/empty record so the UI panel renders the "no data" state.
        let url = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("summary.json")
        let fallback = #"""
        {"enabled":false,"status":"unavailable","runningCount":0,"succeededCount":0,"failedCount":0,"interruptedCount":0,"totalCount":0,"stagedCount":0,"recurringImproveJobs":[],"personalityGrowthEntries":0,"smokeJobCount":0,"oldInterruptedCount":0,"repairableReceiptFailureCount":0,"dataRoot":"","createdAt":""}
        """#
        return try Self.readLocalJSON(url, fallbackJSON: fallback)
    }

    func getHarnessLearningReceipts(limit: Int = 50) async throws -> [HarnessLearningReceipt] {
        // DAEMON-DEAD PORT (2026-06-03): read the harness learning receipt
        // ledger directly. The file is append-only JSONL and already matches
        // HarnessLearningReceipt's camelCase model shape.
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("learning_receipts.jsonl")
        let cap = max(1, min(limit, 200))
        let persistence = SwiftNativePersistenceCore()
        // U5 W-A item 1 (:6384): propagate — a swallowed read rendered as
        // "no learning receipts" (healthy-empty) instead of the real error.
        let rows = try await persistence.tailJSONL(path, limit: cap, maxBytes: nil)
        var receipts: [HarnessLearningReceipt] = []
        let decoder = JSONDecoder.nativeAgent
        for row in rows {
            guard let data = try? row.serializedData(pretty: false),
                  let receipt = try? decoder.decode(HarnessLearningReceipt.self, from: data) else {
                continue
            }
            receipts.append(receipt)
        }
        return receipts.sorted { $0.createdAt > $1.createdAt }
    }

    func getHarnessLearningProposals(limit: Int = 50) async throws -> [HarnessLearningProposal] {
        // Swift-native cutover port P2: was GET /v1/harness/learning/proposals. Read
        // `<dataRoot>/improvements/proposals.jsonl` directly — newest-last
        // append-only file. Decode one record per line and apply `limit` from
        // the tail (the daemon route's pagination semantics).
        let url = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("proposals.jsonl")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder.nativeAgent
        var rows: [HarnessLearningProposal] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            if let row = try? decoder.decode(HarnessLearningProposal.self, from: lineData) {
                rows.append(row)
            }
        }
        let cap = max(1, min(limit, 200))
        if rows.count > cap {
            rows = Array(rows.suffix(cap))
        }
        return rows
    }

    // Swift-native config aggregate. The daemon-era bridge file is retired:
    // each feature is read only from its owned per-feature path.
    func getConfig() async throws -> AppConfig {
        let dataRoot = PersistenceCore.defaultDataRoot()
        var config = AppConfig()

        let researchPath = dataRoot
            .appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: researchPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = parsed["searxng_base_url"] as? String {
            config.searxngBaseURL = raw
        } else {
            config.searxngBaseURL = ""
        }

        config.autoDoctor = Self.readAutoDoctorConfig(dataRoot: dataRoot)

        if let cfg = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot) {
            var telegram = TelegramConfig()
            telegram.enabled = cfg.enabled
            telegram.tokenConfigured = !cfg.botToken.isEmpty
            telegram.allowedChatIds = cfg.allowedChatIds.sorted().map { String($0) }
            telegram.allowedUserIds = cfg.allowedUserIds.sorted().map { String($0) }
            telegram.requireMention = cfg.requireMention
            telegram.model = cfg.model
            telegram.reasoningEffort = cfg.reasoningEffort
            config.telegram = telegram
        }

        config.codexAuth = try? await getCodexAuthStatus()
        config.modelRouting = Self.readModelRoutingConfig(dataRoot: dataRoot)
        return config
    }

}
