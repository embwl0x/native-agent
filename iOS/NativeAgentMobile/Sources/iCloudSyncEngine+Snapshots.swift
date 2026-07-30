// PATCH-2026-05-07: ios-parity iCloudSyncEngine — snapshot reader + inbox writer for iOS
// Architecture:
//   READ:  iCloud Drive `snapshots/*.json` — Mac's SnapshotWriter keeps these fresh.
//          KVS key `snapshot_updated` pings iOS when a snapshot changes.
//   WRITE: iOS drops an action envelope into `inbox/<msg_id>.json`.
//          MacSyncEngine validates it, dispatches into the in-process Swift runtime,
//          writes `responses/<msg_id>.json`, then pings `inbox_response_<msg_id>`.

import CryptoKit
import Foundation
import SwiftUI
import NativeAgentShared

extension iCloudSyncEngine {
    /// Apply the credential-free CloudKit projection published by the Mac.
    /// Decode/validation is all-or-nothing so malformed or future payloads
    /// retain the phone's last proven catalog instead of blanking the picker.
    @discardableResult
    func applyProviderCatalogStatus(_ value: String) -> Bool {
        do {
            let catalog = try NAProviderCatalogStatusCodec.decode(value)
            providers = catalog.providers.map { provider in
                ProviderInfo(
                    provider_id: provider.providerID,
                    display_name: provider.displayName,
                    auth_modes: provider.authModes,
                    auth_status: ProviderAuthStatus(
                        provider_id: provider.providerID,
                        state: provider.authState,
                        detail: "",
                        user_info: nil,
                        last_checked_at: nil
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
            applyRemoteSurfaceModels(
                catalog.surfaces.mapValues { selection in
                    SurfaceModelPref(
                        model: selection.model,
                        reasoningEffort: selection.reasoningEffort,
                        serviceTier: selection.serviceTier,
                        providerId: selection.providerID
                    )
                }
            )
            lastSyncAt = Date()
            syncError = nil
            return true
        } catch {
            syncError = "Provider catalog sync failed: \(error.localizedDescription)"
            return false
        }
    }

    // PATCH-2026-06-06: cross-device-picker-cue — surfaceModels comes from the
    // Mac's surfaces.json via iCloud snapshot. iOS has no local writer for
    // these (the Mac picker is the only source of truth today), so every
    // change here is by definition REMOTE. Diff against the previous in-memory
    // value and toast on per-surface changes so the user notices when the Mac
    // flips a model. We deliberately do NOT toast on the FIRST load (previous
    // empty) — that's the cold-start hydration, not a remote change event.
    private func applyRemoteSurfaceModels(_ next: [String: SurfaceModelPref]) {
        let previous = surfaceModels
        if !previous.isEmpty {
            for (surface, newPref) in next {
                guard let prev = previous[surface] else { continue }
                if prev.model != newPref.model {
                    iOSSystemToastCenter.shared.push(
                        info: "Mac changed \(surface) model to \(newPref.model)"
                    )
                }
            }
        }
        surfaceModels = next
    }

    // MARK: - Snapshot refresh

    /// 2026-05-09: was synchronously reading 11 JSON files on @MainActor — when
    /// any of them needed an iCloud Drive download, the read blocked the UI
    /// for the duration of the network fetch and the Memory tab visibly froze.
    /// Now: hop to a detached task, do all reads off-main, return a `Bundle`,
    /// assign published properties back on MainActor.
    func refreshSnapshots() async {
        guard let snapshotDir else { return }
        if refreshInFlight {
            refreshQueued = true
            return
        }
        snapshotRefreshGeneration &+= 1
        // 2026-07-21 audit fix: a full/lightweight refresh WRITES inboxItems,
        // so it must also invalidate any in-flight targeted refresh —
        // otherwise a targeted read that STARTED before still passes its
        // targetedRefreshGeneration guard afterward and clobbers the fresher
        // full-refresh data with its older read.
        targetedRefreshGeneration &+= 1
        // refreshSnapshots() also writes chatTranscripts — invalidate the
        // transcripts lane's in-flight reads too.
        chatTranscriptsRefreshGeneration &+= 1
        let generation = snapshotRefreshGeneration
        refreshInFlight = true
        defer {
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                Task { @MainActor in
                    await self.refreshSnapshots()
                }
            }
        }
        let bundle = await Self.loadAllSnapshots(snapshotDir: snapshotDir)
        // Resumption of an @MainActor async func is back on the main actor.
        guard generation == snapshotRefreshGeneration else { return }
        if let v = bundle.workshopTasks { workshopTasks = v }
        if let v = bundle.skills { skills = v }
        if let v = bundle.memories { memories = v }
        if let v = bundle.memoryProposals { memoryProposals = v.filter(\.isPending) }
        if let v = bundle.trainingProposals { trainingProposals = v }
        if let v = bundle.promotionCandidates { promotionCandidates = v }
        if let v = bundle.trustPolicy { trustPolicy = v }
        if let v = bundle.personality { personality = v }
        if let v = bundle.health { health = v }
        if let v = bundle.organismLivingStatus { organismLivingStatus = v }
        if let v = bundle.sessions { sessions = v }
        if let v = bundle.pinnedChatSessions { pinnedChatSessions = v }
        if let v = bundle.chatTranscripts { chatTranscripts = Self.transcriptMap(v) }
        if let v = bundle.connectors { connectors = v }
        if let v = bundle.providers { providers = v }
        // gpt-5.5 review finding #2: don't gate on !isEmpty. A valid `{}`
        // snapshot (Mac wiped all surface picks) should still propagate so
        // the in-memory map matches the source of truth.
        if let v = bundle.surfaceModels { applyRemoteSurfaceModels(v) }
        if let v = bundle.approvals { approvals = v }
        if let v = bundle.inboxItems {
            inboxSnapshotLoaded = true
            inboxItems = v
        }
        if let v = bundle.turnSummaries { turnSummaries = v }
        if bundle.loadedAllSnapshots {
            lastSyncAt = Date()
            syncError = nil
        } else if bundle.loadedAnySnapshot {
            syncError = "Some iCloud snapshots are still downloading. Showing the last proven value for the rest."
        } else {
            syncError = "No iCloud snapshots found yet. Keep the Mac app open until sync completes."
        }
    }

    func refreshLightweightSnapshots() async {
        guard let snapshotDir else { return }
        if refreshInFlight {
            refreshQueued = true
            return
        }
        snapshotRefreshGeneration &+= 1
        // 2026-07-21 audit fix: see refreshSnapshots() — full-refresh writes
        // must invalidate in-flight targeted refreshes.
        targetedRefreshGeneration &+= 1
        let generation = snapshotRefreshGeneration
        refreshInFlight = true
        defer {
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                Task { @MainActor in
                    await self.refreshLightweightSnapshots()
                }
            }
        }
        let bundle = await Self.loadLightweightSnapshots(snapshotDir: snapshotDir)
        guard generation == snapshotRefreshGeneration else { return }
        if let v = bundle.trustPolicy { trustPolicy = v }
        if let v = bundle.personality { personality = v }
        if let v = bundle.health { health = v }
        if let v = bundle.organismLivingStatus { organismLivingStatus = v }
        if let v = bundle.sessions { sessions = v }
        if let v = bundle.pinnedChatSessions { pinnedChatSessions = v }
        if let v = bundle.connectors { connectors = v }
        if let v = bundle.providers { providers = v }
        if let v = bundle.surfaceModels { applyRemoteSurfaceModels(v) }
        if let v = bundle.approvals { approvals = v }
        if let v = bundle.inboxItems {
            inboxSnapshotLoaded = true
            inboxItems = v
        }
        if bundle.loadedAllSnapshots {
            lastSyncAt = Date()
            syncError = nil
        } else if bundle.loadedAnySnapshot {
            syncError = "Some lightweight iCloud snapshots are still downloading."
        } else {
            syncError = "No iCloud snapshots found yet. Keep the Mac app open until sync completes."
        }
    }

    // Turn Inspector W4: targeted refresh so the inspector view doesn't reload
    // ALL snapshots on appear/pull (mirrors refreshApprovalsSnapshot).
    func refreshTurnSummariesSnapshot() async {
        guard let snapshotDir else { return }
        if let latest: TurnSummaryFile = await Self.loadSnapshotObjectOnly(named: "turn_summaries.json", in: snapshotDir) {
            turnSummaries = latest
            lastSyncAt = Date()
            syncError = nil
        }
    }

    func refreshApprovalsSnapshot() async {
        guard let snapshotDir else { return }
        if let latest: [ApprovalRequest] = await Self.loadSnapshotArrayOnly(named: "approvals.json", in: snapshotDir) {
            approvals = latest
            lastSyncAt = Date()
            syncError = nil
        }
    }

    func refreshActivitySnapshot() async {
        guard let snapshotDir else { return }
        // 2026-07-04 (review): generation guard — foreground/push/poll refreshes
        // overlap; without this a SLOWER older read could assign its results
        // after a newer read already landed, briefly reviving stale data.
        targetedRefreshGeneration &+= 1
        let generation = targetedRefreshGeneration
        let bundle = await Self.loadActivitySnapshots(snapshotDir: snapshotDir)
        guard generation == targetedRefreshGeneration else { return }
        if let v = bundle.approvals { approvals = v }
        if let v = bundle.inboxItems {
            inboxSnapshotLoaded = true
            inboxItems = v
        }
        if let v = bundle.memoryProposals { memoryProposals = v.filter(\.isPending) }
        if let v = bundle.trainingProposals { trainingProposals = v }
        if let v = bundle.promotionCandidates { promotionCandidates = v }
        if let v = bundle.personality { personality = v }
        if bundle.loadedAllSnapshots {
            lastSyncAt = Date()
            syncError = nil
        } else if bundle.loadedAnySnapshot {
            syncError = "Some Activity snapshots are still downloading."
        }
    }

    func refreshMemorySnapshot() async {
        guard let snapshotDir else { return }
        async let latestMemories: [MemoryRecord]? = Self.loadSnapshotArrayOnly(named: "memories.json", in: snapshotDir)
        async let latestProposals: [MemoryProposalRecord]? = Self.loadSnapshotArrayOnly(named: "memory_proposals.json", in: snapshotDir)
        let (memoryRows, proposalRows) = await (latestMemories, latestProposals)
        if let memoryRows { memories = memoryRows }
        if let proposalRows { memoryProposals = proposalRows.filter(\.isPending) }
        if memoryRows != nil && proposalRows != nil {
            lastSyncAt = Date()
            syncError = nil
        } else if memoryRows != nil || proposalRows != nil {
            syncError = "Some Memory snapshots are still downloading from iCloud."
        } else {
            syncError = "Memory snapshots are still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshWorkshopTasksSnapshot() async {
        guard let snapshotDir else { return }
        if let latest: [WorkshopTaskRecord] = await Self.loadSnapshotArrayOnly(named: "workshop_tasks.json", in: snapshotDir) {
            workshopTasks = latest
            lastSyncAt = Date()
            syncError = nil
        } else {
            syncError = "Workshop snapshot is still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshCommandCenterSnapshot() async {
        guard let snapshotDir else { return }
        async let latestHealth: RuntimeHealth? = Self.loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        async let latestTrust: TrustPolicy? = Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let latestApprovals: [ApprovalRequest]? = Self.loadSnapshotArrayOnly(named: "approvals.json", in: snapshotDir)
        let (healthRow, trustRow, approvalRows) = await (latestHealth, latestTrust, latestApprovals)
        if let healthRow { health = healthRow }
        if let trustRow { trustPolicy = trustRow }
        if let approvalRows { approvals = approvalRows }
        if healthRow != nil && trustRow != nil && approvalRows != nil {
            lastSyncAt = Date()
            syncError = nil
        } else if healthRow != nil || trustRow != nil || approvalRows != nil {
            syncError = "Some Command Center snapshots are still downloading from iCloud."
        } else {
            syncError = "Command Center snapshots are still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshSettingsSnapshot() async {
        guard let snapshotDir else { return }
        async let latestTrust: TrustPolicy? = Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let latestPersonality: PersonalityProfile? = Self.loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        async let latestConnectors: [ConnectorRecord]? = Self.loadSnapshotArrayOnly(named: "connectors.json", in: snapshotDir)
        async let latestHealth: RuntimeHealth? = Self.loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        let (trustRow, personalityRow, connectorRows, healthRow) = await (latestTrust, latestPersonality, latestConnectors, latestHealth)
        if let trustRow { trustPolicy = trustRow }
        if let personalityRow { personality = personalityRow }
        if let connectorRows { connectors = connectorRows }
        if let healthRow { health = healthRow }
        if trustRow != nil && personalityRow != nil && connectorRows != nil && healthRow != nil {
            lastSyncAt = Date()
            syncError = nil
        } else if trustRow != nil || personalityRow != nil || connectorRows != nil || healthRow != nil {
            syncError = "Some Settings snapshots are still downloading from iCloud."
        } else {
            syncError = "Settings snapshots are still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshHealthSnapshot() async {
        guard let snapshotDir else { return }
        async let latestHealth: RuntimeHealth? = Self.loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        async let latestOrganism: OrganismLivingStatusFile? = Self.loadSnapshotObjectOnly(named: "organism_living_status.json", in: snapshotDir)
        let (latest, organism) = await (latestHealth, latestOrganism)
        if let latest {
            health = latest
        }
        if let organism {
            organismLivingStatus = organism
        }
        if latest != nil && organism != nil {
            lastSyncAt = Date()
            syncError = nil
        } else if latest != nil || organism != nil {
            syncError = "Some Health snapshots are still downloading from iCloud."
        } else {
            syncError = "Health snapshot is still downloading from iCloud. Try again in a moment."
        }
    }

    // R25: targeted runs loader mirroring refreshHealthSnapshot — AdvancedView
    // is the only consumer, so it loads on demand rather than riding the full
    // snapshot bundle.
    func refreshRunsSnapshot() async {
        guard let snapshotDir else { return }
        if let latest: [RunRecord] = await Self.loadSnapshotArrayOnly(named: "runs.json", in: snapshotDir) {
            runs = latest
            lastSyncAt = Date()
            syncError = nil
        } else if runs.isEmpty {
            syncError = "Runs snapshot is still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshTrustSnapshot() async {
        guard let snapshotDir else { return }
        if let latest: TrustPolicy = await Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir) {
            trustPolicy = latest
            lastSyncAt = Date()
            syncError = nil
        } else {
            syncError = "Trust snapshot is still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshProviderControlsSnapshot() async {
        guard let snapshotDir else { return }
        async let latestProviders: [ProviderInfo]? = Self.loadSnapshotArrayOnly(named: "providers.json", in: snapshotDir)
        async let latestTrust: TrustPolicy? = Self.loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let latestSurfaceModels: [String: SurfaceModelPref]? = Self.loadSnapshotObjectOnly(named: "model_preferences.json", in: snapshotDir)
        let (providerRows, trustRow, surfaceModelRows) = await (latestProviders, latestTrust, latestSurfaceModels)
        if let providerRows { providers = providerRows }
        if let trustRow { trustPolicy = trustRow }
        // gpt-5.5 review finding #2: see the bulk-apply site above for why
        // we don't gate on !isEmpty.
        if let surfaceModelRows { applyRemoteSurfaceModels(surfaceModelRows) }
        if providerRows != nil && trustRow != nil && surfaceModelRows != nil {
            lastSyncAt = Date()
            syncError = nil
        } else if providerRows != nil || trustRow != nil || surfaceModelRows != nil {
            syncError = "Some Provider snapshots are still downloading from iCloud."
        } else {
            syncError = "Provider snapshots are still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshChatSessionsSnapshot() async {
        await refreshChatSessionListSnapshot()
    }

    func refreshChatSessionListSnapshot() async {
        guard let snapshotDir else { return }
        async let latestSessions: [ChatSession]? = Self.loadSnapshotArrayOnly(named: "sessions.json", in: snapshotDir)
        async let latestPinned: [ChatSession]? = Self.loadSnapshotArrayOnly(named: "pinned_chat_sessions.json", in: snapshotDir)
        let (sessionRows, pinnedRows) = await (latestSessions, latestPinned)
        if let sessionRows { sessions = sessionRows }
        if let pinnedRows { pinnedChatSessions = pinnedRows }
        if sessionRows != nil && pinnedRows != nil {
            lastSyncAt = Date()
            syncError = nil
        } else if sessionRows != nil || pinnedRows != nil {
            syncError = "Some Chat session snapshots are still downloading from iCloud."
        } else {
            syncError = "Chat session snapshots are still downloading from iCloud. Try again in a moment."
        }
    }

    func refreshChatTranscriptsSnapshot() async {
        guard let snapshotDir else { return }
        // 2026-07-21 audit fix: generation guard — this lane is reachable
        // concurrently (5s ChatView loop, forceRefresh, scenePhase) and each
        // read can block ~2.5s in awaitCurrentVersion; without the guard two
        // overlapping reads can complete out of order and the older content
        // lands last, reverting visible transcripts (the merge then drops
        // Mac-originated messages missing from the older read).
        chatTranscriptsRefreshGeneration &+= 1
        let generation = chatTranscriptsRefreshGeneration
        if let latestTranscripts: [ChatTranscriptSnapshot] = await Self.loadSnapshotArrayOnly(named: "chat_transcripts.json", in: snapshotDir) {
            guard generation == chatTranscriptsRefreshGeneration else { return }
            chatTranscripts = Self.transcriptMap(latestTranscripts)
            lastSyncAt = Date()
            syncError = nil
        }
    }

    func transcriptRecords(for sessionID: String?) -> [ChatMessageRecord]? {
        guard let sessionID,
              let records = chatTranscripts[sessionID],
              !records.isEmpty else { return nil }
        return records
    }

    @discardableResult
    func refreshInboxSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        // 2026-07-04 (review): generation guard — same stale-clobber protection
        // as refreshActivitySnapshot (shared counter: inbox and activity both
        // write inboxItems, so they must invalidate each other's stale reads).
        targetedRefreshGeneration &+= 1
        let generation = targetedRefreshGeneration
        if let latest: [InboxItemRecord] = await Self.loadSnapshotArrayOnly(named: "inbox.json", in: snapshotDir) {
            guard generation == targetedRefreshGeneration else { return true }
            inboxSnapshotLoaded = true
            inboxItems = latest
            lastSyncAt = Date()
            syncError = nil
            return true
        } else {
            guard generation == targetedRefreshGeneration else { return false }
            syncError = "Inbox snapshot is still downloading from iCloud. Try again in a moment."
            return false
        }
    }

    private struct SnapshotBundle: Sendable {
        var workshopTasks: [WorkshopTaskRecord]?
        var skills: [SkillRecord]?
        var memories: [MemoryRecord]?
        var memoryProposals: [MemoryProposalRecord]?
        var trainingProposals: [TrainingProposalSummary]?
        var promotionCandidates: [PromotionCandidateSummary]?
        var trustPolicy: TrustPolicy?
        var personality: PersonalityProfile?
        var health: RuntimeHealth?
        var organismLivingStatus: OrganismLivingStatusFile?
        var sessions: [ChatSession]?
        var pinnedChatSessions: [ChatSession]?
        var chatTranscripts: [ChatTranscriptSnapshot]?
        var connectors: [ConnectorRecord]?
        var providers: [ProviderInfo]?
        var surfaceModels: [String: SurfaceModelPref]?
        var approvals: [ApprovalRequest]?
        var inboxItems: [InboxItemRecord]?
        var turnSummaries: TurnSummaryFile?

        var loadedAnySnapshot: Bool {
            workshopTasks != nil ||
                skills != nil ||
                memories != nil ||
                memoryProposals != nil ||
                trainingProposals != nil ||
                promotionCandidates != nil ||
                trustPolicy != nil ||
                personality != nil ||
                health != nil ||
                organismLivingStatus != nil ||
                sessions != nil ||
                pinnedChatSessions != nil ||
                chatTranscripts != nil ||
                connectors != nil ||
                providers != nil ||
                surfaceModels != nil ||
                approvals != nil ||
                inboxItems != nil ||
                turnSummaries != nil
        }

        var loadedAllSnapshots: Bool {
            workshopTasks != nil && skills != nil && memories != nil && memoryProposals != nil
                && trainingProposals != nil && promotionCandidates != nil && trustPolicy != nil
                && personality != nil && health != nil && organismLivingStatus != nil
                && sessions != nil && pinnedChatSessions != nil && chatTranscripts != nil
                && connectors != nil && providers != nil && surfaceModels != nil
                && approvals != nil && inboxItems != nil && turnSummaries != nil
        }
    }

    private struct ActivitySnapshotBundle: Sendable {
        var approvals: [ApprovalRequest]?
        var inboxItems: [InboxItemRecord]?
        var memoryProposals: [MemoryProposalRecord]?
        var trainingProposals: [TrainingProposalSummary]?
        var promotionCandidates: [PromotionCandidateSummary]?
        var personality: PersonalityProfile?

        var loadedAnySnapshot: Bool {
            approvals != nil ||
                inboxItems != nil ||
                memoryProposals != nil ||
                trainingProposals != nil ||
                promotionCandidates != nil ||
                personality != nil
        }

        var loadedAllSnapshots: Bool {
            approvals != nil && inboxItems != nil && memoryProposals != nil
                && trainingProposals != nil && promotionCandidates != nil && personality != nil
        }
    }

    private struct LightweightSnapshotBundle: Sendable {
        var trustPolicy: TrustPolicy?
        var personality: PersonalityProfile?
        var health: RuntimeHealth?
        var organismLivingStatus: OrganismLivingStatusFile?
        var sessions: [ChatSession]?
        var pinnedChatSessions: [ChatSession]?
        var connectors: [ConnectorRecord]?
        var providers: [ProviderInfo]?
        var surfaceModels: [String: SurfaceModelPref]?
        var approvals: [ApprovalRequest]?
        var inboxItems: [InboxItemRecord]?

        var loadedAnySnapshot: Bool {
            trustPolicy != nil ||
                personality != nil ||
                health != nil ||
                organismLivingStatus != nil ||
                sessions != nil ||
                pinnedChatSessions != nil ||
                connectors != nil ||
                providers != nil ||
                surfaceModels != nil ||
                approvals != nil ||
                inboxItems != nil
        }

        var loadedAllSnapshots: Bool {
            trustPolicy != nil && personality != nil && health != nil
                && organismLivingStatus != nil && sessions != nil
                && pinnedChatSessions != nil && connectors != nil && providers != nil
                && surfaceModels != nil && approvals != nil && inboxItems != nil
        }
    }

    private nonisolated static func loadAllSnapshots(snapshotDir: URL) async -> SnapshotBundle {
        async let workshopTasks: [WorkshopTaskRecord]? = loadSnapshotArrayOnly(named: "workshop_tasks.json", in: snapshotDir)
        async let skills: [SkillRecord]? = loadSnapshotArrayOnly(named: "skills_snapshot.json", in: snapshotDir)
        async let memories: [MemoryRecord]? = loadSnapshotArrayOnly(named: "memories.json", in: snapshotDir)
        async let memoryProposals: [MemoryProposalRecord]? = loadSnapshotArrayOnly(named: "memory_proposals.json", in: snapshotDir)
        async let trainingProposals: [TrainingProposalSummary]? = loadSnapshotArrayOnly(named: "training_proposals.json", in: snapshotDir)
        async let promotionCandidates: [PromotionCandidateSummary]? = loadSnapshotArrayOnly(named: "promotion_candidates.json", in: snapshotDir)
        async let trustPolicy: TrustPolicy? = loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let personality: PersonalityProfile? = loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        async let health: RuntimeHealth? = loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        async let organismLivingStatus: OrganismLivingStatusFile? = loadSnapshotObjectOnly(named: "organism_living_status.json", in: snapshotDir)
        async let sessions: [ChatSession]? = loadSnapshotArrayOnly(named: "sessions.json", in: snapshotDir)
        async let pinnedChatSessions: [ChatSession]? = loadSnapshotArrayOnly(named: "pinned_chat_sessions.json", in: snapshotDir)
        async let chatTranscripts: [ChatTranscriptSnapshot]? = loadSnapshotArrayOnly(named: "chat_transcripts.json", in: snapshotDir)
        async let connectors: [ConnectorRecord]? = loadSnapshotArrayOnly(named: "connectors.json", in: snapshotDir)
        async let providers: [ProviderInfo]? = loadSnapshotArrayOnly(named: "providers.json", in: snapshotDir)
        async let surfaceModels: [String: SurfaceModelPref]? = loadSnapshotObjectOnly(named: "model_preferences.json", in: snapshotDir)
        async let approvals: [ApprovalRequest]? = loadSnapshotArrayOnly(named: "approvals.json", in: snapshotDir)
        async let inboxItems: [InboxItemRecord]? = loadSnapshotArrayOnly(named: "inbox.json", in: snapshotDir)
        async let turnSummaries: TurnSummaryFile? = loadSnapshotObjectOnly(named: "turn_summaries.json", in: snapshotDir)
        return await SnapshotBundle(
            workshopTasks: workshopTasks,
            skills: skills,
            memories: memories,
            memoryProposals: memoryProposals,
            trainingProposals: trainingProposals,
            promotionCandidates: promotionCandidates,
            trustPolicy: trustPolicy,
            personality: personality,
            health: health,
            organismLivingStatus: organismLivingStatus,
            sessions: sessions,
            pinnedChatSessions: pinnedChatSessions,
            chatTranscripts: chatTranscripts,
            connectors: connectors,
            providers: providers,
            surfaceModels: surfaceModels,
            approvals: approvals,
            inboxItems: inboxItems,
            turnSummaries: turnSummaries
        )
    }

    private nonisolated static func loadLightweightSnapshots(snapshotDir: URL) async -> LightweightSnapshotBundle {
        async let trustPolicy: TrustPolicy? = loadSnapshotObjectOnly(named: "trust_policy.json", in: snapshotDir)
        async let personality: PersonalityProfile? = loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        async let health: RuntimeHealth? = loadSnapshotObjectOnly(named: "health.json", in: snapshotDir)
        async let organismLivingStatus: OrganismLivingStatusFile? = loadSnapshotObjectOnly(named: "organism_living_status.json", in: snapshotDir)
        async let sessions: [ChatSession]? = loadSnapshotArrayOnly(named: "sessions.json", in: snapshotDir)
        async let pinnedChatSessions: [ChatSession]? = loadSnapshotArrayOnly(named: "pinned_chat_sessions.json", in: snapshotDir)
        async let connectors: [ConnectorRecord]? = loadSnapshotArrayOnly(named: "connectors.json", in: snapshotDir)
        async let providers: [ProviderInfo]? = loadSnapshotArrayOnly(named: "providers.json", in: snapshotDir)
        async let surfaceModels: [String: SurfaceModelPref]? = loadSnapshotObjectOnly(named: "model_preferences.json", in: snapshotDir)
        async let approvals: [ApprovalRequest]? = loadSnapshotArrayOnly(named: "approvals.json", in: snapshotDir)
        async let inboxItems: [InboxItemRecord]? = loadSnapshotArrayOnly(named: "inbox.json", in: snapshotDir)
        return await LightweightSnapshotBundle(
            trustPolicy: trustPolicy,
            personality: personality,
            health: health,
            organismLivingStatus: organismLivingStatus,
            sessions: sessions,
            pinnedChatSessions: pinnedChatSessions,
            connectors: connectors,
            providers: providers,
            surfaceModels: surfaceModels,
            approvals: approvals,
            inboxItems: inboxItems
        )
    }

    private nonisolated static func transcriptMap(_ rows: [ChatTranscriptSnapshot]) -> [String: [ChatMessageRecord]] {
        var out: [String: [ChatMessageRecord]] = [:]
        for row in rows {
            let clean = row.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            out[clean] = row.messages
        }
        return out
    }

    private nonisolated static func loadActivitySnapshots(snapshotDir: URL) async -> ActivitySnapshotBundle {
        async let approvals: [ApprovalRequest]? = loadSnapshotArrayOnly(named: "approvals.json", in: snapshotDir)
        async let inboxItems: [InboxItemRecord]? = loadSnapshotArrayOnly(named: "inbox.json", in: snapshotDir)
        async let memoryProposals: [MemoryProposalRecord]? = loadSnapshotArrayOnly(named: "memory_proposals.json", in: snapshotDir)
        async let trainingProposals: [TrainingProposalSummary]? = loadSnapshotArrayOnly(named: "training_proposals.json", in: snapshotDir)
        async let promotionCandidates: [PromotionCandidateSummary]? = loadSnapshotArrayOnly(named: "promotion_candidates.json", in: snapshotDir)
        async let personality: PersonalityProfile? = loadSnapshotObjectOnly(named: "personality.json", in: snapshotDir)
        return await ActivitySnapshotBundle(
            approvals: approvals,
            inboxItems: inboxItems,
            memoryProposals: memoryProposals,
            trainingProposals: trainingProposals,
            promotionCandidates: promotionCandidates,
            personality: personality
        )
    }

    private nonisolated static func loadSnapshotArrayOnly<T: Decodable & Sendable>(named filename: String, in dir: URL) async -> [T]? {
        await Task.detached(priority: .userInitiated) { () -> [T]? in
            let loaded: [T]? = Self.loadSnapshotArrayStatic(named: filename, in: dir)
            return loaded
        }.value
    }

    private nonisolated static func loadSnapshotObjectOnly<T: Decodable & Sendable>(named filename: String, in dir: URL) async -> T? {
        await Task.detached(priority: .userInitiated) { () -> T? in
            let loaded: T? = Self.loadSnapshotObjectStatic(named: filename, in: dir)
            return loaded
        }.value
    }

    /// Static off-main loaders — body identical to the instance methods below
    /// but callable from a detached Task without crossing the MainActor.
    private nonisolated static func loadSnapshotArrayStatic<T: Decodable>(named filename: String, in dir: URL) -> [T]? {
        guard let data = loadSnapshotData(named: filename, in: dir) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let arr = try? decoder.decode([T].self, from: data) { return arr }
        // Per-entry fallback (one bad record shouldn't wipe the snapshot).
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var out: [T] = []
        for item in raw {
            if let itemData = try? JSONSerialization.data(withJSONObject: item),
               let one = try? decoder.decode(T.self, from: itemData) {
                out.append(one)
            }
        }
        return out.isEmpty ? nil : out
    }

    private nonisolated static func loadSnapshotObjectStatic<T: Decodable>(named filename: String, in dir: URL) -> T? {
        guard let data = loadSnapshotData(named: filename, in: dir) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private nonisolated static func loadSnapshotData(named filename: String, in dir: URL) -> Data? {
        let url = dir.appendingPathComponent(filename)
        // 2026-07-04 stale-snapshot fix: these are iCloud Drive files. A plain
        // Data(contentsOf:) reads whatever replica is on disk — iCloud does NOT
        // pull a newer version written by the Mac until something asks for it,
        // which is why new inbox cards only appeared after an app relaunch
        // (launch-time metadata gathering happened to trigger the download).
        // Ask for the current version and give the download a short window.
        // If it does not land, retain the already-published last good value;
        // decoding a stale replica and stamping `lastSyncAt = now` fabricates
        // freshness and can revive old approvals, models, or inbox state.
        guard awaitCurrentVersion(of: url) else { return nil }
        let maxBytes = snapshotReadLimitBytes(named: filename)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? NSNumber,
           fileSize.uint64Value > UInt64(maxBytes) {
            NSLog("[iCloudSync] skipping oversized snapshot %@ bytes=%llu limit=%d", filename, fileSize.uint64Value, maxBytes)
            return nil
        }
        guard let data = coordinatedRead(url) else { return nil }
        if data.count > maxBytes {
            NSLog("[iCloudSync] skipping oversized snapshot %@ bytes=%d limit=%d", filename, data.count, maxBytes)
            return nil
        }
        return data
    }

    /// Kick an iCloud download for `url` if a newer version exists remotely and
    /// wait (bounded) for it to become current. Runs off-main (all callers are
    /// inside Task.detached), so the short blocking poll cannot freeze the UI.
    private nonisolated static func awaitCurrentVersion(
        of url: URL,
        timeout: TimeInterval = 2.5
    ) -> Bool {
        let fm = FileManager.default
        let isUbiquitous = fm.isUbiquitousItem(at: url)
        guard isUbiquitous else { return true }
        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let values = try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ), let status = values.ubiquitousItemDownloadingStatus else { return false }
            if acceptsSnapshotReplica(
                isUbiquitous: isUbiquitous,
                hasCurrentVersion: status == .current
            ) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        NSLog("[iCloudSync] snapshot %@ still not current after %.1fs — retaining last proven value", url.lastPathComponent, timeout)
        return false
    }

    /// Ubiquitous replicas are evidence only when iCloud reports the current
    /// version. Local test/export roots are already authoritative at their URL.
    nonisolated static func acceptsSnapshotReplica(
        isUbiquitous: Bool,
        hasCurrentVersion: Bool?
    ) -> Bool {
        !isUbiquitous || hasCurrentVersion == true
    }

    /// NSFileCoordinator read — the canonical way to read an iCloud document
    /// (avoids torn reads while an upload/download replaces the file). Falls
    /// back to a direct read if coordination errors.
    private nonisolated static func coordinatedRead(_ url: URL) -> Data? {
        var coordError: NSError?
        var data: Data?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordError
        ) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        if coordError != nil {
            return try? Data(contentsOf: url)
        }
        return data
    }

    private nonisolated static func snapshotReadLimitBytes(named filename: String) -> Int {
        switch filename {
        case "chat_transcripts.json":
            return 6 * 1024 * 1024
        case "knowledge_graph.json", "runs.json":
            // runs.json carries up to 50 full prompt/output pairs — same
            // headroom tier as the KG. The daemon-era capabilities/agent_map/
            // coordination stubs are retired (R25): no consumer, no file.
            return 8 * 1024 * 1024
        case "turn_summaries.json":
            // Mac byte-budgets this to 256KB; 512KB read cap gives headroom while
            // keeping the oversized-skip guard meaningful.
            return 512 * 1024
        default:
            return 4 * 1024 * 1024
        }
    }

    // MARK: - Snapshot loaders

    // 2026-07-04 stale-snapshot fix: the old private instance loaders did plain
    // Data(contentsOf:) reads (stale iCloud replica). Everything now funnels
    // through the hardened static loaders (awaitCurrentVersion + coordinated
    // read). The unused sync/array variants were deleted — the hardened path
    // can wait up to ~2.5s for an iCloud download, so it must only run inside
    // the detached-task Async wrappers, never synchronously on the MainActor.
    func loadSnapshotObjectAsync<T: Decodable & Sendable>(named filename: String, as type: T.Type = T.self) async -> T? {
        guard let snapshotDir else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: snapshotDir.appendingPathComponent(filename))
        return await Self.loadSnapshotObjectOnly(named: filename, in: snapshotDir)
    }

    func loadSnapshotArrayAsync<T: Decodable & Sendable>(named filename: String, as type: T.Type = T.self) async -> [T]? {
        guard let snapshotDir else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: snapshotDir.appendingPathComponent(filename))
        return await Self.loadSnapshotArrayOnly(named: filename, in: snapshotDir)
    }
}
