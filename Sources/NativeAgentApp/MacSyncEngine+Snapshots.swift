// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: every N seconds writes app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import CryptoKit
import AppKit
import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import CognitiveSubstrate
import KnowledgeGraph
import PersistenceCore

struct MobileToolCatalogRecord: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String?
    var status: String?
    var description: String?
    var autoRun: Bool?
    var riskClass: String?
    var updatedAt: String?
}

enum MobileToolCatalogProjection {
    static func records(from catalog: ChatToolCatalogSnapshot) -> [MobileToolCatalogRecord] {
        catalog.tools.map { tool in
            MobileToolCatalogRecord(
                id: tool.name,
                name: tool.name,
                kind: tool.dispatchableVia,
                status: tool.loadState,
                description: tool.description,
                autoRun: tool.effectiveAutonomy == "auto",
                riskClass: tool.effectiveAutonomy,
                updatedAt: nil
            )
        }
    }
}

enum MobileInboxProjection {
    static let maximumRows = 300
    static let maximumActiveRows = 200
    static let maximumEncodedBytes = 384 * 1024

    static func data(
        from items: [InboxItemRecord],
        encoder: JSONEncoder
    ) throws -> (data: Data, included: Int) {
        let sorted = items.sorted {
            if $0.created_at != $1.created_at { return $0.created_at > $1.created_at }
            return $0.id > $1.id
        }
        let active = sorted.filter(\.isActivityPending).prefix(maximumActiveRows)
        let activeIDs = Set(active.map(\.id))
        let resolved = sorted
            .filter { !activeIDs.contains($0.id) && !$0.isActivityPending }
            .prefix(max(0, maximumRows - active.count))
        var projection = Array(active) + Array(resolved)
        while true {
            let data = try encoder.encode(projection)
            if data.count <= maximumEncodedBytes {
                return (data, projection.count)
            }
            guard !projection.isEmpty else { return (data, 0) }
            projection.removeLast()
        }
    }
}

enum MobileDeskProjection {
    static let maximumRows = 300
    static let maximumNotesPerItem = 5
    static let maximumEncodedBytes = 512 * 1024

    static func data(from items: [DeskItem], encoder: JSONEncoder) throws -> (data: Data, included: Int) {
        var records = items.sorted {
            if $0.status.isTerminal != $1.status.isTerminal { return !$0.status.isTerminal }
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }.prefix(maximumRows).map { item in
            MobileDeskItem(
                handle: item.handle,
                alias: item.alias,
                parent: item.parent,
                kind: item.kind.rawValue,
                status: item.status.rawValue,
                project: String(item.project.prefix(200)),
                title: String(item.title.prefix(500)),
                summary: item.summary.map { String($0.prefix(2_000)) },
                openedAt: item.openedAt,
                updatedAt: item.updatedAt,
                closedAt: item.closedAt,
                pinned: item.pinned,
                blockedReason: item.blockedReason.map { String($0.prefix(1_000)) },
                waitingOn: item.waitingOn.map { String($0.prefix(200)) },
                blockedOn: Array(item.blockedOn.prefix(25)),
                deferUntil: item.deferUntil,
                origin: item.origin.rawValue,
                requiresOwnerInput: item.requiresOwnerInput,
                recentNotes: item.notes.suffix(maximumNotesPerItem).map {
                    MobileDeskNote(timestamp: $0.ts, text: String($0.text.prefix(2_000)))
                }
            )
        }
        while true {
            let data = try encoder.encode(records)
            if data.count <= maximumEncodedBytes { return (data, records.count) }
            guard !records.isEmpty else { return (data, 0) }
            records.removeLast()
        }
    }
}

private enum SnapshotFileWriteResult {
    case unchanged
    case changed
    case failed(String)
}

extension MacSyncEngine {
    enum SnapshotWriteScope: Sendable {
        case standard
        case chatSessions
    }

    // MARK: - Snapshot writer
    // 2026-05-09 / 2026-05-31: raw snapshot bytes flow through
    // NativeClient.trustSnapshotData() — bypasses Codable decode for
    // endpoints whose typed Mac models have non-optional fields with default
    // values that the daemon doesn't emit (developerMode etc). iOS decodes
    // the raw JSON with lenient, fully-optional structs so the failure mode
    // is "field missing in UI", not "snapshot file disappears". Centralized
    // in NativeClient as part of the Wave-2 direct-caller consolidation.

