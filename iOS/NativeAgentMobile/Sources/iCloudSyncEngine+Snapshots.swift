import Foundation
import NativeAgentShared
import os
import SwiftUI
// Blueprint: | `iCloudSyncEngine+Snapshots.swift` | `iCloudSyncEngine`: `applyHelpersSnapshot`, `refreshHelpersSnapshot`, `applyProviderState` |

/// A malformed page owns its decode failure; the surrounding dictionary remains readable.
private struct PhoneFacePages: Decodable, Sendable {
    let pages: [String: PartFaceSnapshot]

    private struct PageKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: PageKey.self)
        var pages: [String: PartFaceSnapshot] = [:]
        for key in container.allKeys {
            do { pages[key.stringValue] = try container.decode(PartFaceSnapshot.self, forKey: key) }
            catch {
                pages[key.stringValue] = PartFaceSnapshot(part: key.stringValue, version: nil, sourceEpoch: 0,
                    status: .failed, face: nil, error: PartCallError(code: "bad_face",
                        message: "This iPhone couldn't read this page: \(error). Update NativeAgent on this iPhone or repair the page on your Mac."),
                    owed: false)
            }
        }
        self.pages = pages
    }
}

enum ProviderControlsRefreshOutcome: Equatable, Sendable {
    case refreshed
    case partial
    case unavailable
    case superseded

    static let filenames: Set<String> = ["providers.json", "trust_policy.json", "model_preferences.json"]

    func feedbackMessage(damage: String?) -> String? {
        switch self {
        case .refreshed:
            damage
        case .partial:
            damage
                ?? "Couldn't fully refresh models. Some model settings are still downloading from iCloud. Try again in a moment."
        case .unavailable:
            damage
                ?? "Couldn't refresh models. Provider snapshots are still downloading from iCloud. Try again in a moment."
        case .superseded:
            "Couldn't refresh models because iCloud sync was reconfigured. Try again."
        }
    }
}

enum AdvancedSnapshotRefreshOutcome: Equatable, Sendable {
    case refreshed
    case partial
    case unavailable
    case superseded
}

struct SettingsSnapshotRefreshOutcome: Equatable, Sendable {
    static let filenames: Set<String> = ["trust_policy.json", "personality.json", "connectors.json", "health.json"]

    enum Field: CaseIterable, Hashable, Sendable {
        case trustPolicy, personality, connectors, health
    }

    enum State: Equatable, Sendable {
        case refreshed, partial, unavailable, superseded
    }

    var availableFields: Set<Field>
    var wasSuperseded = false
    var damage: String? = nil

    var state: State {
        if wasSuperseded { return .superseded }
        if availableFields.count == Field.allCases.count { return .refreshed }
        return availableFields.isEmpty ? .unavailable : .partial
    }

    var feedbackMessage: String? {
        switch state {
        case .refreshed:
            damage
        case .partial:
            damage ?? "Some Settings snapshots are still downloading from iCloud."
        case .unavailable:
            damage ?? "Settings snapshots are still downloading from iCloud. Try again in a moment."
        case .superseded:
            "Settings refresh was interrupted by an iCloud reconfiguration. Try again."
        }
    }
}

extension iCloudSyncEngine {
    /// Retain newer canonical rows and removals until the Mac snapshot revision acknowledges their readbacks.
    func orderedSnapshot<Row: Decodable & Identifiable & Sendable>(
        _ read: MacSnapshotRead<[Row]>, file: String, current: [Row]
    ) -> [Row] where Row.ID == String {
        if read.revision < (snapshotReadRevisions[file] ?? 0) { return current }
        snapshotReadRevisions[file] = read.revision
        let newer = (recordReadbackRevisions[file] ?? [:]).filter { $0.value > read.revision }
        recordReadbackRevisions[file] = newer
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let incomingIDs = Set(read.value.map(\.id))
        return read.value.compactMap { newer[$0.id] == nil ? $0 : currentByID[$0.id] }
            + current.filter { newer[$0.id] != nil && !incomingIDs.contains($0.id) }
    }

    func installReadback(revision: Double, file: String, id: String) -> Bool {
        let applied = max(snapshotReadRevisions[file] ?? 0, recordReadbackRevisions[file]?[id] ?? 0)
        if revision < applied { return false }
        recordReadbackRevisions[file, default: [:]][id] = revision
        return true
    }

