// Snapshot publication for the Mac-owned device sync state.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import CryptoKit
import AppKit
import Foundation
import DeviceSyncState
import NativeAgentShared
import NativeAgentCore
import ChatSessionWork
import CognitiveSubstrate
import MemoryV2
import MacIntegration
import ApprovalInbox
import NotificationInbox
import PersistenceCore
import Desk
import Transcripts
import ProviderRouting
import TurnTrace
// Blueprint: | `MacSyncEngine+Snapshots.swift` | Revisioned snapshots retain exact payload/wire digests; phone Inspector reads its host; chat snapshots carry HerScreen's read-only other-room exchanges as an additive field |

extension MacSyncEngine {
    nonisolated static let turnSummariesSnapshotFilename = "turn_summaries.json"
    nonisolated static let organismLivingStatusSnapshotFilename = "organism_living_status.json"

    public enum SnapshotWriteScope: Sendable {
        case standard
        case chatSessions
        case workActivity

        // Broader scopes retain an activity pass of their own.
        func including(_ other: Self?) -> Self {
            if self == .standard || other == .standard { return .standard }
            return self == .chatSessions || other == .chatSessions ? .chatSessions : .workActivity
        }
    }

    // MARK: - Snapshot writer
    // trust_policy.json retains every raw checked policy field and adds the
    // engine-resolved preset and effective permission level, so keys the typed
    // Mac model does not name still reach the phone. iOS decodes
    // the raw JSON with lenient, fully-optional structs so the failure mode
    // is "field missing in UI", not "snapshot file disappears".

    public func writeSnapshots(
        forceHeavy: Bool = false,
        republish: Bool = false,
        includeMemories: Bool = false,
        includeChatTranscripts: Bool = false,
        scope: SnapshotWriteScope = .standard
    ) async {
        guard isActive, let snapshotDir else { return }
        if snapshotWriteInFlight {
            snapshotWriteQueuedScope = scope.including(snapshotWriteQueuedScope)
            snapshotWriteQueuedNeedsHeavy = snapshotWriteQueuedNeedsHeavy || forceHeavy
            snapshotWriteQueuedNeedsRepublish = snapshotWriteQueuedNeedsRepublish || republish
            snapshotWriteQueuedNeedsMemories = snapshotWriteQueuedNeedsMemories || includeMemories
            snapshotWriteQueuedNeedsChatTranscripts =
                snapshotWriteQueuedNeedsChatTranscripts || includeChatTranscripts
            return
        }
        let lifecycleGeneration = snapshotLifecycleGeneration
        snapshotWriteInFlight = true
        defer {
            snapshotWriteInFlight = false
            if snapshotIntegrityReconcileQueued, isActive { requestSnapshotIntegrityPass() }
            if isActive, let queuedScope = snapshotWriteQueuedScope {
                snapshotWriteQueuedScope = nil
                let queuedForceHeavy = snapshotWriteQueuedNeedsHeavy
                let queuedRepublish = snapshotWriteQueuedNeedsRepublish
                let queuedIncludeMemories = snapshotWriteQueuedNeedsMemories
                let queuedIncludeChatTranscripts = snapshotWriteQueuedNeedsChatTranscripts
                snapshotWriteQueuedNeedsHeavy = false
                snapshotWriteQueuedNeedsRepublish = false
                snapshotWriteQueuedNeedsMemories = false
                snapshotWriteQueuedNeedsChatTranscripts = false
                Task { @MainActor in
                    await self.writeSnapshots(
                        forceHeavy: queuedForceHeavy,
                        republish: queuedRepublish,
                        includeMemories: queuedIncludeMemories,
                        includeChatTranscripts: queuedIncludeChatTranscripts,
                        scope: queuedScope
                    )
                }
            }
        }

        // Admit the rest of this event burst before capturing any source input.
        // During the pass the same flags retain one follow-up, with heavy/chat
        // demand OR-merged rather than one build per observation.
        await Task.yield()
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        let heavy = forceHeavy || snapshotWriteQueuedNeedsHeavy
        if republish || snapshotWriteQueuedNeedsRepublish { snapshotFileDigests.removeAll() }
        let memories = includeMemories || snapshotWriteQueuedNeedsMemories
        let transcripts = includeChatTranscripts || snapshotWriteQueuedNeedsChatTranscripts
        let mergedScope = scope.including(snapshotWriteQueuedScope)
        snapshotWriteQueuedScope = nil
        snapshotWriteQueuedNeedsHeavy = false
        snapshotWriteQueuedNeedsRepublish = false
        snapshotWriteQueuedNeedsMemories = false
        snapshotWriteQueuedNeedsChatTranscripts = false
        await buildAndWriteSnapshots(
            forceHeavy: heavy, includeMemories: memories, includeChatTranscripts: transcripts, scope: mergedScope,
            snapshotDir: snapshotDir, lifecycleGeneration: lifecycleGeneration
        )
    }

    func encodeSnapshot<Value: Encodable & Sendable>(_ value: Value) async throws -> Data {
        try await MobileSnapshotBuilder.shared.encode(value)
    }