    func writeSnapshots(
        forceHeavy: Bool = false,
        includeChatTranscripts: Bool = false,
        scope: SnapshotWriteScope = .standard
    ) async {
        guard isActive, let snapshotDir else { return }
        if snapshotWriteInFlight {
            snapshotWriteQueued = true
            snapshotWriteQueuedNeedsHeavy = snapshotWriteQueuedNeedsHeavy || forceHeavy
            snapshotWriteQueuedNeedsChatTranscripts =
                snapshotWriteQueuedNeedsChatTranscripts || includeChatTranscripts
            snapshotWriteQueuedNeedsStandardPass =
                snapshotWriteQueuedNeedsStandardPass || scope == .standard
            return
        }
        let lifecycleGeneration = snapshotLifecycleGeneration
        snapshotWriteInFlight = true
        let includeHeavySnapshots = forceHeavy
        let includeTranscriptSnapshots = forceHeavy || includeChatTranscripts
        defer {
            if lifecycleGeneration == snapshotLifecycleGeneration {
                snapshotWriteInFlight = false
            }
            if lifecycleGeneration == snapshotLifecycleGeneration, snapshotWriteQueued {
                snapshotWriteQueued = false
                let queuedForceHeavy = snapshotWriteQueuedNeedsHeavy
                let queuedIncludeChatTranscripts = snapshotWriteQueuedNeedsChatTranscripts
                let queuedScope: SnapshotWriteScope = snapshotWriteQueuedNeedsStandardPass
                    ? .standard
                    : .chatSessions
                snapshotWriteQueuedNeedsHeavy = false
                snapshotWriteQueuedNeedsChatTranscripts = false
                snapshotWriteQueuedNeedsStandardPass = false
                Task { @MainActor in
                    await self.writeSnapshots(
                        forceHeavy: queuedForceHeavy,
                        includeChatTranscripts: queuedIncludeChatTranscripts,
                        scope: queuedScope
                    )
                }
            }
        }

        if scope == .chatSessions, !forceHeavy {
            await writeChatSessionSnapshots(
                includeTranscripts: includeChatTranscripts,
                snapshotDir: snapshotDir,
                lifecycleGeneration: lifecycleGeneration
            )
            return
        }

        let api = NativeClient(baseURL: "")

        do {
            // Fire lightweight freshness fetches. Full inventory/readout
            // snapshots are force-triggered so the idle timer does not rebuild
            // provider catalogs, turn summaries, chat transcripts, KG, etc.
            async let executionsTask = api.getWorkshopExecutions()
            async let sessionsTask = api.getChatSessions()
            async let healthTask = api.getHealth()
            async let memProposalsTask = api.getMemoryProposals()
            async let trainingTask = api.getTrainingProposals()
            async let promotionTask = api.getPromotionPending()
            async let organismTask = Self.organismLivingStatusSnapshot()

            // fix-2026-06-10 sync-audit #1: a transient fetch failure must NOT
            // become a successfully-written EMPTY snapshot (`?? []` fabricated
            // empty state, replaced the last good file, and pinged iOS — the
            // phone showed zero missions/memories until the next pass). Mirror
            // modelPreferencesSnapshotData's nil-skip: on a thrown fetch, skip
            // that snapshot file (keep the last good one) and record the error
            // so it's visible in syncError + the log.
            var snapshotFetchFailures: [String] = []
            func recordFetchFailure(_ label: String, _ error: Error) {
                snapshotFetchFailures.append("\(label): \(error.localizedDescription)")
                NSLog("[MacSyncEngine] snapshot fetch failed for %@ — keeping last good file: %@", label, "\(error)")
            }
            // Sweep R4 item 2: groups the native helpers could not build. Same
            // publish behavior as before (keep last good), but the group is now
            // NAMED — in syncError and in the durable skip file Doctor reads —
            // so "iPhone is showing stale approvals" stops being invisible.
            var skippedSnapshotGroups: [String: String] = [:]
            func recordGroupSkip(_ label: String, _ reason: String) {
                skippedSnapshotGroups[label] = reason
                snapshotFetchFailures.append("\(label): \(reason)")
                NSLog("[MacSyncEngine] snapshot group %@ SKIPPED — keeping last good file: %@", label, reason)
            }

            var executions: [WorkshopExecutionRecord]?
            do { executions = try await executionsTask } catch { recordFetchFailure("missions", error) }
            var skills: [SkillRecord]?
            var memories: [MemoryRecord]?
            var connectors: [ConnectorRecord]?
            var toolCatalog: ChatToolCatalogSnapshot?
            var sessions: [ChatSession]?
            do { sessions = try await sessionsTask } catch { recordFetchFailure("sessions", error) }
            let health = try? await healthTask
            var memProposals: [MemoryProposalRecord]?
            do { memProposals = try await memProposalsTask } catch { recordFetchFailure("memory_proposals", error) }
            var training: [TrainingProposalSummary]?
            do { training = try await trainingTask } catch { recordFetchFailure("training_proposals", error) }
            var promotion: [PromotionCandidateSummary]?
            do { promotion = try await promotionTask } catch { recordFetchFailure("promotion_candidates", error) }
            var organismLivingStatus = await organismTask
            var organismLivingStatusReady = true
            // Needs-User APNS is reserved for an exact canonical owner wait.
            // Approvals have their own APNS lane. Generic blocked work,
            // provider caution, reflex review, and other body trouble stay
            // visible as attention but must not manufacture a user request.
            var deskItems: [DeskItem]?
            do {
                let desk = try await SwiftNativeDeskStore(
                    dataRoot: PersistenceCore.defaultDataRoot()
                ).liveState()
                deskItems = desk.items
                let ownerDecisionCount = LivingAttentionPolicy.ownerDecisionDeskCount(in: desk.items)
                organismLivingStatus.needsUser = ownerDecisionCount > 0
                organismLivingStatus.needsAttention = (organismLivingStatus.needsAttention ?? false)
                    || desk.items.contains { $0.status == .blocked }
                let why = ownerDecisionCount > 0
                    ? "Desk has \(ownerDecisionCount) item\(ownerDecisionCount == 1 ? "" : "s") explicitly waiting on the owner."
                    : ""
                await NeedsUserEdgeNotifier.shared.evaluate(
                    needsUser: ownerDecisionCount > 0,
                    why: why
                )
            } catch {
                organismLivingStatusReady = false
                NSLog("needs_user_notify: desk read failed, skipping evaluation: \(error.localizedDescription)")
            }
            var providers: [ProviderInfo]?
            if includeHeavySnapshots {
                do { skills = try await api.getSkills() } catch { recordFetchFailure("skills", error) }
                do { memories = try await api.getMemories() } catch { recordFetchFailure("memories", error) }
                do { connectors = try await api.getConnectors() } catch { recordFetchFailure("connectors", error) }
                do { toolCatalog = try await api.getChatToolCatalogSnapshot() } catch {
                    recordFetchFailure("tool_catalog", error)
                }
                // PATCH-2026-05-07: leftover-1 providers.json snapshot so iOS reads provider state.
                // This can refresh provider catalogs, so keep it out of the idle timer.
                do { providers = try await api.listProviders() } catch { recordFetchFailure("providers", error) }
            }

            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            var wroteAnySnapshot = false
            var changedSnapshotFilenames: Set<String> = []

            func writeData(_ data: Data, to filename: String) async {
                guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
                switch await writeSnapshotData(
                    data,
                    to: filename,
                    in: snapshotDir,
                    lifecycleGeneration: lifecycleGeneration
                ) {
                case .changed:
                    wroteAnySnapshot = true
                    changedSnapshotFilenames.insert(filename)
                case .failed(let reason):
                    snapshotFetchFailures.append("\(filename) write: \(reason)")
                case .unchanged:
                    break
                }
            }

            func write<T: Encodable>(_ value: T, to filename: String) async {
                guard let data = try? encoder.encode(value) else { return }
                await writeData(data, to: filename)
            }

            /// Publish when the group built; NAME it when it was skipped.
            func publish(_ build: SnapshotGroupBuild, as label: String, to filename: String) async {
                switch build {
                case .built(let data): await writeData(data, to: filename)
                case .skipped(let reason): recordGroupSkip(label, reason)
                }
            }

            if let executions {
                await write(executions, to: "workshop_tasks.json")
                try? FileManager.default.removeItem(
                    at: snapshotDir.appendingPathComponent("missions.json")
                )
            }
            if let deskItems {
                do {
                    let projection = try MobileDeskProjection.data(from: deskItems, encoder: encoder)
                    await writeData(projection.data, to: "desk.json")
                } catch {
                    recordFetchFailure("desk", error)
                }
            }
            if let skills { await write(skills, to: "skills_snapshot.json") }
            if let toolCatalog {
                await write(
                    MobileToolCatalogProjection.records(from: toolCatalog),
                    to: "tools_snapshot.json"
                )
            }
            if let memories { await write(memories, to: "memories.json") }
            // PATCH-2026-05-09: 2026-05-09 trust + personality bypass NativeClient
            // typed decode (Mac's TrustPolicy has `developerMode: Bool = false`
            // which Codable still requires — daemon doesn't send it, decode
            // silently fails, file never written).  Pipe raw daemon bytes
            // directly: iOS decodes with its own lenient struct.
            async let trustData = api.trustSnapshotData()
            // R25 (2026-07-02): personality now has a native loader —
            // NativeClient.getPersonality() returns the SHARED PersonalityProfile
            // iOS decodes, so the daemon-era `{}` stub is gone. Nil-skip on
            // fetch failure (sync-audit #1: never replace last-good with
            // fabricated state).
            async let personalityFetch: PersonalityProfile? = {
                do { return try await api.getPersonality() } catch {
                    NSLog("[MacSyncEngine] snapshot fetch failed for personality — keeping last good file: %@", "\(error)")
                    return nil
                }
            }()
            async let approvalsData: SnapshotGroupBuild = self.nativeApprovalsSnapshotData(api: api)
            async let inboxData: SnapshotGroupBuild = self.nativeInboxSnapshotData(api: api)
            // The command palette is unconditionally Swift-native and reads
            // its live persona, approval, and autonomy context directly from
            // canonical local owners without an HTTP round-trip.
            let (trustRaw, personalityProfile, approvalsRaw, inboxRaw) = await (
                trustData,
                personalityFetch,
                approvalsData,
                inboxData
            )
            if let trustRaw { await writeData(trustRaw, to: "trust_policy.json") }
            if let personalityProfile { await write(personalityProfile, to: "personality.json") }
            await publish(approvalsRaw, as: "approvals", to: "approvals.json")
            await publish(inboxRaw, as: "inbox", to: "inbox.json")
            if includeHeavySnapshots {
                // Turn Inspector W4: per-turn summaries for the iOS read-only
                // inspector (content-free; size-budgeted). Off-main read of the
                // persisted day file — not a bus subscriber, no hot-path cost.
                async let turnSummariesData: Data? = self.turnSummariesSnapshotData()
                async let commandPaletteData = api.fetchCommandPaletteRawData()
                // Swift-native cutover: native KG file read.
                // R25 (2026-07-02): the fabricated capabilities/agent_map/
                // coordination stubs are GONE — no iOS surface ever consumed
                // them, so the honest state is no file at all. runs.json is
                // real now: AdvancedView's runs list had shipped UI waiting on
                // a snapshot nobody wrote (newest 50, nil-skip on failure).
                async let knowledgeGraphData: SnapshotGroupBuild = self.nativeKnowledgeGraphSnapshotData()
                async let runsFetch: [RunRecord]? = {
                    // Strict read: nil = ledger exists but unreadable/corrupt →
                    // skip the write, keep last-good (review MED #1, 2026-07-02).
                    let rows = await api.getRunsStrict()
                    if rows == nil {
                        NSLog("[MacSyncEngine] runs ledger unreadable — keeping last good runs.json")
                    }
                    return rows
                }()
                let (turnSummariesRaw, commandPaletteRaw, knowledgeGraphRaw, runsAll) = await (
                    turnSummariesData,
                    commandPaletteData,
                    knowledgeGraphData,
                    runsFetch
                )
                if let turnSummariesRaw { await writeData(turnSummariesRaw, to: "turn_summaries.json") }
                if let commandPaletteRaw { await writeData(commandPaletteRaw, to: "command_palette.json") }
                await publish(knowledgeGraphRaw, as: "knowledge_graph", to: "knowledge_graph.json")
                if let runsAll {
                    // Byte-budget the snapshot copy (review MED #2): prompt/
                    // output/error are unbounded on disk; 50 uncapped worker
                    // outputs can exceed iOS's 8MB hard-skip and the phone
                    // would silently show a stale/empty list. Clipped fields
                    // bound the file at ~50 × 8KB ≈ 400KB worst case.
                    func clip(_ s: String?, _ cap: Int) -> String? {
                        guard let s, s.count > cap else { return s }
                        return String(s.prefix(cap)) + "… [clipped for sync]"
                    }
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
                    // TRUE byte bound (delta review 2026-07-02): the grapheme
                    // clips shrink the dominant fields but don't bound the
                    // encoded bytes (JSON escaping, multi-byte clusters, other
                    // unbounded fields). Post-encode guard: halve the run count
                    // until under budget; never publish an oversized file iOS
                    // would hard-skip.
                    var bounded = Array(recent)
                    let runsByteBudget = 6 * 1024 * 1024
                    while true {
                        guard let data = try? encoder.encode(bounded) else { break }
                        if data.count <= runsByteBudget {
                            await writeData(data, to: "runs.json")
                            break
                        }
                        if bounded.count <= 1 {
                            NSLog("[MacSyncEngine] runs.json over byte budget even at 1 run — skipping write")
                            break
                        }
                        bounded = Array(bounded.prefix(bounded.count / 2))
                    }
                }
                // R25: sweep the retired fabricated stubs out of the synced
                // container so no stale fake-empty file lingers (idempotent).
                for retired in ["capabilities.json", "agent_map.json", "coordination_summary.json"] {
                    try? FileManager.default.removeItem(at: snapshotDir.appendingPathComponent(retired))
                }
                lastHeavySnapshotAt = Date()
            }
            if let connectors { await write(connectors, to: "connectors.json") }
            // fix-2026-06-10 sync-audit #1: pinned/transcript snapshots derive
            // from sessions — skip them too when the sessions fetch failed so a
            // transient error can't blank the phone's pinned chats/transcripts.
            if let sessions {
                await write(sessions, to: "sessions.json")
                let pinnedSessions = pinnedChatSessions(from: sessions)
                await write(pinnedSessions, to: "pinned_chat_sessions.json")
                if includeTranscriptSnapshots {
                    let transcriptSessions = transcriptSnapshotSessions(from: sessions, pinnedSessions: pinnedSessions)
                    let transcripts: [ChatTranscriptSnapshot] = transcriptSessions.isEmpty
                        ? []
                        : await chatTranscriptSnapshots(for: transcriptSessions, api: api)
                    await write(transcripts, to: "chat_transcripts.json")
                }
            }
            if let health { await write(health, to: "health.json") }
            if organismLivingStatusReady {
                await write(organismLivingStatus, to: "organism_living_status.json")
            }
            if let memProposals { await write(memProposals, to: "memory_proposals.json") }
            if let training { await write(training, to: "training_proposals.json") }
            if let promotion { await write(promotion, to: "promotion_candidates.json") }
            if let providers { await write(providers, to: "providers.json") }

            // 2026-06-05 picker-sync: publish the resolved per-surface model
            // preferences so iOS chat-box + iOS providers-panel can show the
            // SAME model the Mac picker shows, and so the iOS chat-box can
            // hydrate from the Mac's surfaces.json instead of carrying its
            // own stale @AppStorage cache. Shape: { surface: { model,
            // reasoningEffort } } — flat-string variants are tolerated by
            // the iOS reader for back-compat.
            if includeHeavySnapshots {
                await publish(
                    await self.modelPreferencesSnapshotData(api: api),
                    as: "model_preferences",
                    to: "model_preferences.json"
                )
            }

            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            lastSnapshotAt = Date()
            // fix-2026-06-10 sync-audit #1: surface skipped-fetch errors instead
            // of clearing them — the snapshot files themselves kept last-good data.
            // Sweep R4 item 2: lead with the SKIPPED GROUP NAMES, because that
            // is what tells the owner which iPhone surface is stale.
            if snapshotFetchFailures.isEmpty {
                syncError = nil
            } else {
                let staleGroups = skippedSnapshotGroups.keys.sorted()
                let prefix = staleGroups.isEmpty
                    ? "Snapshot fetch failed (kept last good files)"
                    : "iPhone is showing STALE \(staleGroups.joined(separator: ", ")) (kept last good files)"
                syncError = "\(prefix): \(snapshotFetchFailures.joined(separator: "; "))"
            }
            // Durable so Doctor can report it later, from a different process,
            // without depending on this @Published in-memory string.
            // NativeAgentPaths.dataRoot, not PersistenceCore.defaultDataRoot():
            // every other piece of MacSyncEngine's local bookkeeping (processed
            // ids, completion markers) resolves through NativeAgentPaths, and
            // two resolvers for one subsystem is how state ends up split across
            // two roots.
            Self.persistSnapshotSkipState(
                skippedSnapshotGroups,
                dataRoot: NativeAgentPaths.dataRoot
            )

            // Notify iOS via KVS only when content changed; unchanged digest
            // ticks should not wake the phone into another full snapshot read.
            if wroteAnySnapshot {
                let changedGroups = NAMobileSnapshotGroup.groups(
                    containingAny: changedSnapshotFilenames
                )
                let published = await iCloudBridge.shared.publishMobileSnapshotStatus(
                    groups: changedGroups,
                    snapshotDirectory: snapshotDir
                )
                guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
                if !published, iCloudBridge.shared.usesCloudKitDeviceTransport {
                    syncError = "iPhone snapshot publication failed for \(changedGroups.map(\.rawValue).sorted().joined(separator: ", ")). The last proven phone data was retained."
                }
                if !iCloudBridge.shared.usesCloudKitDeviceTransport {
                    let snapshotStamp = ISO8601DateFormatter().string(from: Date())
                    let groupNames = changedGroups
                        .map(\.rawValue)
                        .sorted()
                        .joined(separator: ",")
                    let snapshotSignal = "\(snapshotStamp)|groups=\(groupNames)"
                    let signaled: Bool? = await withCKTimeout("MacSyncEngine.writeSnapshots.kvsSignal") {
                        let kvs = NSUbiquitousKeyValueStore.default
                        kvs.set(snapshotSignal, forKey: KVSKey.snapshotUpdated)
                        return kvs.synchronize()
                    }
                    if signaled != true {
                        syncError = "iPhone snapshot signal failed. The files were retained for the next sync edge."
                    }
                }
                // fix-snapshot-digest-persist: checkpoint the updated digest map so
                // a crash/restart before stop() still avoids re-writing these files.
                saveSnapshotDigests()
            }

        } catch {
            syncError = "Snapshot error: \(error.localizedDescription)"
        }
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
        let api = NativeClient(baseURL: "")
        let sessions: [ChatSession]
        do {
            sessions = try await api.getChatSessions()
        } catch {
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            syncError = "Chat session snapshot failed; the last proven phone sessions were retained: \(error.localizedDescription)"
            return
        }
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }

        let pinnedSessions = pinnedChatSessions(from: sessions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var changedFilenames = Set<String>()
        var writeFailures: [String] = []

        func write<T: Encodable>(_ value: T, filename: String) async {
            guard lifecycleGeneration == snapshotLifecycleGeneration,
                  isActive,
                  let data = try? encoder.encode(value) else { return }
            switch await writeSnapshotData(
                data,
                to: filename,
                in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration
            ) {
            case .changed:
                changedFilenames.insert(filename)
            case .failed(let reason):
                writeFailures.append("\(filename): \(reason)")
            case .unchanged:
                break
            }
        }

        await write(sessions, filename: "sessions.json")
        await write(pinnedSessions, filename: "pinned_chat_sessions.json")
        if includeTranscripts {
            let selected = transcriptSnapshotSessions(
                from: sessions,
                pinnedSessions: pinnedSessions
            )
            let transcripts = await chatTranscriptSnapshots(for: selected, api: api)
            await write(transcripts, filename: "chat_transcripts.json")
        }
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        lastSnapshotAt = Date()
        if !writeFailures.isEmpty {
            syncError = "iPhone chat snapshot write failed; last proven files were retained: \(writeFailures.joined(separator: "; "))"
        }
        guard !changedFilenames.isEmpty else { return }

        let groups = NAMobileSnapshotGroup.groups(containingAny: changedFilenames)
        let published = await iCloudBridge.shared.publishMobileSnapshotStatus(
            groups: groups,
            snapshotDirectory: snapshotDir
        )
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
        if !published, iCloudBridge.shared.usesCloudKitDeviceTransport {
            syncError = "iPhone chat snapshot publication failed. The last proven phone conversation was retained."
        } else if writeFailures.isEmpty {
            syncError = nil
        }
        if !iCloudBridge.shared.usesCloudKitDeviceTransport {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let names = groups.map(\.rawValue).sorted().joined(separator: ",")
            let signaled: Bool? = await withCKTimeout("MacSyncEngine.writeChatSessionSnapshots.kvsSignal") {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set("\(stamp)|groups=\(names)", forKey: KVSKey.snapshotUpdated)
                return kvs.synchronize()
            }
            if signaled != true {
                syncError = "iPhone chat snapshot signal failed. The files were retained for the next sync edge."
            }
        }
        saveSnapshotDigests()
    }