    func applyConnectorSnapshot(_ rows: [MobileConnectorSnapshot]) {
        let currentByID = Dictionary(connectors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        connectors = rows.map { row in
            guard let current = currentByID[row.id],
                  (current.updatedAt ?? "") > (row.updatedAt ?? "") else { return row }
            return current
        }
    }

    func refreshTelegramSnapshot() async -> Bool {
        let lifecycle = lifecycleGeneration
        var refreshed = false
        _ = await telegramRead.read({ () async -> SnapshotReading<MobileTelegramSnapshot> in
            await loadSnapshotObjectAsync(named: "telegram.json")
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            guard let snapshot = acceptSnapshot(read, named: "telegram.json") else { return }
            guard snapshot.observedAt.isFinite, snapshot.observedAt > 0 else {
                snapshotHealth["telegram.json"] = .readFailed(reason: "The Telegram snapshot has an invalid observation date.")
                syncError = snapshotHealth.damageSentence(for: ["telegram.json"])
                return
            }
            telegram = snapshot
            refreshed = true
        })
        return refreshed
    }

    private func readOrganismSnapshot(in directory: URL) async -> SnapshotReading<OrganismLivingStatusFile> {
        let lifecycle = lifecycleGeneration
        return await organismRead.read({ () async -> SnapshotReading<OrganismLivingStatusFile> in
            let read: SnapshotReading<OrganismLivingStatusFile> = await Self.loadSnapshotObjectOnly(
                named: "organism_living_status.json", in: directory)
            if let value = read.value, !value.generatedAt.timeIntervalSince1970.isFinite {
                return (nil, .readFailed(reason: "The organism snapshot has an invalid generation date."))
            }
            return read
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            if let value = acceptSnapshot(read, named: "organism_living_status.json") { organismLivingStatus = value }
        })
    }

    func applyHelpersSnapshot(_ incoming: MobileHelpersSnapshot) {
        let currentByID = Dictionary((helpersSnapshot?.helpers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = incoming
        snapshot.helpers = snapshot.helpers.map { row in
            if let current = currentByID[row.id],
               (current.revision ?? 0) > (row.revision ?? 0) { return current }
            return row
        }
        helpersSnapshot = snapshot
        let agents = Dictionary(grouping: snapshot.agents, by: \.id)
        agentThreads = agentThreads.filter { id, thread in agents[id]?.contains(thread.agent.summary) == true }
    }

    @discardableResult
    func refreshHelpersSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        await refreshSnapshotStaleness()
        let read: SnapshotReading<MobileHelpersSnapshot> = await Self.loadSnapshotObjectOnly(named: "helpers_agents.json", in: snapshotDir)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        guard let snapshot = acceptSnapshot(read, named: "helpers_agents.json") else { return false }
        applyHelpersSnapshot(snapshot)
        return staleSnapshotGroups["helpers_agents"] == nil
    }

    /// Successful refreshes retain diagnostics from accepted, partially decoded data.
    func noteRefreshSucceeded(files: Set<String>? = nil) {
        lastSyncAt = Date()
        syncError = snapshotHealth.damageSentence(for: files)
        PhoneRequests.shared.syncDidSucceed()
    }

    /// Validate provider projection atomically; malformed/future payloads must preserve the admitted catalog rather than blank the picker.
    @discardableResult
    func applyProviderCatalogStatus(_ value: String, originatingPairing pairing: Data, isCurrent: @MainActor () -> Bool) async -> Bool {
        let lifecycle = lifecycleGeneration
        guard pairing.count == 32, pairing == pairingStore?.iCloudPairingSecret else { return false }
        let result = await Task.detached(priority: .userInitiated) { () throws -> ([ProviderInfo], MacSnapshotRead<[String: NAProviderSurfaceSelection]>) in
            let catalog = try NAProviderCatalogStatusCodec.decode(value)
            let providers = catalog.providers.map { provider in
                ProviderInfo(
                    provider_id: provider.providerID,
                    display_name: provider.displayName,
                    auth_modes: provider.authModes,
                    auth_status: ProviderAuthStatus(
                        provider_id: provider.providerID,
                        state: provider.authState,
                        detail: "",
                        user_info: nil,
                        last_checked_at: nil,
                        eligible: provider.eligible
                    ),
                    models: provider.models.map { model in
                        ProviderModelInfo(
                            id: model.id,
                            name: model.name,
                            context_length: model.contextLength,
                            supports_streaming: model.supportsStreaming,
                            supports_vision: model.supportsVision,
                            supports_tools: model.supportsTools,
                            supports_json_mode: model.supportsJSONMode,
                            cost_per_1k_in: nil,
                            cost_per_1k_out: nil,
                            default_reasoning_effort: model.defaultReasoningEffort,
                            supported_reasoning_efforts: model.supportedReasoningEfforts,
                            supports_fast: model.supportsFast,
                            controls_note: model.controlsNote,
                            offered: model.offered,
                            offer_note: model.offerNote
                        )
                    }
                )
            }
            return (providers, MacSnapshotRead(revision: catalog.routingRevision, value: catalog.surfaces))
        }.result
        guard !Task.isCancelled, isCurrent(), lifecycle == lifecycleGeneration,
              pairing == pairingStore?.iCloudPairingSecret else { return false }
        switch result {
        case .success(let (providers, surfaceModels)):
            applyProviderState(providers: providers, surfaceModels: surfaceModels)
            noteRefreshSucceeded()
            return true
        case .failure(let error):
            syncError = "Provider catalog sync failed: \(error.localizedDescription)"
            return false
        }
    }

    // Order snapshots/readbacks by the routing owner's revision; do not reintroduce an already acknowledged pending fence.
    private func applyProviderState(providers nextProviders: [ProviderInfo]?, surfaceModels incoming: MacSnapshotRead<[String: NAProviderSurfaceSelection]>?) {
        if let nextProviders, providers != nextProviders { providers = nextProviders }
        guard let incoming else { return }
        var next = surfaceModels
        for surface in Set(next.keys).union(incoming.value.keys)
        where incoming.revision >= (surfaceModelRevisions[surface] ?? 0) {
            surfaceModelRevisions[surface] = incoming.revision
            next[surface] = incoming.value[surface]
        }
        for (surface, newPref) in next {
            guard let prev = surfaceModels[surface], prev.model != newPref.model else { continue }
            let changeMessage = switch ProviderSurfaceLabel.presentation(for: surface) {
            case .named(let surfaceName): "Mac changed the model for \(surfaceName)"
            default: "Mac changed a model"
            }
            let modelName = providers
                .filter { newPref.providerID == nil || $0.provider_id == newPref.providerID }
                .flatMap(\.models).first { $0.id == newPref.model }?
                .name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let modelName, !modelName.isEmpty, modelName != newPref.model {
                SystemToastCenter.shared.push(info: "\(changeMessage) to \(modelName).")
            } else {
                SystemToastCenter.shared.push(info: "\(changeMessage).")
            }
        }
        if surfaceModels != next { surfaceModels = next }
    }

    // MARK: - Snapshot refresh

    private func finishSnapshotRefresh(lifecycle: UInt64) {
        guard lifecycle == lifecycleGeneration else { return }
        refreshInFlight = false
        guard refreshQueued else { return }
        refreshQueued = false
        Task { @MainActor in
            guard lifecycle == self.lifecycleGeneration else { return }
            await self.refreshLightweightSnapshots()
        }
    }

    @discardableResult
    func refreshLightweightSnapshots() async -> Bool {
        guard let snapshotDir else { return false }
        // Refresh drives the rate-limited mailbox prune without a separate timer.
        pruneEphemeralDirectoriesIfDue()
        let lifecycle = lifecycleGeneration
        if refreshInFlight {
            refreshQueued = true
            return false
        }
        let personalityPairing = pairingStore?.iCloudPairingSecret
        refreshInFlight = true
        defer { finishSnapshotRefresh(lifecycle: lifecycle) }
        var refreshed = false
        var publishedGroups = 0
        var overview: SnapshotReading<WorkOverview> = (nil, nil)
        var workActivity: SnapshotReading<MobileWorkActivitySnapshot> = (nil, nil)
        var layout: SnapshotReading<SurfaceLayoutAvailability> = (nil, nil)
        _ = await snapshotRead.read({ () async -> LightweightSnapshotBundle in
            await approvalsRead.read({ () async -> LightweightSnapshotBundle in
                await sessionListRead.read({ () async -> LightweightSnapshotBundle in
                    async let latestOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(
                        named: "work_overview.json", in: snapshotDir)
                    let bundle = await loadLightweightSnapshots(snapshotDir: snapshotDir)
                    _ = await refreshTelegramSnapshot()
                    overview = await latestOverview
                    workActivity = await Self.loadSnapshotObjectOnly(named: "work_activity.json", in: snapshotDir)
                    layout = await Self.loadSnapshotObjectOnly(named: "ui_layout.json", in: snapshotDir)
                    return bundle
                }, publish: { bundle in
                    guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
                    if let v = acceptSnapshot(bundle.sessions, named: "sessions.json"), sessions != v { sessions = v }
                    if let v = acceptSnapshot(bundle.pinnedChatSessions, named: "pinned_chat_sessions.json") { sessionNavigation = v }
                    publishedGroups += 1
                })
            }, publish: { bundle in
                guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
                if let v = acceptSnapshot(bundle.approvals, named: "approvals.json") {
                    approvalsSnapshotLoaded = true
                    approvals = orderedSnapshot(v, file: "approvals.json", current: approvals)
                }
                publishedGroups += 1
            })
        }, publish: { bundle in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            applyWorkOverview(acceptSnapshot(overview, named: "work_overview.json"))
            if let workActivity = acceptSnapshot(workActivity, named: "work_activity.json") { PhoneTurnActivity.shared.receive(workActivity) }
            if let accepted = acceptSnapshot(layout, named: "ui_layout.json") {
                if accepted.value != nil || surfaceLayout?.value == nil { surfaceLayout = accepted }
                if let failure = accepted.failure {
                    snapshotHealth["ui_layout.json"] = .readFailed(reason: failure.localizedDescription)
                }
            }
            adoptLightweightSnapshot(bundle, pairing: personalityPairing)
            if bundle.loadedAllSnapshots {
                noteRefreshSucceeded()
                refreshed = publishedGroups == 2
            } else if bundle.loadedAnySnapshot {
                syncError = snapshotHealth.damageSentence()
                    ?? "Some lightweight iCloud snapshots are still downloading."
            } else {
                syncError = snapshotHealth.damageSentence()
                    ?? "No iCloud snapshots found yet. Keep the Mac app open until sync completes."
            }
        })
        return refreshed
    }

    @discardableResult
    func refreshTurnSummariesSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<TurnSummaryFile> = await Self.loadSnapshotObjectOnly(named: "turn_summaries.json", in: snapshotDir)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        if let latest = acceptSnapshot(read, named: "turn_summaries.json") {
            turnSummaries = latest
            noteRefreshSucceeded()
            return true
        }
        return false
    }

    /// Read Mac per-group staleness; a missing file cannot clear the previous verdict.
    func refreshSnapshotStaleness() async {
        guard let snapshotDir else { return }
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<[String: String]> = await Self.loadSnapshotObjectOnly(named: "snapshot_staleness.json", in: snapshotDir)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
        guard let markers = acceptSnapshot(read, named: "snapshot_staleness.json") else { return }
        staleSnapshotGroups = NAMobileSnapshotGroup.stalenessMessages(markers)
    }

    func refreshApprovalsSnapshot() async {
        guard let snapshotDir else { return }
        let lifecycle = lifecycleGeneration
        _ = await approvalsRead.read({
            async let latestOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(
                named: "work_overview.json", in: snapshotDir)
            let latest: SnapshotReading<MacSnapshotRead<[ApprovalRequest]>> = await Self.loadSnapshotObjectOnly(named: "approvals.json", in: snapshotDir)
            return (latest: latest, overview: await latestOverview)
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            applyWorkOverview(acceptSnapshot(read.overview, named: "work_overview.json"))
            if let latest = acceptSnapshot(read.latest, named: "approvals.json") {
                approvalsSnapshotLoaded = true
                approvals = orderedSnapshot(latest, file: "approvals.json", current: approvals)
                noteRefreshSucceeded()
            }
        })
    }

    @discardableResult
    func refreshActivitySnapshot(recovery: DeviceSyncRecovery = .init()) async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        let read = await readActivitySnapshots(snapshotDir: snapshotDir, lifecycle: lifecycle, recovery: recovery)
        guard !Task.isCancelled, lifecycle == lifecycleGeneration else { return false }
        if read.loadedAll {
            noteRefreshSucceeded()
        } else {
            syncError = snapshotHealth.damageSentence() ?? "Some Activity snapshots are still downloading."
        }
        return read.loadedAll && read.publishedAll
    }