    private func buildAndWriteSnapshots(
        forceHeavy: Bool, includeMemories: Bool, includeChatTranscripts: Bool, scope: SnapshotWriteScope,
        snapshotDir: URL, lifecycleGeneration: UInt64
    ) async {
        if scope == .workActivity {
            await writeWorkActivitySnapshots(in: snapshotDir, lifecycleGeneration: lifecycleGeneration)
            return
        }
        requestWorkActivityPublication()
        let includeHeavySnapshots = forceHeavy
        let includeTranscriptSnapshots = forceHeavy || includeChatTranscripts
        if scope == .chatSessions, !forceHeavy, !includeMemories {
            await writeChatSessionSnapshots(
                includeTranscripts: includeChatTranscripts,
                snapshotDir: snapshotDir,
                lifecycleGeneration: lifecycleGeneration
            )
            return
        }

        let api = sync.host
        let readRevision = Date().timeIntervalSince1970

        do {
            // Fire lightweight freshness fetches. Full inventory/readout
            // snapshots are force-triggered so the idle timer does not rebuild
            // provider catalogs, turn summaries, chat transcripts, KG, etc.
            async let sessionsTask = api.getChatSessions()
            async let healthTask = api.getHealth()
            async let memProposalsTask = api.pendingMemoryProposals()
            async let organismTask = self.organismLivingStatusSnapshot()
            async let overviewTask = api.workOverview()
            async let skillsTask: DeviceSyncSnapshotRows? = {
                guard includeHeavySnapshots else { return nil }
                return try await api.getSkills()
            }()
            async let memoriesTask: [MemoryRecord]? = {
                guard includeHeavySnapshots || includeMemories else { return nil }
                return try await Self.retryingCancelledGroupRead("memories") {
                    try await api.activeMemories().map(MemoryRecord.init(phoneRow:))
                }
            }()
            async let connectorsTask: [MobileConnectorSnapshot]? = {
                guard includeHeavySnapshots else { return nil }
                return try await api.getConnectors()
            }()
            async let toolCatalogTask: [MobileToolCatalogRecord]? = {
                guard includeHeavySnapshots else { return nil }
                return try await api.mobileToolCatalog()
            }()
            async let providersTask: (providers: DeviceSyncSnapshotRows, routing: ProviderRoutingSnapshot)? = {
                guard includeHeavySnapshots else { return nil }
                return try await api.providers()
            }()

            var attemptedSnapshotGroups = Set<String>()
            var skippedSnapshotGroups: [String: String] = [:]
            func recordFetchFailure(_ label: String, _ error: Error) {
                let reason = error.localizedDescription
                attemptedSnapshotGroups.insert(label)
                skippedSnapshotGroups[label] = reason
                nativeLog("[MacSyncEngine] snapshot fetch failed for %@ — keeping last good file: %@", label, "\(error)")
            }
            func recordGroupSkip(_ label: String, _ reason: String) {
                attemptedSnapshotGroups.insert(label)
                skippedSnapshotGroups[label] = reason
                nativeLog("[MacSyncEngine] snapshot group %@ SKIPPED — keeping last good file: %@", label, reason)
            }

            var executions: [WorkshopTaskRecord]?
            var skills: DeviceSyncSnapshotRows?
            var memories: [MemoryRecord]?
            var connectors: [MobileConnectorSnapshot]?
            var toolCatalog: [MobileToolCatalogRecord]?
            var sessions: [ChatSession]?
            do { sessions = try await sessionsTask } catch {
                recordFetchFailure("sessions", error)
                recordGroupSkip("pinned_chat_sessions", "sessions unavailable: \(error.localizedDescription)")
                if includeTranscriptSnapshots {
                    recordGroupSkip("chat_transcripts", "sessions unavailable: \(error.localizedDescription)")
                }
            }
            var health: RuntimeHealth?
            do { health = try await healthTask } catch { recordFetchFailure("health", error) }
            var memProposals: DeviceSyncSnapshotRows?
            do { memProposals = try await memProposalsTask } catch { recordFetchFailure("memory_proposals", error) }
            var organismLivingStatus = await organismTask
            // One Desk read per pass: the overview and desk.json come from the
            // same board. needsUser is the overview's Needs you, the number
            // every Mac surface shows. The needs-you push runs off the app's
            // own overview read (DeviceSync.evaluateNeedsUser), not this pass.
            let (overview, deskItems, approvals, inbox, executionRows) = await overviewTask
            do { executions = try executionRows.get() } catch { recordFetchFailure("workshop_tasks", error) }
            if let deskItems, overview.unavailable.isEmpty {
                organismLivingStatus.needsUser = overview.needsYouCount > 0
                organismLivingStatus.needsAttention = (organismLivingStatus.needsAttention ?? false)
                    || deskItems.contains { $0.status == .blocked }
            } else {
                // Do not retain a prior healthy-looking mobile snapshot when
                // the desk half of the living-status projection is unreadable.
                // This bounded marker replaces it and tells the phone that its
                // counters/attention state are not a complete current read.
                nativeLog("[MacSyncEngine] overview read incomplete, publishing explicit status: \(overview.unavailable.joined(separator: "; "))")
            }
            organismLivingStatus = Self.organismLivingStatusAfterDeskRead(
                organismLivingStatus,
                deskReadSucceeded: deskItems != nil && overview.unavailable.isEmpty
            )
            var providers: (providers: DeviceSyncSnapshotRows, routing: ProviderRoutingSnapshot)?
            if includeHeavySnapshots {
                do { skills = try await skillsTask } catch { recordFetchFailure("skills_snapshot", error) }
            }
            if includeHeavySnapshots || includeMemories {
                do { memories = try await memoriesTask } catch { recordFetchFailure("memories", error) }
            }
            if includeHeavySnapshots {
                do { connectors = try await connectorsTask } catch { recordFetchFailure("connectors", error) }
                do { toolCatalog = try await toolCatalogTask } catch {
                    recordFetchFailure("tools_snapshot", error)
                }
                // Publish provider state on demand.
                // This can refresh provider catalogs, so keep it out of the idle timer.
                do { providers = try await providersTask } catch { recordFetchFailure("providers", error) }
            }

            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            var committedSnapshots: [String: Data] = [:]

            func writeData(_ data: Data, to filename: String) async {
                await publish(.built(data), to: filename)
            }

            func write<T: Encodable & Sendable>(_ value: T, to filename: String) async {
                await writeSnapshot(value, to: filename, in: snapshotDir,
                    lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                    changed: &committedSnapshots, skipped: &skippedSnapshotGroups,
                    attempted: &attemptedSnapshotGroups)
            }

            func publish(_ build: SnapshotGroupBuild, to filename: String) async {
                await writeSnapshot(build, to: filename, in: snapshotDir,
                    lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                    changed: &committedSnapshots, skipped: &skippedSnapshotGroups,
                    attempted: &attemptedSnapshotGroups)
            }

            await publish(await helpersSnapshotData(), to: "helpers_agents.json")
            await write(overview, to: "work_overview.json")
            if let executions {
                await write(executions, to: "workshop_tasks.json")
                projectWorkshopWorkActivities(executions)
                try? FileManager.default.removeItem(
                    at: snapshotDir.appendingPathComponent("missions.json")
                )
            }
            if let deskItems {
                do {
                    let projection = try await MobileSnapshotBuilder.shared.desk(deskItems, executions: executions)
                    await writeData(projection.data, to: "desk.json")
                    // Publish what the bounds dropped instead of leaving the
                    // phone to infer it from the row count it received.
                    await write(
                        MobileDeskProjectionReport(
                            totalRows: deskItems.count,
                            includedRows: projection.included
                        ),
                        to: "desk_bounds.json"
                    )
                    // Complete reading copies of the priority items, published
                    // automatically beside the compact board so a phone away
                    // from the desk can open the text it went out needing.
                    let readingCopies = try await MobileSnapshotBuilder.shared
                        .deskReadingCopies(deskItems)
                    await writeData(readingCopies.data, to: "desk_details.json")
                } catch {
                    recordFetchFailure("desk", error)
                }
            }
            await publish(await schedulerSnapshotData(), to: "scheduler.json")
            if let skills { await write(skills, to: "skills_snapshot.json") }
            if let toolCatalog { await write(toolCatalog, to: "tools_snapshot.json") }
            if let memories { await write(memories, to: "memories.json") }
            // Trust ships raw policy bytes for iOS's lenient decoder.
            async let trustData = try? api.trustSnapshotData()
            async let personalityFetch: PersonalityProfile? = {
                do { return try await api.getPersonality() } catch {
                    nativeLog("[MacSyncEngine] snapshot fetch failed for personality — keeping last good file: %@", "\(error)")
                    return nil
                }
            }()
            async let approvalsData: SnapshotGroupBuild = self.nativeApprovalsSnapshotData(approvals)
            async let inboxData: SnapshotGroupBuild = self.nativeInboxSnapshotData(inbox)
            let (trustRaw, personalityProfile, approvalsRaw, inboxRaw) = await (
                trustData,
                personalityFetch,
                approvalsData,
                inboxData
            )
            if let trustRaw {
                await writeData(trustRaw, to: "trust_policy.json")
            } else {
                recordGroupSkip("trust_policy", "native trust snapshot unavailable")
            }
            do {
                await write(try await api.macIntegrationPermissionsSnapshot(), to: "mac_integration_permissions.json")
            } catch {
                recordFetchFailure("mac_integration_permissions", error)
            }
            await write(sync.host.surfaceLayout(), to: "ui_layout.json")
            if let personalityProfile {
                await write(personalityProfile, to: "personality.json")
            } else {
                recordGroupSkip("personality", "native personality snapshot unavailable")
            }
            await publish(approvalsRaw, to: "approvals.json")
            await publish(inboxRaw, to: "inbox.json")
            if includeHeavySnapshots {
                // The phone summarizes the same persisted projection as Mac Inspector.
                async let turnSummariesData: Data? = sync.host.turnSummariesSnapshotData()
                async let knowledgeGraphData: SnapshotGroupBuild = self.nativeKnowledgeGraphSnapshotData()
                async let runsFetch: [RunRecord]? = {
                    let rows = await api.getRunsStrict()
                    if rows == nil {
                        nativeLog("[MacSyncEngine] runs ledger unreadable — keeping last good runs.json")
                    }
                    return rows
                }()
                let (turnSummariesRaw, knowledgeGraphRaw, runsAll) = await (
                    turnSummariesData,
                    knowledgeGraphData,
                    runsFetch
                )
                await publish(turnSummariesRaw.map(SnapshotGroupBuild.built) ?? .skipped("turn traces unreadable or incomplete"), to: Self.turnSummariesSnapshotFilename)
                await publish(knowledgeGraphRaw, to: "knowledge_graph.json")
                if let runsAll {
                    // Bound synced prompt/output/error fields without changing the stored runs.
                    @Sendable func clip(_ s: String?, _ cap: Int) -> String? {
                        guard let s, s.count > cap else { return s }
                        return String(s.prefix(cap)) + "… [clipped for sync]"
                    }
                    let runsData = await MobileSnapshotBuilder.shared.build { () -> Data? in
                        let encoder = MobileSnapshotBuilder.encoder()
                        let recent = runsAll
                            .sorted { $0.createdAt > $1.createdAt }
                            .prefix(50)
                            .map { run -> RunRecord in
                                var r = run
                                r.prompt = clip(r.prompt, 2_000)
                                r.output = clip(r.output, 4_000)
                                r.error = clip(r.error, 2_000)
                                return r
                            }
                        guard let bounded = try? EncodedPrefix.largestPrefix(
                            count: recent.count, maximumEncodedBytes: 6 * 1024 * 1024,
                            encode: { try encoder.encode(Array(recent.prefix($0))) }
                        ), recent.isEmpty || bounded.included > 0 else { return nil }
                        return bounded.data
                    }
                    if let runsData { await writeData(runsData, to: "runs.json") }
                } else {
                    recordGroupSkip("runs", "run ledger unavailable or unreadable")
                }
                // Remove unconsumed snapshot files from the synced container.
                for retired in [
                    "capabilities.json",
                    "agent_map.json",
                    "coordination_summary.json",
                    "command_palette.json",
                ] {
                    try? FileManager.default.removeItem(at: snapshotDir.appendingPathComponent(retired))
                }
            }
            if let connectors { await write(connectors, to: "connectors.json") }
            // Pinned/transcript snapshots derive
            // from sessions — skip them too when the sessions fetch failed so a
            // transient error can't blank the phone's pinned chats/transcripts.
            if let sessions {
                await write(sessions, to: "sessions.json")
                let navigation = sync.host.sessionNavigation(for: sessions)
                await write(navigation, to: "pinned_chat_sessions.json")
                if includeTranscriptSnapshots {
                    let transcriptSessions = transcriptSnapshotSessions(from: sessions, navigation: navigation)
                    let transcripts: [ChatTranscriptSnapshot] = transcriptSessions.isEmpty
                        ? []
                        : await chatTranscriptSnapshots(for: transcriptSessions, api: api)
                    await write(transcripts, to: "chat_transcripts.json")
                }
            }
            if let health { await write(health, to: "health.json") }
            await publish(await telegramSnapshotData(), to: "telegram.json")
            await write(organismLivingStatus, to: Self.organismLivingStatusSnapshotFilename)
            if let memProposals { await write(memProposals, to: "memory_proposals.json") }
            await write([JSONValue](), to: "training_proposals.json")
            if let providers { await write(providers.providers, to: "providers.json") }
            await write(api.providerSignInStates(), to: "provider_sign_ins.json")

            // Publish the resolved per-surface model
            // preferences so iOS chat-box + iOS providers-panel can show the
            // SAME model the Mac picker shows, and so the iOS chat-box can
            // hydrate from the Mac's surfaces.json instead of carrying its
            // own stale @AppStorage cache. Shape: { surface: { model,
            // reasoningEffort } }, inside the checked routing revision envelope.
            if includeHeavySnapshots {
                await publish(
                    await self.modelPreferencesSnapshotData(providers?.routing),
                    to: "model_preferences.json"
                )
            }

            await commitSnapshots(committedSnapshots, skipped: skippedSnapshotGroups,
                attempted: attemptedSnapshotGroups, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision, scope: .standard)

        } catch {
            syncError = "Snapshot error: \(error.localizedDescription)"
        }
        await sync.host.retryRequestedResults()
    }