    private func pinnedChatSessionIds() -> [String] {
        MacPinnedChatSessionStore.load()
    }

    private func pinnedChatSessions(from sessions: [ChatSession]) -> [ChatSession] {
        let liveById = Dictionary(
            sessions
                .filter { $0.archived != true }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return pinnedChatSessionIds().compactMap { liveById[$0] }
    }

    private func transcriptSnapshotSessions(from sessions: [ChatSession], pinnedSessions: [ChatSession]) -> [ChatSession] {
        var seen = Set<String>()
        var out: [ChatSession] = []
        func append(_ session: ChatSession?) {
            guard let session,
                  session.archived != true,
                  seen.insert(session.id).inserted else { return }
            out.append(session)
        }
        // Retain one Mac main and one phone main. `isMainAppSourceKey` includes
        // both, so selecting only its first match made whichever device sorted
        // second disappear from the mobile transcript projection.
        append(sessions.first(where: {
            $0.sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines) == "app"
                && $0.archived != true
        }))
        append(sessions.first(where: {
            (NativeAgentICloudBridgeConstants.isMobileSourceKey($0.sourceKey)
                || (($0.source ?? "").lowercased() == "ios" && ($0.sourceKey ?? "").isEmpty))
                && $0.archived != true
        }))
        for session in pinnedSessions {
            append(session)
        }
        return out
    }