    @discardableResult
    func refreshWorkActivitySnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<MobileWorkActivitySnapshot> = await Self.loadSnapshotObjectOnly(named: "work_activity.json", in: snapshotDir)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        guard let snapshot = acceptSnapshot(read, named: "work_activity.json") else { return false }
        PhoneTurnActivity.shared.receive(snapshot)
        return true
    }

    /// Every page's face, as the Mac last published them.
    func refreshFacesSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<PhoneFacePages> = await Self.loadSnapshotObjectOnly(named: "faces.json", in: snapshotDir)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        guard let snapshot = acceptSnapshot(read, named: "faces.json") else { return false }
        faces = snapshot.pages
        return true
    }

    func refreshCatalogSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        async let skillRows: SnapshotReading<[SkillManifestEntry]> = Self.loadSnapshotArrayOnly(named: "skills_snapshot.json", in: snapshotDir)
        async let toolRows: SnapshotReading<[MobileToolCatalogRecord]> = Self.loadSnapshotArrayOnly(named: "tools_snapshot.json", in: snapshotDir)
        let (skillRowsValue, toolRowsValue) = await (skillRows, toolRows)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        if let rows = acceptSnapshot(skillRowsValue, named: "skills_snapshot.json") { skills = rows }
        if let rows = acceptSnapshot(toolRowsValue, named: "tools_snapshot.json") { tools = rows }
        if skillRowsValue.value != nil && toolRowsValue.value != nil {
            noteRefreshSucceeded()
            return true
        }
        return false
    }

    @discardableResult
    func refreshKnowledgeGraphSnapshot() async -> Bool {
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<KGEntityResponse> = await loadSnapshotObjectAsync(named: "knowledge_graph.json")
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        guard let snapshot = acceptSnapshot(read, named: "knowledge_graph.json") else { return false }
        knowledgeGraph = snapshot
        return true
    }

    @discardableResult
    func refreshDeskSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        var refreshed = false
        _ = await deskRead.read({ () async -> SnapshotReading<WorkOverview> in
            await Self.loadSnapshotObjectOnly(named: "work_overview.json", in: snapshotDir)
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            if let overview = acceptSnapshot(read, named: "work_overview.json") {
                applyWorkOverview(overview)
                noteRefreshSucceeded()
                refreshed = true
            } else {
                syncError = snapshotHealth.damageSentence() ?? "Desk is still syncing from the Mac. Try again in a moment."
            }
        })
        return refreshed
    }

    /// Missing/unreadable overview is not empty; it cannot replace a newer delivered copy.
    func applyWorkOverview(_ overview: WorkOverview?) {
        guard let overview, let incoming = DeskActivityState.movementDate(overview.capturedAt) else { return }
        if let current = workOverview.flatMap({ DeskActivityState.movementDate($0.capturedAt) }), incoming <= current {
            if incoming < current {
                NSLog("[iCloudSync] work overview refused older capturedAt=%@", overview.capturedAt)
            }
            return
        }
        workOverview = overview
        NSLog("[iCloudSync] work overview applied capturedAt=%@", overview.capturedAt)
    }

    @discardableResult
    func refreshSettingsSnapshot() async -> SettingsSnapshotRefreshOutcome {
        guard let snapshotDir else {
            return SettingsSnapshotRefreshOutcome(availableFields: [])
        }
        let lifecycle = lifecycleGeneration
        let personalityPairing = pairingStore?.iCloudPairingSecret
        async let latestTrust = readTrustSnapshot(in: snapshotDir)
        async let latestPersonality: SnapshotReading<PersonalityProfile> = Self.loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        async let latestConnectors: SnapshotReading<[MobileConnectorSnapshot]> = Self.loadSnapshotArrayOnly(named: "connectors.json", in: snapshotDir)
        async let latestHealth: SnapshotReading<RuntimeHealth> = Self.loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        let (trustRead, personalityRead, connectorRead, healthRead) = await (latestTrust, latestPersonality, latestConnectors, latestHealth)
        guard lifecycle == lifecycleGeneration,
              personalityPairing == pairingStore?.iCloudPairingSecret, !Task.isCancelled else {
            return SettingsSnapshotRefreshOutcome(availableFields: [], wasSuperseded: true)
        }
        let trustRow = trustRead.value
        let personalityRow = acceptSnapshot(personalityRead, named: "personality.json")
        let connectorRows = acceptSnapshot(connectorRead, named: "connectors.json")
        let healthRow = acceptSnapshot(healthRead, named: "health.json")
        var availableFields: Set<SettingsSnapshotRefreshOutcome.Field> = []
        if trustRow != nil { availableFields.insert(.trustPolicy) }
        if personalityRow != nil { availableFields.insert(.personality) }
        if connectorRows != nil { availableFields.insert(.connectors) }
        if healthRow != nil { availableFields.insert(.health) }
        let outcome = SettingsSnapshotRefreshOutcome(availableFields: availableFields, damage: snapshotHealth.damageSentence(
            for: SettingsSnapshotRefreshOutcome.filenames))
        if let personalityRow { applyPersonality(personalityRow, pairing: personalityPairing) }
        if let connectorRows { applyConnectorSnapshot(connectorRows) }
        if let healthRow { health = healthRow }
        if outcome.state == .refreshed {
            noteRefreshSucceeded(files: SettingsSnapshotRefreshOutcome.filenames)
        } else {
            syncError = outcome.feedbackMessage
        }
        return outcome
    }

    @discardableResult
    func refreshHealthSnapshot() async -> (outcome: AdvancedSnapshotRefreshOutcome, feedbackMessage: String?) {
        guard let snapshotDir else {
            health = nil
            organismLivingStatus = nil
            return (.unavailable, "Health snapshot is still downloading from iCloud. Try again in a moment.")
        }
        let lifecycle = lifecycleGeneration
        async let healthRead: SnapshotReading<RuntimeHealth> = Self.loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        async let organismRead = readOrganismSnapshot(in: snapshotDir)
        let (latest, organism) = await (healthRead, organismRead)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else {
            return (.superseded, "Health refresh was superseded by a sync reconfiguration. Try again.")
        }
        let latestValue = acceptSnapshot(latest, named: "health.json")
        let organismValue = organism.value
        // Absence stays explicit; coordinated-read failure preserves the prior publication.
        if let state = latest.health, !state.failed { health = latestValue }
        if latestValue != nil && organismValue != nil {
            noteRefreshSucceeded()
            return (.refreshed, syncError)
        }
        let outcome: AdvancedSnapshotRefreshOutcome = latestValue != nil || organismValue != nil ? .partial : .unavailable
        syncError = snapshotHealth.damageSentence() ?? (outcome == .partial
            ? "Some Health snapshots are still downloading from iCloud."
            : "Health snapshot is still downloading from iCloud. Try again in a moment.")
        return (outcome, syncError)
    }

    @discardableResult
    func refreshRunsSnapshot() async -> (outcome: AdvancedSnapshotRefreshOutcome, feedbackMessage: String?) {
        guard let snapshotDir else { return (.unavailable, "Runs snapshot is still downloading from iCloud. Try again in a moment.") }
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<[RunRecord]> = await Self.loadSnapshotArrayOnly(named: "runs.json", in: snapshotDir)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else {
            return (.superseded, "Runs refresh was superseded by a sync reconfiguration. Try again.")
        }
        if let latest = acceptSnapshot(read, named: "runs.json") {
            runs = latest
            runsSnapshotLoaded = true
            noteRefreshSucceeded()
            return (.refreshed, snapshotHealth.damageSentence(for: ["runs.json"]))
        }
        syncError = snapshotHealth.damageSentence() ?? "Runs snapshot is still downloading from iCloud. Try again in a moment."
        return (.unavailable, snapshotHealth.damageSentence(for: ["runs.json"]) ?? "Runs snapshot is still downloading from iCloud. Try again in a moment.")
    }

    @discardableResult
    func refreshTrustSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let read = await readTrustSnapshot(in: snapshotDir)
        return read.value != nil
    }

    /// All Trust readers share this admission/publication boundary; committed receipts publish through its write.
    private func readTrustSnapshot(in directory: URL) async -> SnapshotReading<TrustPolicy> {
        let lifecycle = lifecycleGeneration
        return await trustRead.read({ () async -> SnapshotReading<TrustPolicy> in
            await Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: directory)
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            if let policy = acceptSnapshot(read, named: "trust_policy.json") {
                trustPolicy = policy
                noteRefreshSucceeded(files: ["trust_policy.json"])
            } else {
                syncError = snapshotHealth.damageSentence(for: ["trust_policy.json"])
                    ?? "Trust snapshot has not arrived. Keep the Mac app open and check Connection in Settings."
            }
        })
    }

    @discardableResult
    func refreshProviderControlsSnapshot() async -> (outcome: ProviderControlsRefreshOutcome, feedbackMessage: String?) {
        guard let snapshotDir else { return (.unavailable, ProviderControlsRefreshOutcome.unavailable.feedbackMessage(damage: nil)) }
        let lifecycle = lifecycleGeneration
        async let latestProviders: SnapshotReading<[ProviderInfo]> = Self.loadSnapshotArrayOnly(named: "providers.json", in: snapshotDir)
        async let latestTrust = readTrustSnapshot(in: snapshotDir)
        async let latestSurfaceModels: SnapshotReading<MacSnapshotRead<[String: NAProviderSurfaceSelection]>> = Self.loadSnapshotObjectOnly(
            named: "model_preferences.json", in: snapshotDir)
        let (providerRead, trustRead, surfaceModelRead) = await (latestProviders, latestTrust, latestSurfaceModels)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else {
            return (.superseded, ProviderControlsRefreshOutcome.superseded.feedbackMessage(damage: nil))
        }
        let providerRows = acceptSnapshot(providerRead, named: "providers.json")
        let trustRow = trustRead.value
        let surfaceModelRows = acceptSnapshot(surfaceModelRead, named: "model_preferences.json")
        applyProviderState(providers: providerRows, surfaceModels: surfaceModelRows)
        let outcome: ProviderControlsRefreshOutcome = providerRows != nil && trustRow != nil && surfaceModelRows != nil
            ? .refreshed : (providerRows != nil || trustRow != nil || surfaceModelRows != nil ? .partial : .unavailable)
        let feedback = outcome.feedbackMessage(damage: snapshotHealth.damageSentence(for: ProviderControlsRefreshOutcome.filenames))
        if outcome == .refreshed { noteRefreshSucceeded(files: ProviderControlsRefreshOutcome.filenames) }
        else { syncError = feedback }
        return (outcome, feedback)
    }

    func refreshChatSessionListSnapshot() async {
        guard let snapshotDir else { return }
        let lifecycle = lifecycleGeneration
        _ = await sessionListRead.read({
            async let latestSessions: SnapshotReading<[ChatSession]> = Self.loadSnapshotArrayOnly(named: "sessions.json", in: snapshotDir)
            async let latestPinned: SnapshotReading<ChatSessionNavigation> = Self.loadSnapshotObjectOnly(named: "pinned_chat_sessions.json", in: snapshotDir)
            return await (latestSessions, latestPinned)
        }, publish: { sessionRows, pinnedRows in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            let sessionRows = acceptSnapshot(sessionRows, named: "sessions.json")
            let pinnedRows = acceptSnapshot(pinnedRows, named: "pinned_chat_sessions.json")
            if let sessionRows { sessions = sessionRows }
            if let pinnedRows { sessionNavigation = pinnedRows }
            if sessionRows != nil && pinnedRows != nil {
                noteRefreshSucceeded()
            } else if sessionRows != nil || pinnedRows != nil {
                syncError = snapshotHealth.damageSentence() ?? "Some Chat session snapshots are still downloading from iCloud."
            } else {
                syncError = snapshotHealth.damageSentence() ?? "Chat session snapshots are still downloading from iCloud. Try again in a moment."
            }
        })
    }

    @discardableResult
    func refreshChatTranscriptsSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        var refreshed = false
        _ = await transcriptsRead.read({ () async -> SnapshotReading<[String: PublishedTranscript]> in
            let read: SnapshotReading<[ChatTranscriptSnapshot]> = await Self.loadSnapshotArrayOnly(named: "chat_transcripts.json", in: snapshotDir)
            guard let rows = read.value else { return (nil, read.health) }
            return (await Self.transcriptMap(rows), read.health)
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            guard let projected = acceptSnapshot(read, named: "chat_transcripts.json") else { return }
            adoptChatTranscripts(projected)
            noteRefreshSucceeded()
            refreshed = true
        })
        return refreshed
    }

    @discardableResult
    func refreshInboxSnapshot(recovery: DeviceSyncRecovery = .init()) async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        var refreshed = false
        _ = await inboxRead.read({
            async let latestOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(
                named: "work_overview.json", in: snapshotDir)
            let latest: SnapshotReading<MacSnapshotRead<[InboxItemRecord]>> = await Self.loadSnapshotObjectOnly(named: "inbox.json", in: snapshotDir)
            return (latest: latest, overview: await latestOverview)
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            applyWorkOverview(acceptSnapshot(read.overview, named: "work_overview.json"))
            if let latest = acceptSnapshot(read.latest, named: "inbox.json") {
                inboxSnapshotLoaded = true
                inboxItems = orderedSnapshot(latest, file: "inbox.json", current: inboxItems)
                noteRefreshSucceeded()
                recovery.didApplyData?()
                refreshed = true
            } else {
                syncError = snapshotHealth.damageSentence() ?? "Inbox snapshot is still downloading from iCloud. Try again in a moment."
            }
        })
        return refreshed
    }

    private func adoptLightweightSnapshot(_ bundle: LightweightSnapshotBundle, pairing: Data?) {
        if let v = acceptSnapshot(bundle.personality, named: "personality.json") { applyPersonality(v, pairing: pairing) }
        if let v = acceptSnapshot(bundle.voicePreference, named: "voice_preference.json") { voicePreference = v }
        if let v = acceptSnapshot(bundle.health, named: "health.json") { health = v }
        if let v = acceptSnapshot(bundle.connectors, named: "connectors.json") { applyConnectorSnapshot(v) }
        applyProviderState(providers: acceptSnapshot(bundle.providers, named: "providers.json"), surfaceModels: acceptSnapshot(bundle.surfaceModels,
            named: "model_preferences.json"))
        if let v = acceptSnapshot(bundle.providerSignIns, named: "provider_sign_ins.json"), providerSignIns != v { providerSignIns = v }
    }

    private struct LightweightSnapshotBundle: Sendable {
        var trustPolicy: SnapshotReading<TrustPolicy>
        var personality: SnapshotReading<PersonalityProfile>
        var voicePreference: SnapshotReading<MobileVoicePreference>
        var health: SnapshotReading<RuntimeHealth>
        var organismLivingStatus: SnapshotReading<OrganismLivingStatusFile>
        var sessions: SnapshotReading<[ChatSession]>
        var pinnedChatSessions: SnapshotReading<ChatSessionNavigation>
        var connectors: SnapshotReading<[MobileConnectorSnapshot]>
        var providers: SnapshotReading<[ProviderInfo]>
        var providerSignIns: SnapshotReading<[String: [String: String]]>
        var surfaceModels: SnapshotReading<MacSnapshotRead<[String: NAProviderSurfaceSelection]>>
        var approvals: SnapshotReading<MacSnapshotRead<[ApprovalRequest]>>

        var loadedAnySnapshot: Bool {
            trustPolicy.value != nil ||
                personality.value != nil ||
                health.value != nil ||
                organismLivingStatus.value != nil ||
                sessions.value != nil ||
                pinnedChatSessions.value != nil ||
                connectors.value != nil ||
                providers.value != nil ||
                surfaceModels.value != nil ||
                approvals.value != nil
        }

        var loadedAllSnapshots: Bool {
            trustPolicy.value != nil && personality.value != nil && health.value != nil
                && organismLivingStatus.value != nil && sessions.value != nil
                && pinnedChatSessions.value != nil && connectors.value != nil && providers.value != nil
                && surfaceModels.value != nil && approvals.value != nil
        }
    }

    private func loadLightweightSnapshots(snapshotDir: URL) async -> LightweightSnapshotBundle {
        async let trustPolicy = readTrustSnapshot(in: snapshotDir)
        async let personality: SnapshotReading<PersonalityProfile> = Self.loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        async let voicePreference: SnapshotReading<MobileVoicePreference> = Self.loadSnapshotObjectOnly(named: "voice_preference.json", in: snapshotDir)
        async let health: SnapshotReading<RuntimeHealth> = Self.loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        async let organismLivingStatus = readOrganismSnapshot(in: snapshotDir)
        async let sessions: SnapshotReading<[ChatSession]> = Self.loadSnapshotArrayOnly(named: "sessions.json", in: snapshotDir)
        async let pinnedChatSessions: SnapshotReading<ChatSessionNavigation> = Self.loadSnapshotObjectOnly(named: "pinned_chat_sessions.json", in: snapshotDir)
        async let connectors: SnapshotReading<[MobileConnectorSnapshot]> = Self.loadSnapshotArrayOnly(named: "connectors.json", in: snapshotDir)
        async let providers: SnapshotReading<[ProviderInfo]> = Self.loadSnapshotArrayOnly(named: "providers.json", in: snapshotDir)
        async let providerSignIns: SnapshotReading<[String: [String: String]]> = Self.loadSnapshotObjectOnly(named: "provider_sign_ins.json", in: snapshotDir)
        async let surfaceModels: SnapshotReading<MacSnapshotRead<[String: NAProviderSurfaceSelection]>> = Self.loadSnapshotObjectOnly(
            named: "model_preferences.json", in: snapshotDir)
        async let approvals: SnapshotReading<MacSnapshotRead<[ApprovalRequest]>> = Self.loadSnapshotObjectOnly(named: "approvals.json", in: snapshotDir)
        return await LightweightSnapshotBundle(
            trustPolicy: trustPolicy,
            personality: personality,
            voicePreference: voicePreference,
            health: health,
            organismLivingStatus: organismLivingStatus,
            sessions: sessions,
            pinnedChatSessions: pinnedChatSessions,
            connectors: connectors,
            providers: providers,
            providerSignIns: providerSignIns,
            surfaceModels: surfaceModels,
            approvals: approvals
        )
    }

    private func readActivitySnapshots(
        snapshotDir: URL, lifecycle: UInt64, recovery: DeviceSyncRecovery
    ) async -> (loadedAny: Bool, loadedAll: Bool, publishedAll: Bool) {
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return (false, false, false) }
        let inboxAccepted = await refreshInboxSnapshot(recovery: recovery)
        var published = false
        let proposals = await memoryRead.read({ () async -> SnapshotReading<MacSnapshotRead<[MemoryProposalRecord]>> in
            await Self.loadSnapshotObjectOnly(named: "memory_proposals.json", in: snapshotDir)
        }, publish: { rows in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            if let v = acceptSnapshot(rows, named: "memory_proposals.json") {
                memoryProposalsSnapshotLoaded = true
                memoryProposals = orderedSnapshot(v, file: "memory_proposals.json", current: memoryProposals).filter(\.isPending)
            }
            published = true
        })
        let loaded = [inboxAccepted, proposals.value != nil]
        return (loaded.contains(true), loaded.allSatisfy { $0 }, published && inboxAccepted)
    }

}