    /// Completion/session mutations need only the canonical session index,
    /// pinned projection, and (for completed turns) bounded transcripts. This
    /// avoids rebuilding health, approvals, memory, provider, run, and graph
    /// snapshots on every ordinary conversation edge.
    private func writeChatSessionSnapshots(
        includeTranscripts: Bool,
        snapshotDir: URL,
        lifecycleGeneration: UInt64
    ) async {
        let readRevision = Date().timeIntervalSince1970
        let api = sync.host
        var changed: [String: Data] = [:]
        var skipped: [String: String] = [:]
        var attempted = Set<String>()
        func write<T: Encodable & Sendable>(_ value: T, filename: String) async {
            await writeSnapshot(value, to: filename, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                changed: &changed, skipped: &skipped, attempted: &attempted)
        }
        do {
            let sessions = try await api.getChatSessions()
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            let navigation = sync.host.sessionNavigation(for: sessions)
            await write(sessions, filename: "sessions.json")
            await write(navigation, filename: "pinned_chat_sessions.json")
            if includeTranscripts {
                let selected = transcriptSnapshotSessions(from: sessions, navigation: navigation)
                await write(await chatTranscriptSnapshots(for: selected, api: api), filename: "chat_transcripts.json")
            }
        } catch {
            attempted = ["sessions", "pinned_chat_sessions"]
            if includeTranscripts { attempted.insert("chat_transcripts") }
            for group in attempted { skipped[group] = "sessions unavailable: \(error.localizedDescription)" }
        }
        await commitSnapshots(changed, skipped: skipped, attempted: attempted, in: snapshotDir,
            lifecycleGeneration: lifecycleGeneration, readRevision: readRevision, scope: .chatSessions)
        await sync.host.retryRequestedResults()
    }

