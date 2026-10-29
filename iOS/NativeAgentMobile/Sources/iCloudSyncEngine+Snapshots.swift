import Foundation
import NativeAgentShared
import os
import SwiftUI
// Blueprint: | `iCloudSyncEngine+Snapshots.swift` | `iCloudSyncEngine`: `applyHelpersSnapshot` owns both file and action receipt adoption, retaining newer Mac helper revisions; `refreshHelpersSnapshot`, `applySchedulerSnapshot`, `refreshSchedulerSnapshot`, `applyProviderState`; Mac revisions order approvals, inbox and memory snapshots against per-record readbacks/removals until acknowledged; provider snapshots and action receipts use the checked routing revision in the same shared surface-model projection; one typed skill/tool/graph decode owner through full, catalog and graph refreshes; Advanced group delivery refreshes that graph projection for its open list/detail; connector and Telegram receipts share snapshot ordering |

/// Provider refresh distinguishes unavailable snapshots from a usable model list.
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
    /// Retain newer canonical rows (including absent rows) in this one shared
    /// projection until a Mac snapshot's revision acknowledges their readbacks.
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

    func applyTelegramSnapshot(_ snapshot: MobileTelegramSnapshot) {
        if snapshot.observedAt >= (telegram?.observedAt ?? 0) { telegram = snapshot }
    }

    func refreshTelegramSnapshot() async -> Bool {
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<MobileTelegramSnapshot> = await loadSnapshotObjectAsync(named: "telegram.json")
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        guard let snapshot = acceptSnapshot(read, named: "telegram.json") else { return false }
        applyTelegramSnapshot(snapshot)
        return true
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
        let revisions = Dictionary(grouping: snapshot.helpers, by: \.id).mapValues { Set($0.map(\.revision)) }
        let agents = Dictionary(grouping: snapshot.agents, by: \.id)
        helperDetails = helperDetails.filter { id, detail in revisions[id]?.contains(detail.revision) == true }
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

    func applySchedulerSnapshot(_ snapshot: MobileSchedulerSnapshot) {
        guard snapshot.capturedAt >= (schedulerSnapshot?.capturedAt ?? 0) else { return }
        var merged = snapshot
        schedulerJobReceiptTimes = schedulerJobReceiptTimes.filter { $0.value > snapshot.capturedAt }
        if !schedulerJobReceiptTimes.isEmpty {
            merged.mac_time_zone = schedulerSnapshot?.mac_time_zone
        }
        // Preserve newer action readbacks without discarding other jobs in this full snapshot.
        for job in schedulerSnapshot?.jobs ?? [] where schedulerJobReceiptTimes[job.id] != nil {
            if let index = merged.jobs.firstIndex(where: { $0.id == job.id }) {
                merged.jobs[index] = job
            } else {
                merged.jobs.append(job)
            }
        }
        schedulerSnapshot = merged
    }

    @discardableResult
    func refreshSchedulerSnapshot() async -> Bool {
        await refreshSnapshotStaleness()
        guard snapshotDir != nil else {
            schedulerError = "Scheduler is unavailable until this iPhone receives a snapshot from the Mac."
            return false
        }
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<MobileSchedulerSnapshot> = await loadSnapshotObjectAsync(named: "scheduler.json")
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        guard let snapshot = acceptSnapshot(read, named: "scheduler.json") else {
            schedulerError = "Could not refresh Scheduler. Keep the Mac app open and try again."
            return false
        }
        applySchedulerSnapshot(snapshot)
        schedulerError = nil
        return true
    }

    /// Successful refreshes retain diagnostics from accepted, partially decoded data.
    func noteRefreshSucceeded(files: Set<String>? = nil) {
        lastSyncAt = Date()
        syncError = snapshotHealth.damageSentence(for: files)
        PhoneRequests.shared.syncDidSucceed()
    }

    /// Apply the credential-free CloudKit projection published by the Mac.
    /// Decode/validation is all-or-nothing so malformed or future payloads
    /// retain the phone's last proven catalog instead of blanking the picker.
    @discardableResult
    func applyProviderCatalogStatus(_ value: String, isCurrent: @MainActor () -> Bool) async -> Bool {
        let lifecycle = lifecycleGeneration
        let pairing = pairingStore?.iCloudPairingSecret
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
                        eligible: provider.eligible ?? (provider.authState == "ready")
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
                            supports_fast: model.supportsFast
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

    // Snapshots and readbacks carry the routing owner's revision. There is no
    // pending acknowledgment fence to reinstall after an acknowledgment arrived.
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
        let full = fullRefreshQueued
        let recordDelivery = transportDeliveryQueued
        refreshQueued = false
        fullRefreshQueued = false
        transportDeliveryQueued = false
        Task { @MainActor in
            guard lifecycle == self.lifecycleGeneration else { return }
            if full {
                await self.refreshSnapshots(recordTransportDelivery: recordDelivery)
            } else {
                await self.refreshLightweightSnapshots()
            }
        }
    }

    /// Snapshot I/O stays off-main; publication belongs to MainActor.
    /// Only an explicitly completed read proves freshness, never a syncError comparison.
    @discardableResult
    func refreshSnapshots(recordTransportDelivery: Bool = false) async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        if refreshInFlight {
            refreshQueued = true
            fullRefreshQueued = true
            transportDeliveryQueued = transportDeliveryQueued || recordTransportDelivery
            return false
        }
        let personalityPairing = pairingStore?.iCloudPairingSecret
        refreshInFlight = true
        defer { finishSnapshotRefresh(lifecycle: lifecycle) }
        var refreshed = false
        var publishedGroups = 0
        var delivered: Set<NAMobileSnapshotGroup> = []
        var schedulerLoaded = false
        var workActivity: SnapshotReading<MobileWorkActivitySnapshot> = (nil, nil)
        var layout: SnapshotReading<SurfaceLayout> = (nil, nil)
        var projectedTranscripts: [String: PublishedTranscript]?
        // Each snapshot's owner admits its read before loading.
        _ = await snapshotRead.read({ () async -> SnapshotBundle in
            await deskRead.read({ () async -> SnapshotBundle in
                await approvalsRead.read({ () async -> SnapshotBundle in
                    await sessionListRead.read({ () async -> SnapshotBundle in
                        await transcriptsRead.read({ () async -> SnapshotBundle in
                            schedulerLoaded = await refreshSchedulerSnapshot()
                            let bundle = await readAllSnapshots(snapshotDir: snapshotDir, lifecycle: lifecycle)
                            _ = await refreshTelegramSnapshot()
                            workActivity = await Self.loadSnapshotObjectOnly(named: "work_activity.json", in: snapshotDir)
                            layout = await Self.loadSnapshotObjectOnly(named: "ui_layout.json", in: snapshotDir)
                            if let rows = bundle.chatTranscripts.value { projectedTranscripts = await Self.transcriptMap(rows) }
                            await refreshSnapshotStaleness()
                            return bundle
                        }, publish: { bundle in
                            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
                            _ = acceptSnapshot(bundle.chatTranscripts, named: "chat_transcripts.json")
                            if let projectedTranscripts { adoptChatTranscripts(projectedTranscripts) }
                            if bundle.chatTranscripts.value != nil { delivered.insert(.chat) }
                            publishedGroups += 1
                        })
                    }, publish: { bundle in
                        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
                        if let v = acceptSnapshot(bundle.lightweight.sessions, named: "sessions.json"), sessions != v { sessions = v }
                        if let v = acceptSnapshot(bundle.lightweight.pinnedChatSessions, named: "pinned_chat_sessions.json") { sessionNavigation = v }
                        publishedGroups += 1
                    })
                }, publish: { bundle in
                    guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
                    if let v = acceptSnapshot(bundle.lightweight.approvals, named: "approvals.json") {
                        approvalsSnapshotLoaded = true
                        approvals = orderedSnapshot(v, file: "approvals.json", current: approvals)
                    }
                    publishedGroups += 1
                })
            }, publish: { bundle in
                guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
                if let v = acceptSnapshot(bundle.deskItems, named: "desk.json") { deskItems = v }
                applyWorkOverview(acceptSnapshot(bundle.workOverview, named: "work_overview.json"))
                if let v = acceptSnapshot(bundle.deskBounds, named: "desk_bounds.json") { deskBounds = v }
                if let v = acceptSnapshot(bundle.deskReadingCopies, named: "desk_details.json") {
                    deskReadingCopies = Dictionary(v.map { ($0.handle, $0) }, uniquingKeysWith: { _, newer in newer })
                }
                if bundle.deskItems.value != nil, bundle.deskBounds.value != nil, bundle.workOverview.value != nil { delivered.insert(.desk) }
                publishedGroups += 1
            })
        }, publish: { bundle in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            if let workActivity = acceptSnapshot(workActivity, named: "work_activity.json") { PhoneTurnActivity.shared.receive(workActivity) }
            var acceptedLayout = acceptSnapshot(layout, named: "ui_layout.json")
            acceptedLayout?.addMissing()
            surfaceLayout = acceptedLayout
            if let v = acceptSnapshot(bundle.skills, named: "skills_snapshot.json"), skills != v { skills = v }
            if let v = acceptSnapshot(bundle.tools, named: "tools_snapshot.json") { tools = v }
            if let graph = acceptSnapshot(bundle.knowledgeGraph, named: "knowledge_graph.json") { knowledgeGraph = graph }
            adoptLightweightSnapshot(bundle.lightweight, pairing: personalityPairing)
            if let v = acceptSnapshot(bundle.turnSummaries, named: "turn_summaries.json") { turnSummaries = v }
            // Scheduler is an independent, optional projection on older Macs.
            // Its failure stays on the Scheduler page, not on unrelated groups.
            if recordTransportDelivery {
                // This pass never reads all of Core, Catalog or Advanced. Only
                // groups whose required files landed can renew a delivery clock.
                if bundle.activity.loadedAll && bundle.activity.publishedAll { delivered.insert(.activity) }
                if schedulerLoaded { delivered.insert(.scheduler) }
                if workActivity.value != nil { delivered.insert(.work) }
                let stale = Set(staleSnapshotGroups.keys)
                let damaged = Set(snapshotHealth.keys)
                noteTransportDelivery(groups: delivered.filter { group in
                    !group.filenames.contains {
                        damaged.contains($0) || stale.contains(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
                    }
                })
            }
            if bundle.loadedAllSnapshots {
                noteRefreshSucceeded()
                refreshed = publishedGroups == 4 && bundle.activity.publishedAll
            } else if bundle.loadedAnySnapshot {
                // Name damaged bytes; only absent bytes count as downloading.
                syncError = snapshotHealth.damageSentence()
                    ?? "Some iCloud snapshots are still downloading. Showing the last proven value for the rest."
            } else {
                syncError = snapshotHealth.damageSentence()
                    ?? "No iCloud snapshots found yet. Keep the Mac app open until sync completes."
            }
        })
        return refreshed
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
        var layout: SnapshotReading<SurfaceLayout> = (nil, nil)
        _ = await snapshotRead.read({ () async -> LightweightSnapshotBundle in
            await approvalsRead.read({ () async -> LightweightSnapshotBundle in
                await sessionListRead.read({ () async -> LightweightSnapshotBundle in
                    await settleUnobservedActionResponses()
                    async let latestOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(named: "work_overview.json", in: snapshotDir)
                    let bundle = await Self.loadLightweightSnapshots(snapshotDir: snapshotDir)
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
            var acceptedLayout = acceptSnapshot(layout, named: "ui_layout.json")
            acceptedLayout?.addMissing()
            surfaceLayout = acceptedLayout
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

    // The inspector refreshes only its turn-summary snapshot.
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
            async let latestOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(named: "work_overview.json", in: snapshotDir)
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
    func refreshActivitySnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        let read = await readActivitySnapshots(snapshotDir: snapshotDir, lifecycle: lifecycle)
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

    func refreshKnowledgeGraphSnapshot() async {
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<KGEntityResponse> = await loadSnapshotObjectAsync(named: "knowledge_graph.json")
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
        if let snapshot = acceptSnapshot(read, named: "knowledge_graph.json") { knowledgeGraph = snapshot }
    }

    func refreshMemorySnapshot() async {
        guard let snapshotDir else { return }
        let lifecycle = lifecycleGeneration
        _ = await memoryRead.read({
            async let latestMemories: SnapshotReading<MacSnapshotRead<[MemoryRecord]>> = Self.loadSnapshotObjectOnly(named: "memories.json", in: snapshotDir)
            async let latestProposals: SnapshotReading<MacSnapshotRead<[MemoryProposalRecord]>> = Self.loadSnapshotObjectOnly(named: "memory_proposals.json", in: snapshotDir)
            let rows = await (latestMemories, latestProposals)
            await refreshSnapshotStaleness()
            return rows
        }, publish: { memoryRows, proposalRows in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            let memoryRows = acceptSnapshot(memoryRows, named: "memories.json")
            let proposalRows = acceptSnapshot(proposalRows, named: "memory_proposals.json")
            if let memoryRows { memories = orderedSnapshot(memoryRows, file: "memories.json", current: memories) }
            if let proposalRows {
                memoryProposalsSnapshotLoaded = true
                memoryProposals = orderedSnapshot(proposalRows, file: "memory_proposals.json", current: memoryProposals).filter(\.isPending)
            }
            if memoryRows != nil && proposalRows != nil {
                noteRefreshSucceeded()
            } else if memoryRows != nil || proposalRows != nil {
                syncError = snapshotHealth.damageSentence() ?? "Some Memory snapshots are still downloading from iCloud."
            } else {
                syncError = snapshotHealth.damageSentence() ?? "Memory snapshots are still downloading from iCloud. Try again in a moment."
            }
        })
    }

    func refreshWorkshopTasksSnapshot() async {
        guard let snapshotDir else { return }
        let lifecycle = lifecycleGeneration
        _ = await workshopRead.read({ () async -> SnapshotReading<[WorkshopTaskRecord]> in
            await Self.loadSnapshotArrayOnly(named: "workshop_tasks.json", in: snapshotDir)
        }, publish: { latest in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            if let latest = acceptSnapshot(latest, named: "workshop_tasks.json") {
                workshopTasks = latest
                WorkshopCompletionNotificationTracker.shared.apply(latest)
                noteRefreshSucceeded()
            } else {
                syncError = snapshotHealth.damageSentence() ?? "Workshop snapshot is still downloading from iCloud. Try again in a moment."
            }
        })
    }

    @discardableResult
    func refreshDeskSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        var refreshed = false
        _ = await deskRead.read({
            async let latestOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(named: "work_overview.json", in: snapshotDir)
            async let latestBounds: SnapshotReading<MobileDeskProjectionReport> = Self.loadSnapshotObjectOnly(named: "desk_bounds.json", in: snapshotDir)
            async let latestReadingCopies: SnapshotReading<[MobileDeskItemReadingCopy]> = Self.loadSnapshotArrayOnly(named: "desk_details.json", in: snapshotDir)
            async let latest: SnapshotReading<[MobileDeskItem]> = Self.loadSnapshotArrayOnly(named: "desk.json", in: snapshotDir)
            return await (items: latest, bounds: latestBounds, readingCopies: latestReadingCopies, overview: latestOverview)
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            applyWorkOverview(acceptSnapshot(read.overview, named: "work_overview.json"))
            if let latest = acceptSnapshot(read.items, named: "desk.json") {
                deskItems = latest
                if let bounds = acceptSnapshot(read.bounds, named: "desk_bounds.json") { deskBounds = bounds }
                // Absent (an older Mac) is not the same as empty: only a delivered
                // file replaces what the phone already carries.
                if let readingCopies = acceptSnapshot(read.readingCopies, named: "desk_details.json") {
                    deskReadingCopies = Dictionary(
                        readingCopies.map { ($0.handle, $0) },
                        uniquingKeysWith: { _, newer in newer }
                    )
                }
                noteRefreshSucceeded()
                refreshed = true
            } else {
                syncError = snapshotHealth.damageSentence() ?? "Desk is still syncing from the Mac. Try again in a moment."
            }
        })
        return refreshed
    }

    /// A missing or unreadable file is a failed read, not an empty overview:
    /// it never replaces a newer copy another group already delivered.
    func applyWorkOverview(_ overview: WorkOverview?) {
        guard let overview, let incomingDate = DeskActivityState.movementDate(overview.capturedAt) else { return }
        if let currentDate = DeskActivityState.movementDate(workOverview?.capturedAt),
           incomingDate <= currentDate { return }
        workOverview = overview
    }

    @discardableResult
    func refreshSettingsSnapshot() async -> SettingsSnapshotRefreshOutcome {
        guard let snapshotDir else {
            return SettingsSnapshotRefreshOutcome(availableFields: [])
        }
        let lifecycle = lifecycleGeneration
        let personalityPairing = pairingStore?.iCloudPairingSecret
        async let latestTrust: SnapshotReading<TrustPolicy> = Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let latestPersonality: SnapshotReading<PersonalityProfile> = Self.loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        async let latestConnectors: SnapshotReading<[MobileConnectorSnapshot]> = Self.loadSnapshotArrayOnly(named: "connectors.json", in: snapshotDir)
        async let latestHealth: SnapshotReading<RuntimeHealth> = Self.loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        let (trustRead, personalityRead, connectorRead, healthRead) = await (latestTrust, latestPersonality, latestConnectors, latestHealth)
        guard lifecycle == lifecycleGeneration,
              personalityPairing == pairingStore?.iCloudPairingSecret, !Task.isCancelled else {
            return SettingsSnapshotRefreshOutcome(availableFields: [], wasSuperseded: true)
        }
        let trustRow = acceptSnapshot(trustRead, named: "trust_policy.json")
        let personalityRow = acceptSnapshot(personalityRead, named: "personality.json")
        let connectorRows = acceptSnapshot(connectorRead, named: "connectors.json")
        let healthRow = acceptSnapshot(healthRead, named: "health.json")
        var availableFields: Set<SettingsSnapshotRefreshOutcome.Field> = []
        if trustRow != nil { availableFields.insert(.trustPolicy) }
        if personalityRow != nil { availableFields.insert(.personality) }
        if connectorRows != nil { availableFields.insert(.connectors) }
        if healthRow != nil { availableFields.insert(.health) }
        let outcome = SettingsSnapshotRefreshOutcome(availableFields: availableFields, damage: snapshotHealth.damageSentence(for: SettingsSnapshotRefreshOutcome.filenames))
        if let trustRow { trustPolicy = trustRow }
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
        async let organismRead: SnapshotReading<OrganismLivingStatusFile> = Self.loadSnapshotObjectOnly(named: "organism_living_status.json", in: snapshotDir)
        let (latest, organism) = await (healthRead, organismRead)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else {
            return (.superseded, "Health refresh was superseded by a sync reconfiguration. Try again.")
        }
        let latestValue = acceptSnapshot(latest, named: "health.json")
        let organismValue = acceptSnapshot(organism, named: "organism_living_status.json")
        // Absence stays explicit; coordinated-read failure preserves the prior publication.
        if let state = latest.health, !state.failed { health = latestValue }
        if let state = organism.health, !state.failed { organismLivingStatus = organismValue }
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
            noteRefreshSucceeded()
            return (.refreshed, snapshotHealth.damageSentence(for: ["runs.json"]))
        }
        syncError = snapshotHealth.damageSentence() ?? "Runs snapshot is still downloading from iCloud. Try again in a moment."
        return (.unavailable, snapshotHealth.damageSentence(for: ["runs.json"]) ?? "Runs snapshot is still downloading from iCloud. Try again in a moment.")
    }

    @discardableResult
    func refreshTrustSnapshot() async -> Bool {
        guard let snapshotDir else { trustPolicy = nil; return false }
        let lifecycle = lifecycleGeneration
        let read: SnapshotReading<TrustPolicy> = await Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return false }
        trustPolicy = acceptSnapshot(read, named: "trust_policy.json")
        if trustPolicy != nil {
            noteRefreshSucceeded()
            return true
        }
        syncError = snapshotHealth.damageSentence() ?? "Trust snapshot is still downloading from iCloud. Try again in a moment."
        return false
    }

    @discardableResult
    func refreshProviderControlsSnapshot() async -> (outcome: ProviderControlsRefreshOutcome, feedbackMessage: String?) {
        guard let snapshotDir else { return (.unavailable, ProviderControlsRefreshOutcome.unavailable.feedbackMessage(damage: nil)) }
        let lifecycle = lifecycleGeneration
        async let latestProviders: SnapshotReading<[ProviderInfo]> = Self.loadSnapshotArrayOnly(named: "providers.json", in: snapshotDir)
        async let latestTrust: SnapshotReading<TrustPolicy> = Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let latestSurfaceModels: SnapshotReading<MacSnapshotRead<[String: NAProviderSurfaceSelection]>> = Self.loadSnapshotObjectOnly(named: "model_preferences.json", in: snapshotDir)
        let (providerRead, trustRead, surfaceModelRead) = await (latestProviders, latestTrust, latestSurfaceModels)
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else {
            return (.superseded, ProviderControlsRefreshOutcome.superseded.feedbackMessage(damage: nil))
        }
        let providerRows = acceptSnapshot(providerRead, named: "providers.json")
        let trustRow = acceptSnapshot(trustRead, named: "trust_policy.json")
        let surfaceModelRows = acceptSnapshot(surfaceModelRead, named: "model_preferences.json")
        applyProviderState(providers: providerRows, surfaceModels: surfaceModelRows)
        if let trustRow { trustPolicy = trustRow }
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
    func refreshInboxSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        var refreshed = false
        _ = await inboxRead.read({
            async let latestOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(named: "work_overview.json", in: snapshotDir)
            let latest: SnapshotReading<MacSnapshotRead<[InboxItemRecord]>> = await Self.loadSnapshotObjectOnly(named: "inbox.json", in: snapshotDir)
            return (latest: latest, overview: await latestOverview)
        }, publish: { read in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            applyWorkOverview(acceptSnapshot(read.overview, named: "work_overview.json"))
            if let latest = acceptSnapshot(read.latest, named: "inbox.json") {
                inboxSnapshotLoaded = true
                inboxItems = orderedSnapshot(latest, file: "inbox.json", current: inboxItems)
                noteRefreshSucceeded()
                NADeviceSyncRecoveryBudget.didApplyData?()
                refreshed = true
            } else {
                syncError = snapshotHealth.damageSentence() ?? "Inbox snapshot is still downloading from iCloud. Try again in a moment."
            }
        })
        return refreshed
    }

    private struct SnapshotBundle: Sendable {
        var lightweight: LightweightSnapshotBundle
        var activity: (loadedAny: Bool, loadedAll: Bool, publishedAll: Bool)
        var deskItems: SnapshotReading<[MobileDeskItem]>
        var workOverview: SnapshotReading<WorkOverview>
        // Additive: deliberately absent from the completeness checks below, so
        // an older Mac that publishes no report cannot pin a "downloading" banner.
        var deskBounds: SnapshotReading<MobileDeskProjectionReport>
        /// Additive for the same reason as `deskBounds`.
        var deskReadingCopies: SnapshotReading<[MobileDeskItemReadingCopy]>
        var skills: SnapshotReading<[SkillManifestEntry]>
        var tools: SnapshotReading<[MobileToolCatalogRecord]>
        var knowledgeGraph: SnapshotReading<KGEntityResponse>
        var chatTranscripts: SnapshotReading<[ChatTranscriptSnapshot]>
        var turnSummaries: SnapshotReading<TurnSummaryFile>

        var loadedAnySnapshot: Bool {
            lightweight.loadedAnySnapshot || activity.loadedAny ||
                deskItems.value != nil ||
                skills.value != nil ||
                chatTranscripts.value != nil ||
                turnSummaries.value != nil
        }

        var loadedAllSnapshots: Bool {
            lightweight.loadedAllSnapshots && activity.loadedAll
                && deskItems.value != nil && skills.value != nil && chatTranscripts.value != nil && turnSummaries.value != nil
        }
    }

    private func adoptLightweightSnapshot(_ bundle: LightweightSnapshotBundle, pairing: Data?) {
        if let v = acceptSnapshot(bundle.trustPolicy, named: "trust_policy.json") { trustPolicy = v }
        if let v = acceptSnapshot(bundle.personality, named: "personality.json") { applyPersonality(v, pairing: pairing) }
        if let v = acceptSnapshot(bundle.health, named: "health.json") { health = v }
        // Absence is explicit; a failed read preserves the previous posture.
        let organism = acceptSnapshot(bundle.organismLivingStatus, named: "organism_living_status.json")
        if let state = bundle.organismLivingStatus.health, !state.failed { organismLivingStatus = organism }
        if let v = acceptSnapshot(bundle.connectors, named: "connectors.json") { applyConnectorSnapshot(v) }
        applyProviderState(providers: acceptSnapshot(bundle.providers, named: "providers.json"), surfaceModels: acceptSnapshot(bundle.surfaceModels, named: "model_preferences.json"))
        if let v = acceptSnapshot(bundle.providerSignIns, named: "provider_sign_ins.json"), providerSignIns != v { providerSignIns = v }
    }

    private struct LightweightSnapshotBundle: Sendable {
        var trustPolicy: SnapshotReading<TrustPolicy>
        var personality: SnapshotReading<PersonalityProfile>
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

    private func readAllSnapshots(snapshotDir: URL, lifecycle: UInt64) async -> SnapshotBundle {
        async let lightweight = Self.loadLightweightSnapshots(snapshotDir: snapshotDir)
        async let activity = readActivitySnapshots(snapshotDir: snapshotDir, lifecycle: lifecycle)
        async let deskItems: SnapshotReading<[MobileDeskItem]> = Self.loadSnapshotArrayOnly(named: "desk.json", in: snapshotDir)
        async let workOverview: SnapshotReading<WorkOverview> = Self.loadSnapshotObjectOnly(named: "work_overview.json", in: snapshotDir)
        async let deskBounds: SnapshotReading<MobileDeskProjectionReport> = Self.loadSnapshotObjectOnly(named: "desk_bounds.json", in: snapshotDir)
        async let deskReadingCopies: SnapshotReading<[MobileDeskItemReadingCopy]> = Self.loadSnapshotArrayOnly(named: "desk_details.json", in: snapshotDir)
        async let skills: SnapshotReading<[SkillManifestEntry]> = Self.loadSnapshotArrayOnly(named: "skills_snapshot.json", in: snapshotDir)
        async let tools: SnapshotReading<[MobileToolCatalogRecord]> = Self.loadSnapshotArrayOnly(named: "tools_snapshot.json", in: snapshotDir)
        async let knowledgeGraph: SnapshotReading<KGEntityResponse> = Self.loadSnapshotObjectOnly(named: "knowledge_graph.json", in: snapshotDir)
        async let chatTranscripts: SnapshotReading<[ChatTranscriptSnapshot]> = Self.loadSnapshotArrayOnly(named: "chat_transcripts.json", in: snapshotDir)
        async let turnSummaries: SnapshotReading<TurnSummaryFile> = Self.loadSnapshotObjectOnly(named: "turn_summaries.json", in: snapshotDir)
        return await SnapshotBundle(
            lightweight: lightweight,
            activity: activity,
            deskItems: deskItems,
            workOverview: workOverview,
            deskBounds: deskBounds,
            deskReadingCopies: deskReadingCopies,
            skills: skills,
            tools: tools,
            knowledgeGraph: knowledgeGraph,
            chatTranscripts: chatTranscripts,
            turnSummaries: turnSummaries
        )
    }

    private nonisolated static func loadLightweightSnapshots(snapshotDir: URL) async -> LightweightSnapshotBundle {
        async let trustPolicy: SnapshotReading<TrustPolicy> = loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let personality: SnapshotReading<PersonalityProfile> = loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        async let health: SnapshotReading<RuntimeHealth> = loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        async let organismLivingStatus: SnapshotReading<OrganismLivingStatusFile> = loadSnapshotObjectOnly(named: "organism_living_status.json", in: snapshotDir)
        async let sessions: SnapshotReading<[ChatSession]> = loadSnapshotArrayOnly(named: "sessions.json", in: snapshotDir)
        async let pinnedChatSessions: SnapshotReading<ChatSessionNavigation> = loadSnapshotObjectOnly(named: "pinned_chat_sessions.json", in: snapshotDir)
        async let connectors: SnapshotReading<[MobileConnectorSnapshot]> = loadSnapshotArrayOnly(named: "connectors.json", in: snapshotDir)
        async let providers: SnapshotReading<[ProviderInfo]> = loadSnapshotArrayOnly(named: "providers.json", in: snapshotDir)
        async let providerSignIns: SnapshotReading<[String: [String: String]]> = loadSnapshotObjectOnly(named: "provider_sign_ins.json", in: snapshotDir)
        async let surfaceModels: SnapshotReading<MacSnapshotRead<[String: NAProviderSurfaceSelection]>> = loadSnapshotObjectOnly(named: "model_preferences.json", in: snapshotDir)
        async let approvals: SnapshotReading<MacSnapshotRead<[ApprovalRequest]>> = loadSnapshotObjectOnly(named: "approvals.json", in: snapshotDir)
        return await LightweightSnapshotBundle(
            trustPolicy: trustPolicy,
            personality: personality,
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
        snapshotDir: URL, lifecycle: UInt64
    ) async -> (loadedAny: Bool, loadedAll: Bool, publishedAll: Bool) {
        guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return (false, false, false) }
        let inboxAccepted = await refreshInboxSnapshot()
        var publications = 0
        let snapshots = await workshopRead.read({
            await memoryRead.read({
                async let workshopTasks: SnapshotReading<[WorkshopTaskRecord]> = Self.loadSnapshotArrayOnly(named: "workshop_tasks.json", in: snapshotDir)
                async let memories: SnapshotReading<MacSnapshotRead<[MemoryRecord]>> = Self.loadSnapshotObjectOnly(named: "memories.json", in: snapshotDir)
                async let memoryProposals: SnapshotReading<MacSnapshotRead<[MemoryProposalRecord]>> = Self.loadSnapshotObjectOnly(named: "memory_proposals.json", in: snapshotDir)
                return await (workshopTasks: workshopTasks, memories: memories, memoryProposals: memoryProposals)
            }, publish: { rows in
                guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
                if let v = acceptSnapshot(rows.memories, named: "memories.json") { memories = orderedSnapshot(v, file: "memories.json", current: memories) }
                if let v = acceptSnapshot(rows.memoryProposals, named: "memory_proposals.json") {
                    memoryProposalsSnapshotLoaded = true
                    memoryProposals = orderedSnapshot(v, file: "memory_proposals.json", current: memoryProposals).filter(\.isPending)
                }
                publications += 1
            })
        }, publish: { rows in
            guard lifecycle == lifecycleGeneration, !Task.isCancelled else { return }
            if let v = acceptSnapshot(rows.workshopTasks, named: "workshop_tasks.json") { workshopTasks = v; WorkshopCompletionNotificationTracker.shared.apply(v) }
            publications += 1
        })
        let loaded = [snapshots.workshopTasks.value != nil, snapshots.memories.value != nil, inboxAccepted,
                      snapshots.memoryProposals.value != nil]
        return (loaded.contains(true), loaded.allSatisfy { $0 }, publications == 2 && inboxAccepted)
    }

}