    private func chatTranscriptSnapshots(for sessions: [ChatSession], api: NativeClient) async -> [ChatTranscriptSnapshot] {
        var out: [ChatTranscriptSnapshot] = []
        for session in sessions.prefix(8) {
            guard let messages = try? await api.getChatMessages(sessionId: session.id) else { continue }
            out.append(ChatTranscriptSnapshot(sessionId: session.id, messages: compactTranscriptMessages(messages)))
        }
        return out
    }

    private func compactTranscriptMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.suffix(80).map { message in
            var copy = message
            copy.content = Self.truncateTranscriptContent(copy.content)
            return copy
        }
    }

    private nonisolated static func truncateTranscriptContent(_ content: String, maxCharacters: Int = 6_000) -> String {
        guard content.count > maxCharacters else { return content }
        return String(content.prefix(maxCharacters)) + "\n[truncated for iPhone snapshot]"
    }

    private func writeSnapshotData(
        _ data: Data,
        to filename: String,
        in snapshotDir: URL,
        lifecycleGeneration expectedLifecycleGeneration: UInt64
    ) async -> SnapshotFileWriteResult {
        let digest = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
        let url = snapshotDir.appendingPathComponent(filename)
        // FIX (E): only skip the write when the digest matches AND the snapshot
        // file actually exists on disk. Digests persist across restarts, so a
        // matching digest with a missing/deleted file would otherwise suppress
        // recreating the snapshot forever, leaving iOS with no (or stale) data.
        if snapshotFileDigests[filename] == digest,
           FileManager.default.fileExists(atPath: url.path) {
            return .unchanged
        }
        // Off-main coordinated write, AWAITED so the write completes before this
        // returns. That keeps the original semantics exactly: digest is recorded
        // (and `true` returned) only on a confirmed write, the snapshotWriteInFlight
        // guard serializes passes, and no detached write outlives writeSnapshots
        // to race a same-file write from the next pass.
        let writeError = await Task.detached(priority: .utility) { [data, url] in
            Self.coordinatedWriteReturningError(data: data, to: url)
        }.value
        // The coordinated filesystem write itself cannot be cancelled once it
        // has entered Foundation. It still targets the captured old cache URL;
        // after a stop/restart, do not let its late result mutate the new
        // generation's digest/error/publication state.
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration,
              isActive else { return .unchanged }
        if let writeError {
            syncError = "Snapshot write failed for \(filename): \(writeError)"
            return .failed(writeError)
        }
        snapshotFileDigests[filename] = digest
        return .changed
    }

    /// Coordinated write returning an optional error description (nil = success).
    /// nonisolated static — safe to call from detached tasks off the main actor.
    nonisolated private static func coordinatedWriteReturningError(data: Data, to url: URL) -> String? {
        var writeError: String?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error.localizedDescription
            }
        }
        if writeError == nil, let coordError {
            writeError = coordError.localizedDescription
        }
        return writeError
    }


    // Swift-native cutover: native snapshot helpers replacing /v1/approvals, /v1/inbox,
    // and /v1/knowledge_graph reads.
    //
    // Sweep R4 item 2: these used to return `Data?`, and the writeSnapshots loop
    // read nil as "skip this file, best-effort". Nil-skip is still the RIGHT
    // publish behavior — the phone keeps the last good file instead of being
    // handed fabricated empty state — but it was silent: the Mac published
    // every other group and nothing said the phone was now holding stale
    // approvals or an out-of-date model choice. The typed result carries the
    // REASON out so the same pass that keeps last-good also says which group
    // went stale and why.
    private func nativeApprovalsSnapshotData(api: NativeClient) async -> SnapshotGroupBuild {
        let approvals: [ApprovalRequest]
        do { approvals = try await api.getApprovals() } catch {
            return .skipped("approval store unreadable: \(error.localizedDescription)")
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .sortedKeys
        do { return .built(try enc.encode(approvals)) } catch {
            return .skipped("approvals could not be encoded: \(error.localizedDescription)")
        }
    }

    private func nativeInboxSnapshotData(api: NativeClient) async -> SnapshotGroupBuild {
        let items: [InboxItemRecord]
        do { items = try await api.getInboxItems() } catch {
            return .skipped("inbox unreadable: \(error.localizedDescription)")
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .sortedKeys
        do {
            let projection = try MobileInboxProjection.data(from: items, encoder: enc)
            if !items.isEmpty, projection.included == 0 {
                return .skipped("mobile inbox rows exceeded the bounded projection budget")
            }
            if projection.included < items.count {
                NSLog(
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
            return .built(try await NativeClient.canonicalKnowledgeGraphSnapshotData())
        } catch {
            NSLog(
                "[MacSyncEngine] canonical knowledge graph unreadable — keeping last good snapshot: %@",
                String(describing: error)
            )
            return .skipped("knowledge graph unreadable: \(error.localizedDescription)")
        }
    }

    private static func organismLivingStatusSnapshot() async -> OrganismLivingStatusFile {
        let snapshot = await NativeCognitionRuntime.shared.organismSnapshot()
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
                reflexCandidates: snapshot.reflexSummary.candidateCount,
                reflexesNeedReview: snapshot.reflexSummary.reviewRequiredCount,
                approvedReflexBiases: snapshot.reflexSummary.approvedLowRiskCount,
                standingViewProposals: snapshot.dreamRepairSummary.proposedStandingViews
            ),
            reflexCandidates: snapshot.reflexCandidates.prefix(8).map {
                OrganismLivingReflexCandidateFile(
                    id: $0.id,
                    pattern: $0.pattern,
                    trustClass: $0.trustClass.rawValue,
                    confidence: $0.confidence,
                    reviewRequired: $0.reviewRequired,
                    autoActivationAllowed: $0.autoActivationAllowed,
                    approvedAt: $0.approvedAt
                )
            },
            standingViewProposals: snapshot.dreamRepairSummary.standingViewProposals.prefix(4).map {
                OrganismLivingStandingViewProposalFile(
                    id: $0.id,
                    title: $0.title,
                    rationale: $0.rationale,
                    evidenceIDs: $0.evidenceIDs,
                    reviewRequired: $0.reviewRequired
                )
            }
        )
    }

    /// Turn Inspector W4: compute the per-turn SUMMARY snapshot for the iOS
    /// read-only inspector. Reads TODAY's (+ yesterday's) persisted turn-trace
    /// day file off the live root, groups via the existing
    /// `TurnInspectorGrouping`, projects to content-free `TurnSummaryRecord`s,
    /// and applies the count + byte budget (truncation marker on drop).
    ///
    /// Runs entirely on a detached utility task — disk read + decode + grouping
    /// are off the main actor and off the chat hot path (this is a 30s-poll read
    /// of the persisted day file, NOT a TurnTraceBus subscriber). Returns nil
    /// only on encode failure so a transient miss keeps the last good snapshot.
    private func turnSummariesSnapshotData() async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            let root = TurnSummarySource.liveRoot()
            let events = TurnSummarySource.loadEvents(root: root)
            let encoder = TurnSummaryComputer.makeEncoder()
            let file = TurnSummaryComputer.compute(from: events, encoder: encoder)
            return try? encoder.encode(file)
        }.value
    }

    /// 2026-06-05 picker-sync: encode the picker's resolved per-surface
    /// model preferences as JSON for iOS to pull. Shape:
    /// `{ "chat": {"model": "claude-opus-4-8", "reasoningEffort": "high"}, ... }`.
    /// Empty surfaces are omitted so iOS doesn't render rows the Mac can't
    /// honor. Returns nil only when the picker call itself throws — a stub
    /// `{}` would silently let iOS overwrite the Mac with empty state, so
    /// nil-skip is safer.
    private func modelPreferencesSnapshotData(api: NativeClient) async -> SnapshotGroupBuild {
        let prefs: SurfaceModelPreferencesResponse
        do { prefs = try await api.getModelPreferences() } catch {
            return .skipped("model preferences unreadable: \(error.localizedDescription)")
        }
        var out: [String: [String: String]] = [:]
        for entry in prefs.preferences {
            let surface = entry.surface
            let model = entry.model
            guard !surface.isEmpty, !model.isEmpty else { continue }
            var row: [String: String] = ["model": model]
            let effort = entry.reasoningEffort
            if !effort.isEmpty { row["reasoningEffort"] = effort }
            if let serviceTier = entry.serviceTier, !serviceTier.isEmpty {
                row["serviceTier"] = serviceTier
            }
            out[surface] = row
        }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        do { return .built(try enc.encode(out)) } catch {
            return .skipped("model preferences could not be encoded: \(error.localizedDescription)")
        }
    }
}

extension MacSyncEngine {
    /// Durable record of which snapshot groups the last pass could not build.
    /// Written on EVERY pass — including the clean one, which removes the file —
    /// so Doctor never reports a skip the next pass already recovered from.
    nonisolated static func persistSnapshotSkipState(
        _ skips: [String: String],
        dataRoot: URL
    ) {
        let url = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
        guard !skips.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var payload = skips
        payload["_observedAt"] = ISO8601DateFormatter().string(from: Date())
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            NSLog("[MacSyncEngine] could not record snapshot skip state: %@", error.localizedDescription)
        }
    }
}

/// Sweep R4 item 2: the outcome of building ONE iOS snapshot group.
///
/// `.skipped` keeps the publish behavior identical to the old `nil` — the file
/// is not rewritten, so the phone keeps the last good copy — while carrying the
/// reason out so the pass can name the stale group in `syncError` and in the
/// durable state Doctor reads.
enum SnapshotGroupBuild {
    case built(Data)
    case skipped(String)

    var data: Data? {
        if case .built(let data) = self { return data }
        return nil
    }

    var skipReason: String? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}