    func writeSnapshot<T: Encodable & Sendable>(
        _ value: T, to filename: String, in snapshotDir: URL,
        lifecycleGeneration: UInt64, readRevision: Double,
        changed: inout [String: Data], skipped: inout [String: String], attempted: inout Set<String>
    ) async {
        let build: SnapshotGroupBuild
        do { build = .built(try await encodeSnapshot(value)) }
        catch { build = .skipped("encoding failed: \(error.localizedDescription)") }
        await writeSnapshot(build, to: filename, in: snapshotDir,
            lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
            changed: &changed, skipped: &skipped, attempted: &attempted)
    }

    private func writeSnapshot(
        _ build: SnapshotGroupBuild, to filename: String, in snapshotDir: URL,
        lifecycleGeneration: UInt64, readRevision: Double,
        changed: inout [String: Data], skipped: inout [String: String], attempted: inout Set<String>
    ) async {
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        let group = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        attempted.insert(group)
        switch build {
        case .skipped(let reason): skipped[group] = reason
        case .built(let data):
            switch await writeSnapshotData(data, to: filename, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision) {
            case .changed(let bytes): changed[filename] = bytes
            case .failed(let reason): skipped[group] = "write failed: \(reason)"
            case .unchanged: break
            }
        }
    }

    /// Every scope holds the snapshot writer through publication and staleness reconciliation.
    func commitSnapshots(
        _ changed: [String: Data], skipped: [String: String], attempted: Set<String>, in snapshotDir: URL,
        lifecycleGeneration: UInt64, readRevision: Double, scope: SnapshotWriteScope
    ) async {
        var committedSnapshots = changed
        var skippedSnapshotGroups = skipped
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        lastSnapshotAt = Date()
        let prunedDigests = Self.digestsPrunedToExistingFiles(snapshotFileDigests, in: snapshotDir)
        if prunedDigests.count != snapshotFileDigests.count {
            snapshotFileDigests = prunedDigests
            await saveSnapshotDigests()
        }
        if !committedSnapshots.isEmpty {
            let failed = await publishChangedSnapshots(
                committedSnapshots,
                in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration,
                scope: scope
            )
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            skippedSnapshotGroups.merge(Self.publishFailureSkips(failed, changed: Set(committedSnapshots.keys))) { _, publish in publish }
        }
        let currentSkips = skippedSnapshotGroups
        let unresolvedSnapshotGroups = await MobileSnapshotBuilder.shared.build {
            Self.updateSnapshotSkipState(
                currentSkips: currentSkips, attemptedGroups: attempted,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
        }
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        if unresolvedSnapshotGroups.isEmpty {
            syncError = nil
        } else {
            let messages = NAMobileSnapshotGroup.stalenessMessages(unresolvedSnapshotGroups)
            syncError = messages.keys.sorted().first.flatMap { messages[$0] }
                ?? "iPhone updates could not be prepared. The last received data is still available. Open Connection in Settings to check the Mac link."
        }
        committedSnapshots = [:]
        if let stalenessMarker = await MobileSnapshotBuilder.shared.build({
            Self.snapshotStalenessMarkerData(unresolvedGroups: unresolvedSnapshotGroups)
        }) {
            var markerAttempts = Set<String>()
            await writeSnapshot(.built(stalenessMarker), to: Self.snapshotStalenessFilename, in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration, readRevision: readRevision,
                changed: &committedSnapshots, skipped: &skippedSnapshotGroups, attempted: &markerAttempts)
        }
        if !committedSnapshots.isEmpty {
            await publishChangedSnapshots(
                committedSnapshots,
                in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration,
                scope: scope
            )
        }
    }

    /// Publish, invalidate failed digests, signal the selected transport, then checkpoint.
    /// Returns each group that did not publish, with why.
    @discardableResult
    func publishChangedSnapshots(
        _ committed: [String: Data],
        in snapshotDir: URL,
        lifecycleGeneration: UInt64,
        scope: SnapshotWriteScope
    ) async -> [NAMobileSnapshotGroup: DeviceSyncError] {
        let changedFilenames = Set(committed.keys)
        let groups = NAMobileSnapshotGroup.groups(containingAny: changedFilenames)
        var failures = await sync.bridge.publishMobileSnapshotStatus(
            groups: groups,
            snapshotDirectory: snapshotDir,
            committed: committed,
            shouldPublish: { self.snapshotLifecycleGeneration == lifecycleGeneration && self.isActive }
        ) ?? [:]
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return [:] }
        if !failures.isEmpty {
            let messages = NAMobileSnapshotGroup.stalenessMessages(Self.publishFailureSkips(failures, changed: changedFilenames))
            syncError = messages.keys.sorted().first.flatMap { messages[$0] }
            forgetSnapshotDigests(for: changedFilenames)
        }
        if !sync.bridge.usesCloudKitDeviceTransport {
            let timeoutLabel = switch scope {
            case .standard: "MacSyncEngine.writeSnapshots.kvsSignal"
            case .chatSessions: "MacSyncEngine.writeChatSessionSnapshots.kvsSignal"
            case .workActivity: "MacSyncEngine.writeWorkActivitySnapshots.kvsSignal"
            }
            let signaled = await signalSnapshotGroups(groups, timeoutLabel: timeoutLabel)
            if signaled != true {
                let reason = "iPhone updates could not be delivered. The last received data is still available. The Mac will try again on its next update; keep NativeAgent open."
                syncError = reason
                for group in groups { failures[group] = .transient(message: reason) }
                forgetSnapshotDigests(for: changedFilenames)
            }
        }
        await saveSnapshotDigests()
        return failures
    }

