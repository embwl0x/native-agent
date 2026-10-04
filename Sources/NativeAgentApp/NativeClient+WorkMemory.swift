import Foundation
import NativeAgentShared
import PersistenceCore
import MemoryV2
import ProviderRouting
import BackgroundLoops
import TrustCenter
import SelfImprovement
import WorkshopExecution
import TelegramBot
import Skills
import Connectors

extension NativeClient {
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
        let path = (dataRootOverride ?? PersistenceCore.defaultDataRoot())
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

    func getPersonality() async throws -> PersonalityProfile {
        return try await swiftPersonality()
    }

    func getSkills() async throws -> [SkillRecord] {
        let impl = makeSkillsClient(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let rows = try await impl.listSkills()
        let data = try JSONValue.array(rows).serializedData(pretty: false)
        // Use the SAME lossy per-row decode the HTTP getList path uses, so a
        // single malformed registry row drops that row instead of blanking
        // the whole list (gpt-5.5 review finding #1, 2026-06-01).
        return try Self.decodeLossyArray(data, context: "getSkills(swiftNative)")
    }

    func getConnectors() async throws -> [ConnectorRecord] {
        // DAEMON-DEAD PORT (2026-06-03): read the Swift-owned connector
        // registry directly and overlay only non-secret runtime readiness
        // signals (token/config presence). This restores the Connectors tab and
        // command-summary counts without routing through a daemon fallback.
        return try await Self.readConnectorRecords(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    func getWorkspaces() async throws -> [WorkspaceRecord] {
        // Subsystem #24 wave 31 (W14): when .connectors is on, read the saved
        // workspace rows in-process from <dataRoot>/connectors/workspaces.json
        // (pure read, no write-back, no secrets), matching Runtime.list_workspaces.
        let impl = makeConnectorsClient(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
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

    func getTrainingArtifacts() async throws -> [TrainingArtifact] {
        // Swift-native cutover port P2: was GET /v1/training. Read
        // `<dataRoot>/training/artifacts/index.json`; missing → `[]`.
        let url = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("training", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("index.json")
        return try Self.readLocalJSON(url, fallbackJSON: "[]")
    }

    func getImprovements() async throws -> [ImprovementRun] {
        // Only verified reads may replace the UI's last loaded runs.
        let actor = NativeClient._trainingPromotionActor()
        guard let runs = try await actor.listImprovementsVerified(),
              runs.allSatisfy({ $0.objective != nil && $0.status != nil && $0.phase != nil && $0.createdAt != nil }) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -503, userInfo: [
                NSLocalizedDescriptionKey: "Improvement runs are unavailable because the read could not be verified."
            ])
        }
        return runs
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
        let row: JSONValue = try Self.readLocalJSON(url, fallbackJSON: fallback)
        return try ImprovementSummary(persistedRow: row)
    }


    // Swift-native config aggregate. The daemon-era bridge file is retired:
    // each feature is read only from its owned per-feature path.
    func getConfig() async throws -> AppConfig {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
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

        config.telegram = await TelegramFacade(dataRoot: dataRoot).configuration()

        config.codexAuth = try? await ProvidersFacade(dataRoot: PersistenceCore.defaultDataRoot()).codexAuthStatus()
        config.modelRouting = try await Self.readModelRoutingConfig(dataRoot: dataRoot)
        return config
    }

}