    /// The snapshot file groups (names without extension, the skip state's and
    /// the phone's stale badge's vocabulary) a failed status group left stale:
    /// only the files this pass changed. An unchanged file is the copy the
    /// phone already has, and a mark on it would wait for its next rewrite.
    nonisolated static func publishFailureSkips(_ failures: [NAMobileSnapshotGroup: DeviceSyncError],
                                                changed: Set<String>) -> [String: String] {
        var skips: [String: String] = [:]
        for (group, reason) in failures {
            for filename in group.filenames where changed.contains(filename) {
                let page = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                skips[page] = "publish failed (\(group.rawValue)): \(reason.localizedDescription)"
                skips["_message.\(page)"] = NAMobileSnapshotGroup.stalePageMessage(page, recovery: reason.snapshotRecoveryMessage)
            }
        }
        return skips
    }

    private func signalSnapshotGroups(_ groups: Set<NAMobileSnapshotGroup>, timeoutLabel: String) async -> Bool? {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let names = groups.map(\.rawValue).sorted().joined(separator: ",")
        let signal = "\(stamp)|groups=\(names)"
        return await withCKTimeout(timeoutLabel) {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(signal, forKey: KVSKey.snapshotUpdated)
            return kvs.synchronize()
        }
    }

    private func transcriptSnapshotSessions(from sessions: [ChatSession], navigation: ChatSessionNavigation) -> [ChatSession] {
        var seen = Set<String>()
        var out: [ChatSession] = []
        func append(_ session: ChatSession?) {
            guard let session,
                  session.archived != true,
                  seen.insert(session.id).inserted else { return }
            out.append(session)
        }
        // The conversation User is in always rides first, whatever its source.
        let currentID = navigation.anchor?.sessionId
        append(sessions.first { $0.id == currentID })
        // Retain one Mac main and one phone main; isMainAppSourceKey includes both.
        append(sessions.first(where: {
            $0.sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines) == "app"
                && $0.archived != true
        }))
        append(sessions.first(where: {
            (NativeAgentICloudBridgeConstants.isMobileSourceKey($0.sourceKey)
                || (($0.source ?? "").lowercased() == "ios" && ($0.sourceKey ?? "").isEmpty))
                && $0.archived != true
        }))
        let remainingPins = navigation.rows.filter(\.isPinned).map(\.session).filter { !seen.contains($0.id) && $0.archived != true }
        let room = max(0, Self.transcriptSnapshotSessionCeiling - out.count)
        // Newest pins win both count and byte limits; omitted history remains explicitly unsynced.
        let selectedPins = Array(
            remainingPins
                .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
                .prefix(room)
        )
        for session in selectedPins {
            append(session)
        }
        // Fill remaining transcript capacity with recent history; agent-bridge and bot chats require an anchor or pin.
        for session in sessions.sorted(by: { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }) {
            guard out.count < Self.transcriptSnapshotSessionCeiling else { break }
            guard !["agent-bridge", "bot"].contains((session.source ?? "").lowercased()) else { continue }
            append(session)
        }
        return out
    }

    /// Failed publication invalidates those digests so the next pass rewrites and republishes the files.
    private func forgetSnapshotDigests(for filenames: Set<String>) {
        guard !filenames.isEmpty else { return }
        for filename in filenames {
            snapshotFileDigests.removeValue(forKey: filename)
        }
    }

    /// Maximum transcript sessions per publication; encoded bytes are bounded separately.
    static let transcriptSnapshotSessionCeiling = 16
    nonisolated static let transcriptSnapshotRowLimit = 80

    /// Raw chat_transcripts.json budget; the status codec also enforces 8 MiB raw and 800 KiB published limits.
    nonisolated static let chatTranscriptGroupByteBudget = 2 * 1024 * 1024

    private func chatTranscriptSnapshots(for sessions: [ChatSession], api: any DeviceSyncHost) async -> [ChatTranscriptSnapshot] {
        var out: [ChatTranscriptSnapshot] = []
        let exchanges: Result<[OtherRoomExchange], Error>
        do { exchanges = .success(try await api.getOtherRoomExchanges()) }
        catch { exchanges = .failure(error) }
        // The array framing the blocks ride in: "[" + "]".
        var used = 2
        for session in sessions {
            var snapshot = ChatTranscriptSnapshot(sessionId: session.id, messages: [],
                transcriptGeneration: session.transcriptGeneration)
            do {
                let messages = try await api.getChatMessages(sessionId: session.id)
                snapshot = ChatTranscriptSnapshot(
                    sessionId: session.id,
                    messages: await MobileSnapshotBuilder.shared.build { Self.compactTranscriptMessages(messages) },
                    transcriptGeneration: session.transcriptGeneration,
                    hasOlder: messages.lazy.filter(\.isPersonVisible).count > Self.transcriptSnapshotRowLimit
                )
                let since = snapshot.messages.first.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) }
                snapshot.otherRooms = try exchanges.get().filter { event in
                    event.sessionID != session.id && since.map { event.at >= $0 } == true
                }
            } catch {
                snapshot.readError = error.localizedDescription
            }
            let encodedBytes = (try? await MobileSnapshotBuilder.shared.encode(snapshot))?.count
                ?? Self.chatTranscriptGroupByteBudget
            // Each block after the first also carries its separating comma.
            var candidates = out + [snapshot]
            var size = used + encodedBytes + (out.isEmpty ? 0 : 1)
            if size > Self.chatTranscriptGroupByteBudget {
                // Spend the group on conversation rows before optional images,
                // including previews in sessions already selected this pass.
                candidates = await MobileSnapshotBuilder.shared.build { [candidates] in
                    candidates.map { $0.omittingAttachmentPreviews() }
                }
                size = (try? await MobileSnapshotBuilder.shared.encode(candidates))?.count
                    ?? (Self.chatTranscriptGroupByteBudget + 1)
            }
            guard size <= Self.chatTranscriptGroupByteBudget else { break }
            used = size
            out = candidates
        }
        // Publish only still-present sessions with unchanged generations; present rows without a counter remain eligible.
        if let generationsAfter = try? await api.getChatTranscriptGenerations() {
            out = out.filter { snapshot in
                guard let after = generationsAfter[snapshot.sessionId] else { return false }
                return after == snapshot.transcriptGeneration
            }
        }
        // Keep the highest-priority sessions that fit the actual compressed
        // envelope. Omitted sessions remain unsynced; never turn their rows
        // into an authoritative empty transcript just to meet the byte limit.
        let candidates = out
        return await MobileSnapshotBuilder.shared.build {
            let encoder = MobileSnapshotBuilder.encoder()
            var out = candidates
            // The compressed transport envelope has its own budget. Apply the
            // same optional-preview reduction before dropping any session.
            do {
                _ = try NAMobileSnapshotStatusCodec.encode(
                    group: .chat, files: ["chat_transcripts.json": try encoder.encode(out)])
                return out
            } catch DeviceSyncError.payloadTooLarge {
                out = out.map { $0.omittingAttachmentPreviews() }
            } catch {
                return out
            }
            while !out.isEmpty {
                do {
                    _ = try NAMobileSnapshotStatusCodec.encode(
                        group: .chat,
                        files: ["chat_transcripts.json": try encoder.encode(out)]
                    )
                    break
                } catch DeviceSyncError.payloadTooLarge {
                    out.removeLast()
                } catch {
                    // Other codec failures remain publication errors at the
                    // existing transport boundary rather than dropping history.
                    break
                }
            }
            return out
        }
    }

    private nonisolated static func compactTranscriptMessages(
        _ messages: [ChatMessageRecord]
    ) -> [ChatMessageRecord] {
        // Rows that are hers alone never reach the phone's transcript.
        messages.filter(\.isPersonVisible).suffix(transcriptSnapshotRowLimit).map { message in
            var copy = message
            copy.content = Self.truncateTranscriptContent(copy.content)
            return copy
        }
    }

    private nonisolated static func truncateTranscriptContent(_ content: String, maxCharacters: Int = 6_000) -> String {
        guard content.count > maxCharacters else { return content }
        return String(content.prefix(maxCharacters)) + "\n[truncated for iPhone snapshot]"
    }

    private nonisolated static let revisionedSnapshotFiles: Set<String> = [
        "approvals.json", "inbox.json", "memories.json", "memory_proposals.json"
    ]

    nonisolated static func revisionedSnapshotData(_ data: Data, revision: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["revision": revision,
            "value": JSONSerialization.jsonObject(with: data)], options: [.sortedKeys])
    }

    func writeSnapshotData(
        _ data: Data,
        to filename: String,
        in snapshotDir: URL,
        lifecycleGeneration expectedLifecycleGeneration: UInt64,
        readRevision: Double
    ) async -> SnapshotFileWriteResult {
        var data = data
        if let cap = Self.rowFileByteCaps[filename] {
            let bounded = await MobileSnapshotBuilder.shared.build { [data] in Self.newestRows(data, maxBytes: cap) }
            if bounded.dropped > 0 {
                nativeLog("[MacSyncEngine] %@ over %d bytes — kept the newest rows, dropped %d", filename, cap, bounded.dropped)
            }
            data = bounded.data
        }
        let digest = await MobileSnapshotBuilder.shared.build { [data] in MacSyncSnapshotIntegrity.digest(data) }
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration, isActive else { return .unchanged }
        let url = snapshotDir.appendingPathComponent(filename)
        // A saved digest cannot suppress recreation of a missing file.
        if snapshotFileDigests[filename]?.payload == digest,
           await VolumeIO.run({ FileManager.default.fileExists(atPath: url.path) }) {
            return .unchanged
        }
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration, isActive else { return .unchanged }
        if Self.revisionedSnapshotFiles.contains(filename) {
            do { data = try Self.revisionedSnapshotData(data, revision: readRevision) }
            catch { return .failed(error.localizedDescription) }
        }
        let wireDigest = MacSyncSnapshotIntegrity.digest(data)
        // Await the coordinated write before recording its digest or admitting another snapshot pass.
        let writeError = await VolumeIO.run { [data, url] in
            Self.coordinatedWriteReturningError(data: data, to: url)
        }
        // The coordinated filesystem write itself cannot be cancelled once it
        // has entered Foundation. It still targets the captured old cache URL;
        // A retiring write may have replaced bytes covered by a saved digest.
        // Invalidate that skip before admitting the restarted pass.
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration,
              isActive else {
            snapshotFileDigests.removeValue(forKey: filename)
            await saveSnapshotDigests()
            return .unchanged
        }
        if let writeError {
            syncError = "Snapshot write failed for \(filename): \(writeError)"
            return .failed(writeError)
        }
        snapshotFileDigests[filename] = SnapshotFileDigest(payload: digest, wire: wireDigest)
        return .changed(data)
    }

    /// Row files with no bound of their own. Each stays far under its group's
    /// transport budget (800 KiB published, 8 MiB raw), so one store's growth
    /// can no longer fail every other file in the group.
    nonisolated static let rowFileByteCaps: [String: Int] = [
        "sessions.json": 1_048_576,
        "memories.json": 1_048_576,
        "workshop_tasks.json": 1_048_576,
    ]

    /// A JSON array within `maxBytes`: when it does not fit, the newest rows
    /// (by `updatedAt`, else `createdAt`) that fit stay, in their own order.
    nonisolated static func newestRows(_ data: Data, maxBytes: Int) -> (data: Data, dropped: Int) {
        guard data.count > maxBytes,
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return (data, 0) }
        func stamp(_ row: Any) -> String {
            let object = row as? [String: Any]
            return object?["updatedAt"] as? String ?? object?["createdAt"] as? String ?? ""
        }
        let newestFirst = rows.indices.sorted { stamp(rows[$0]) > stamp(rows[$1]) }
        guard let bounded = try? EncodedPrefix.largestPrefix(
            count: max(0, rows.count - 1), maximumEncodedBytes: maxBytes,
            encode: { count in
                let kept = Set(newestFirst.prefix(count))
                return try JSONSerialization.data(withJSONObject: rows.indices.filter(kept.contains).map { rows[$0] },
                                                  options: [.sortedKeys])
            }
        ) else { return (data, 0) }
        return (bounded.data, rows.count - bounded.included)
    }

    /// Keep digest keys only while their snapshot files exist in dir.
    nonisolated static func digestsPrunedToExistingFiles(_ digests: [String: SnapshotFileDigest], in dir: URL) -> [String: SnapshotFileDigest] {
        digests.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.key).path) }
    }

    private func nativeApprovalsSnapshotData(_ read: Result<[ApprovalRequest], Error>) async -> SnapshotGroupBuild {
        let approvals: [ApprovalRequest]
        do { approvals = try read.get() } catch {
            return .skipped("approval store unreadable: \(error.localizedDescription)")
        }
        do { return .built(try await MobileSnapshotBuilder.shared.encode(approvals)) } catch {
            return .skipped("approvals could not be encoded: \(error.localizedDescription)")
        }
    }

    private func nativeInboxSnapshotData(_ read: Result<[InboxItemRecord], Error>) async -> SnapshotGroupBuild {
        let items: [InboxItemRecord]
        do { items = try read.get() } catch {
            return .skipped("inbox unreadable: \(error.localizedDescription)")
        }
        return await buildInboxSnapshot(items)
    }

    /// Value-only seam also used by the normal source-read path above.
    func buildInboxSnapshot(_ items: [InboxItemRecord]) async -> SnapshotGroupBuild {
        do {
            let projection = try await MobileSnapshotBuilder.shared.inbox(items)
            if !items.isEmpty, projection.included == 0 {
                return .skipped("mobile inbox rows exceeded the bounded projection budget")
            }
            if projection.included < items.count {
                nativeLog(
                    "[MacSyncEngine] mobile inbox projection bounded rows=%d total=%d bytes=%d",
                    projection.included,
                    items.count,
                    projection.data.count
                )
            }
            return .built(projection.data)
        } catch {
            return .skipped("inbox could not be encoded: \(error.localizedDescription)")
        }
    }

    private func nativeKnowledgeGraphSnapshotData() async -> SnapshotGroupBuild {
        do {
            return .built(try await Self.retryingCancelledGroupRead("knowledge_graph") {
                try await sync.host.knowledgeGraphSnapshotData()
            })
        } catch {
            nativeLog(
                "[MacSyncEngine] canonical knowledge graph unreadable — keeping last good snapshot: %@",
                String(describing: error)
            )
            return .skipped("knowledge graph unreadable: \(error.localizedDescription)")
        }
    }

    func organismLivingStatusSnapshot() async -> OrganismLivingStatusFile {
        let snapshot = await sync.cognition.organismSnapshot()
        return await MobileSnapshotBuilder.shared.build { Self.organismLivingStatusSnapshot(from: snapshot) }
    }

    nonisolated static func organismLivingStatusSnapshot(
        from snapshot: OrganismSnapshot
    ) -> OrganismLivingStatusFile {
        let posture = OrganismBehaviorPosture.from(snapshot: snapshot)
        let behaviorLine: String
        if let posture {
            behaviorLine = [
                posture.claimDiscipline.rawValue,
                posture.toolStrategy.rawValue,
                posture.loopBudget.rawValue,
            ].joined(separator: " / ")
        } else {
            behaviorLine = "off"
        }
        return OrganismLivingStatusFile(
            generatedAt: snapshot.generatedAt,
            enabled: snapshot.enabled,
            posture: posture?.posture ?? (snapshot.enabled ? "steady" : "off"),
            bodyLine: snapshot.projectedBodyLine,
            behaviorLine: behaviorLine,
            needsUser: false,
            needsAttention: LivingAttentionPolicy.organismNeedsAttention(snapshot),
            signalCount: snapshot.signalCount,
            lastSignalAt: snapshot.lastSignalAt,
            body: OrganismLivingBodyFile(
                macAwake: snapshot.bodySchema.macAwake,
                iPhoneReachable: snapshot.bodySchema.iPhoneReachable,
                providersHealthy: snapshot.bodySchema.providersHealthy,
                memoryHealthy: snapshot.bodySchema.memoryHealthy,
                dreamHealthy: snapshot.bodySchema.dreamHealthy,
                toolHandsAvailable: snapshot.bodySchema.toolHandsAvailable,
                approvalChannelsOpen: snapshot.bodySchema.approvalChannelsOpen,
                notificationPathHealthy: snapshot.bodySchema.notificationPathHealthy,
                resourcePressure: snapshot.bodySchema.resourcePressure.rawValue
            ),
            counters: OrganismLivingCountersFile(
                fieldNodes: snapshot.fieldSummary.nodeCount,
                pendingPredictions: snapshot.predictionSummary.pendingCount,
                dreamRepairs: snapshot.dreamRepairSummary.receiptCount,
                // Preserve shared fields for iPhone decoding compatibility.
                reflexCandidates: 0,
                reflexesNeedReview: 0,
                approvedReflexBiases: nil,
                standingViewProposals: nil
            ),
            standingViewProposals: nil,
            availability: snapshot.enabled ? .live : .disabled
        )
    }

    /// The status file is the mobile boundary for this combined organism + desk
    /// projection. A failed desk read must replace, rather than preserve, a
    /// previously complete file; disabled organism snapshots stay disabled.
    nonisolated static func organismLivingStatusAfterDeskRead(
        _ status: OrganismLivingStatusFile,
        deskReadSucceeded: Bool
    ) -> OrganismLivingStatusFile {
        guard !deskReadSucceeded, status.enabled else { return status }
        var unavailable = status
        unavailable.markUnavailable(reason: "desk_status_unavailable")
        return unavailable
    }

    /// Publish checked per-surface routing preferences; omit empty surfaces the Mac cannot honor.
    private func modelPreferencesSnapshotData(_ routing: ProviderRoutingSnapshot?) async -> SnapshotGroupBuild {
        guard let routing else { return .skipped("model preferences unreadable: provider settings unavailable") }
        return await MobileSnapshotBuilder.shared.build {
            let out = iCloudBridge.providerSurfaceSelections(from: routing).mapValues { selection in
                var row = ["model": selection.model]
                if let provider = selection.providerID { row["providerId"] = provider }
                if let effort = selection.reasoningEffort { row["reasoningEffort"] = effort }
                if let tier = selection.serviceTier, !tier.isEmpty { row["serviceTier"] = tier }
                return row
            }
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            do { return .built(try Self.revisionedSnapshotData(enc.encode(out), revision: routing.revision)) } catch {
                return .skipped("model preferences could not be encoded: \(error.localizedDescription)")
            }
        }
    }
}

extension MemoryRecord {
    /// The phone's memories.json row, in the shape the Mac browsing list
    /// has always sent: importance 0, pinned spelled out, no tags.
    init(phoneRow r: MemoryV2.MemoryRecord) {
        self.init(
            id: r.id, layer: r.layer ?? "semantic", text: r.text, sourceRunId: r.sourceRunId,
            importance: 0, confidence: r.confidence ?? 0, status: r.status, pinned: r.pinned ?? false,
            createdAt: r.createdAt, updatedAt: r.updatedAt
        )
    }
}
