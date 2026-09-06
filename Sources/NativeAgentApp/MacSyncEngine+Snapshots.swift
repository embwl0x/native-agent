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

/// Reconciles the persisted snapshot-digest cache against the files the iPhone
/// actually reads.  The digest cache is an optimization, never evidence that
/// a file remains intact: a same-name file can be truncated or replaced by an
/// out-of-process iCloud/crash-window event while its old digest still sits in
/// memory.  This bounded check runs only in MacSync's slow integrity fallback.
enum MacSyncSnapshotIntegrity {
    static let maximumSnapshotBytes = 8 * 1024 * 1024

    struct Report: Equatable {
        let retainedDigests: [String: String]
        let missingManagedFiles: [String]
        let mismatchedManagedFiles: [String]
        let unreadableManagedFiles: [String]
        let retiredDigestKeys: [String]

        var requiresRepair: Bool {
            !missingManagedFiles.isEmpty
                || !mismatchedManagedFiles.isEmpty
                || !unreadableManagedFiles.isEmpty
        }

        var integrityFailures: [String] {
            (missingManagedFiles.map { "\($0) is missing" }
                + mismatchedManagedFiles.map { "\($0) digest mismatch" }
                + unreadableManagedFiles.map { "\($0) unreadable" })
                .sorted()
        }
    }

    /// Only files carried by the current mobile snapshot manifest are repaired.
    /// A missing digest for a retired file is pruned without manufacturing a
    /// costly rebuild for a contract the phone no longer consumes.
    static func reconcile(
        digests: [String: String],
        in directory: URL,
        managedFilenames: Set<String> = Set(NAMobileSnapshotGroup.allCases.flatMap(\.filenames))
    ) -> Report {
        let fileManager = FileManager.default
        var retained: [String: String] = [:]
        var missing: [String] = []
        var mismatched: [String] = []
        var unreadable: [String] = []
        var retired: [String] = []

        for (filename, expectedDigest) in digests {
            let isManaged = managedFilenames.contains(filename)
            let url = directory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path) else {
                if isManaged { missing.append(filename) } else { retired.append(filename) }
                continue
            }
            guard isManaged else {
                // A stale key must not keep claiming a file that no longer
                // belongs to the mobile contract, even if a same-name artifact
                // happens to remain in the directory.
                retired.append(filename)
                continue
            }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let byteCount = attributes[.size] as? NSNumber,
                      byteCount.intValue >= 0,
                      byteCount.intValue <= maximumSnapshotBytes else {
                    unreadable.append(filename)
                    continue
                }
                let actualDigest = digest(try Data(contentsOf: url))
                guard actualDigest == expectedDigest else {
                    mismatched.append(filename)
                    continue
                }
                retained[filename] = expectedDigest
            } catch {
                unreadable.append(filename)
            }
        }
        return Report(
            retainedDigests: retained,
            missingManagedFiles: missing.sorted(),
            mismatchedManagedFiles: mismatched.sorted(),
            unreadableManagedFiles: unreadable.sorted(),
            retiredDigestKeys: retired.sorted()
        )
    }

    static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

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

enum MobileProjectionEncoder {
    static func largestPrefix<Record: Encodable>(
        of records: [Record],
        maximumEncodedBytes: Int,
        encoder: JSONEncoder
    ) throws -> (data: Data, included: Int) {
        let fullData = try encoder.encode(records)
        guard fullData.count > maximumEncodedBytes else {
            return (fullData, records.count)
        }

        // Encoded array size grows monotonically with its prefix. Find the
        // largest safe prefix in logarithmic encodes instead of removing one
        // row and re-encoding the whole array on every pass.
        var low = 0
        var high = records.count
        var bestData = try encoder.encode([Record]())
        var bestCount = 0
        while low <= high {
            let midpoint = low + (high - low) / 2
            let data = try encoder.encode(Array(records.prefix(midpoint)))
            if data.count <= maximumEncodedBytes {
                bestData = data
                bestCount = midpoint
                low = midpoint + 1
            } else {
                high = midpoint - 1
            }
        }
        return (bestData, bestCount)
    }
}

enum MobileInboxProjection {
    static let maximumRows = 300
    static let maximumActiveRows = 200
    static let maximumEncodedBytes = 384 * 1024

    static func data(
        from items: [InboxItemRecord],
        encoder: JSONEncoder,
        alreadyNewestFirst: Bool = false
    ) throws -> (data: Data, included: Int) {
        let sorted = alreadyNewestFirst ? items : items.sorted {
            if $0.created_at != $1.created_at { return $0.created_at > $1.created_at }
            return $0.id > $1.id
        }

        var active: [InboxItemRecord] = []
        var resolved: [InboxItemRecord] = []
        active.reserveCapacity(min(maximumActiveRows, sorted.count))
        resolved.reserveCapacity(min(maximumRows, sorted.count))
        for item in sorted {
            if item.isActivityPending {
                if active.count < maximumActiveRows { active.append(item) }
            } else if resolved.count < maximumRows {
                resolved.append(item)
            }
        }
        resolved = Array(resolved.prefix(max(0, maximumRows - active.count)))
        let projection = active + resolved
        return try MobileProjectionEncoder.largestPrefix(
            of: projection,
            maximumEncodedBytes: maximumEncodedBytes,
            encoder: encoder
        )
    }
}

enum MobileDeskProjection {
    static let maximumRows = 300
    static let maximumNotesPerItem = 5
    static let maximumEncodedBytes = 512 * 1024

    static func data(from items: [DeskItem], encoder: JSONEncoder) throws -> (data: Data, included: Int) {
        let records = items.sorted {
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
        return try MobileProjectionEncoder.largestPrefix(
            of: records,
            maximumEncodedBytes: maximumEncodedBytes,
            encoder: encoder
        )
    }
}

enum SnapshotFileWriteResult: Equatable {
    case unchanged
    case changed
    case failed(String)
}

extension MacSyncEngine {
    nonisolated static let turnSummariesSnapshotFilename = "turn_summaries.json"
    nonisolated static let organismLivingStatusSnapshotFilename = "organism_living_status.json"

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
            async let organismTask = self.organismLivingStatusSnapshot()

            // fix-2026-06-10 sync-audit #1: a transient fetch failure must NOT
            // become a successfully-written EMPTY snapshot (`?? []` fabricated
            // empty state, replaced the last good file, and pinged iOS — the
            // phone showed zero missions/memories until the next pass). Mirror
            // modelPreferencesSnapshotData's nil-skip: on a thrown fetch, skip
            // that snapshot file (keep the last good one) and record the error
            // so it's visible in syncError + the log.
            var snapshotFetchFailures: [String] = []
            var attemptedSnapshotGroups = Set<String>()
            var skippedSnapshotGroups: [String: String] = [:]
            func snapshotGroupName(for filename: String) -> String {
                URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            }
            func recordFetchFailure(_ label: String, _ error: Error) {
                let reason = error.localizedDescription
                attemptedSnapshotGroups.insert(label)
                skippedSnapshotGroups[label] = reason
                snapshotFetchFailures.append("\(label): \(reason)")
                NSLog("[MacSyncEngine] snapshot fetch failed for %@ — keeping last good file: %@", label, "\(error)")
            }
            // Sweep R4 item 2: groups the native helpers could not build. Same
            // publish behavior as before (keep last good), but the group is now
            // NAMED — in syncError and in the durable skip file Doctor reads —
            // so "iPhone is showing stale approvals" stops being invisible.
            func recordGroupSkip(_ label: String, _ reason: String) {
                attemptedSnapshotGroups.insert(label)
                skippedSnapshotGroups[label] = reason
                snapshotFetchFailures.append("\(label): \(reason)")
                NSLog("[MacSyncEngine] snapshot group %@ SKIPPED — keeping last good file: %@", label, reason)
            }

            var executions: [WorkshopExecutionRecord]?
            do { executions = try await executionsTask } catch { recordFetchFailure("workshop_tasks", error) }
            var skills: [SkillRecord]?
            var memories: [MemoryRecord]?
            var connectors: [ConnectorRecord]?
            var toolCatalog: ChatToolCatalogSnapshot?
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
            var memProposals: [MemoryProposalRecord]?
            do { memProposals = try await memProposalsTask } catch { recordFetchFailure("memory_proposals", error) }
            var training: [TrainingProposalSummary]?
            do { training = try await trainingTask } catch { recordFetchFailure("training_proposals", error) }
            var promotion: [PromotionCandidateSummary]?
            do { promotion = try await promotionTask } catch { recordFetchFailure("promotion_candidates", error) }
            var organismLivingStatus = await organismTask
            // Needs-User APNS is reserved for an exact canonical owner wait.
            // Approvals have their own APNS lane. Generic blocked work,
            // provider caution, reflex review, and other body trouble stay
            // visible as attention but must not manufacture a user request.
            var deskItems: [DeskItem]?
            var deskLivingStatusReadSucceeded = false
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
                deskLivingStatusReadSucceeded = true
            } catch {
                // Do not retain a prior healthy-looking mobile snapshot when
                // the desk half of the living-status projection is unreadable.
                // This bounded marker replaces it and tells the phone that its
                // counters/attention state are not a complete current read.
                NSLog("needs_user_notify: desk read failed, publishing explicit status: \(error.localizedDescription)")
            }
            organismLivingStatus = Self.organismLivingStatusAfterDeskRead(
                organismLivingStatus,
                deskReadSucceeded: deskLivingStatusReadSucceeded
            )
            var providers: [ProviderInfo]?
            if includeHeavySnapshots {
                do { skills = try await api.getSkills() } catch { recordFetchFailure("skills_snapshot", error) }
                do {
                    memories = try await Self.retryingCancelledGroupRead("memories") {
                        try await api.getMemories()
                    }
                } catch { recordFetchFailure("memories", error) }
                do { connectors = try await api.getConnectors() } catch { recordFetchFailure("connectors", error) }
                do { toolCatalog = try await api.getChatToolCatalogSnapshot() } catch {
                    recordFetchFailure("tools_snapshot", error)
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
                let group = snapshotGroupName(for: filename)
                attemptedSnapshotGroups.insert(group)
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
                    recordGroupSkip(group, "write failed: \(reason)")
                case .unchanged:
                    break
                }
            }

            func write<T: Encodable>(_ value: T, to filename: String) async {
                do {
                    await writeData(try encoder.encode(value), to: filename)
                } catch {
                    recordGroupSkip(
                        snapshotGroupName(for: filename),
                        "encoding failed: \(error.localizedDescription)"
                    )
                }
            }

            /// Publish when the group built; NAME it when it was skipped.
            func publish(_ build: SnapshotGroupBuild, as label: String, to filename: String) async {
                attemptedSnapshotGroups.insert(label)
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
            if let trustRaw {
                await writeData(trustRaw, to: "trust_policy.json")
            } else {
                recordGroupSkip("trust_policy", "native trust snapshot unavailable")
            }
            if let personalityProfile {
                await write(personalityProfile, to: "personality.json")
            } else {
                recordGroupSkip("personality", "native personality snapshot unavailable")
            }
            await publish(approvalsRaw, as: "approvals", to: "approvals.json")
            await publish(inboxRaw, as: "inbox", to: "inbox.json")
            if includeHeavySnapshots {
                // Turn Inspector W4: per-turn summaries for the iOS read-only
                // inspector (content-free; size-budgeted). Off-main read of the
                // persisted day file — not a bus subscriber, no hot-path cost.
                async let turnSummariesData: Data? = self.turnSummariesSnapshotData()
                // E8 (upgrade-sweep 2026-08): command_palette.json was fetched
                // and published on every heavy pass with ZERO readers in the
                // iOS target. Choice made: stop writing it rather than build a
                // palette screen nobody asked for. Reinstate the fetch here if
                // that screen is ever wanted.
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
                let (turnSummariesRaw, knowledgeGraphRaw, runsAll) = await (
                    turnSummariesData,
                    knowledgeGraphData,
                    runsFetch
                )
                if let turnSummariesRaw {
                    await writeData(turnSummariesRaw, to: Self.turnSummariesSnapshotFilename)
                }
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
                } else {
                    recordGroupSkip("runs", "run ledger unavailable or unreadable")
                }
                // R25: sweep the retired fabricated stubs out of the synced
                // container so no stale fake-empty file lingers (idempotent).
                // E8 adds command_palette.json to the same sweep: it was
                // written for years and never read.
                for retired in [
                    "capabilities.json",
                    "agent_map.json",
                    "coordination_summary.json",
                    "command_palette.json",
                ] {
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
                if let anchor = chatAnchorSnapshot() {
                    await write(anchor, to: "chat_anchor.json")
                }
                if includeTranscriptSnapshots {
                    let transcriptSessions = transcriptSnapshotSessions(from: sessions, pinnedSessions: pinnedSessions)
                    let transcripts: [ChatTranscriptSnapshot] = transcriptSessions.isEmpty
                        ? []
                        : await chatTranscriptSnapshots(for: transcriptSessions, api: api)
                    await write(transcripts, to: "chat_transcripts.json")
                }
            }
            if let health { await write(health, to: "health.json") }
            await write(organismLivingStatus, to: Self.organismLivingStatusSnapshotFilename)
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
            let unresolvedSnapshotGroups = Self.updateSnapshotSkipState(
                currentSkips: skippedSnapshotGroups,
                attemptedGroups: attemptedSnapshotGroups,
                dataRoot: NativeAgentPaths.dataRoot
            )
            // Sweep 2026-09-01 item 2: the skip record above is LOCAL. Publish
            // the same per-group truth into the bundle so the phone's Memory
            // and Knowledge Graph screens can say they are holding old rows
            // instead of rendering them as current.
            if let stalenessMarker = Self.snapshotStalenessMarkerData(
                unresolvedGroups: unresolvedSnapshotGroups
            ) {
                await writeData(stalenessMarker, to: Self.snapshotStalenessFilename)
            }
            if snapshotFetchFailures.isEmpty, unresolvedSnapshotGroups.isEmpty {
                syncError = nil
            } else {
                let staleGroups = unresolvedSnapshotGroups.keys.sorted()
                let prefix = staleGroups.isEmpty
                    ? "Snapshot fetch failed (kept last good files)"
                    : "iPhone is showing STALE \(staleGroups.joined(separator: ", ")) (kept last good files)"
                let reasons = staleGroups.compactMap { group in
                    unresolvedSnapshotGroups[group].map { "\(group): \($0)" }
                }
                syncError = "\(prefix): \(reasons.joined(separator: "; "))"
            }

            // Notify iOS via KVS only when content changed; unchanged digest
            // ticks should not wake the phone into another full snapshot read.
            // A digest whose file is gone (a retired snapshot name, or a deleted
            // cache) must not survive: the phone diffs against this map, and a
            // key with no file reads as "already have it" for data it never saw.
            let prunedDigests = Self.digestsPrunedToExistingFiles(snapshotFileDigests, in: snapshotDir)
            if prunedDigests.count != snapshotFileDigests.count {
                snapshotFileDigests = prunedDigests
                saveSnapshotDigests()   // durable even on a pass that wrote nothing
            }
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
                    forgetSnapshotDigests(for: changedSnapshotFilenames)
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
        if let anchor = chatAnchorSnapshot() {
            await write(anchor, filename: "chat_anchor.json")
        }
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
            forgetSnapshotDigests(for: changedFilenames)
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

    /// The human's own pins, with the conversation anchor merged in FRONT.
    ///
    /// The anchor is the remote conversation User is currently in, on whichever
    /// surface published it. Merging rather than WRITING it into
    /// `pinned_session_ids.json` is deliberate: an auto-write would fight the
    /// human every time they unpinned it, and would rewrite the file (and
    /// re-publish the phone snapshot) on every `/new`.
    ///
    /// Nothing here knows which surface the anchor came from, and nothing may.
    private func pinnedChatSessionIds() -> [String] {
        ConversationAnchor.merged(into: MacPinnedChatSessionStore.load())
    }

    /// The anchor as the phone consumes it: one small file in the same `.core`
    /// group as `sessions.json` and `pinned_chat_sessions.json`, so it arrives
    /// on the same edge as the sessions it refers to.
    ///
    /// The phone can already SEE the anchor session (it is first in
    /// `pinned_chat_sessions.json`), but "first in a list" is an implicit
    /// contract nobody wrote down. This file states the fact outright, so the
    /// phone can pin and default to it for the same reason the Mac does rather
    /// than by inferring it from ordering.
    private func chatAnchorSnapshot() -> ConversationAnchorPin? {
        ConversationAnchor.current()
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
        // 2026-09-06: the pins used to ride into a flat `prefix(8)` downstream,
        // so a pin past the eighth entry got no transcript at all — and the
        // phone, which can only reread this snapshot, opened it as an empty
        // chat that could never fill. Every pin the phone can select is
        // published now. Past the ceiling the NEWEST pins win, and an older
        // one reads as "history not synced" on the phone instead of as empty.
        let remainingPins = pinnedSessions.filter { !seen.contains($0.id) && $0.archived != true }
        let room = max(0, Self.transcriptSnapshotSessionCeiling - out.count)
        // 2026-09-06: newest-first ALWAYS, not only when the count ceiling
        // bites. `chatTranscriptSnapshots` also drops the tail of this list
        // when the group's byte budget runs out, so the tail has to be the
        // oldest pins whichever bound does the dropping.
        let selectedPins = Array(
            remainingPins
                .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
                .prefix(room)
        )
        for session in selectedPins {
            append(session)
        }
        return out
    }

    /// 2026-09-06: publication is the half that actually reaches the phone, and
    /// the digest map is what suppresses the next write. The digest was recorded
    /// on a successful FILE write, so a publication that then failed left the
    /// phone without the bytes and every later pass reporting `.unchanged` — the
    /// snapshot was never retried for as long as its content stayed the same.
    /// Forgetting the digests of the files whose publication failed makes the
    /// next pass rewrite and republish exactly those files.
    private func forgetSnapshotDigests(for filenames: Set<String>) {
        guard !filenames.isEmpty else { return }
        for filename in filenames {
            snapshotFileDigests.removeValue(forKey: filename)
        }
        saveSnapshotDigests()
    }

    /// The hard ceiling on published transcripts. Each one is bounded to 80
    /// rows of at most 6,000 characters (`compactTranscriptMessages`), so the
    /// worst case stays a small snapshot file.
    static let transcriptSnapshotSessionCeiling = 16

    /// The byte budget for the `.chat` snapshot group, measured on the encoded
    /// `chat_transcripts.json` payload.
    ///
    /// 2026-09-06: the count ceiling alone is not a size bound. Sixteen
    /// sessions of eighty 6,000-character rows encode far past the transport's
    /// contract (`NAMobileSnapshotStatusCodec`: 8 MiB uncompressed, 800 KiB for
    /// the published status value), and breaching either throws — which fails
    /// the WHOLE chat publication, so the phone gets no transcript for ANY
    /// session instead of a smaller set. Budget under the contract, publish
    /// newest-first until it is spent, and let the omitted sessions read as
    /// "History not synced" on the phone.
    ///
    /// Sized against what the codec really produces, not against the raw file:
    /// the payload carries the file base64-expanded (×4/3), and zlib over
    /// base64 text recovers only ~6×, so the 800 KiB status cap is the binding
    /// half. Measured on hard-to-compress prose, a 3 MiB file already reaches
    /// 682 KiB of status value and a 4 MiB one breaches it. 2 MiB lands near
    /// 455 KiB — headroom for content that compresses worse, and still every
    /// transcript in any ordinary chat.
    static let chatTranscriptGroupByteBudget = 2 * 1024 * 1024

    private func chatTranscriptSnapshots(for sessions: [ChatSession], api: NativeClient) async -> [ChatTranscriptSnapshot] {
        var out: [ChatTranscriptSnapshot] = []
        var retained: [String: ChatTranscriptBlock] = [:]
        // The array framing the blocks ride in: "[" + "]".
        var used = 2
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        // 2026-09-06: the selection above is already bounded by
        // `transcriptSnapshotSessionCeiling` and knows which rows are mains and
        // which are pins. The flat `prefix(8)` that used to live here did not,
        // so it dropped pinned sessions the phone could still select.
        for session in sessions {
            let block: ChatTranscriptBlock
            // 2026-09-06: a transcript only changes when its generation moves,
            // so reuse the block published for that generation instead of
            // re-reading history. Without this every completion edge cost up to
            // sixteen sequential history reads to republish fifteen unchanged
            // transcripts.
            if let generation = session.transcriptGeneration,
               let cached = chatTranscriptBlockCache[session.id],
               cached.generation == generation {
                block = cached
            } else {
                guard let messages = try? await api.getChatMessages(sessionId: session.id) else { continue }
                let snapshot = ChatTranscriptSnapshot(
                    sessionId: session.id,
                    messages: compactTranscriptMessages(messages),
                    transcriptGeneration: session.transcriptGeneration
                )
                // An unencodable block is treated as unaffordable rather than
                // free, so it can never be the one that breaches the contract.
                let encodedBytes = (try? encoder.encode(snapshot))?.count
                    ?? Self.chatTranscriptGroupByteBudget
                block = ChatTranscriptBlock(
                    generation: session.transcriptGeneration,
                    snapshot: snapshot,
                    encodedBytes: encodedBytes
                )
            }
            // Each block after the first also carries its separating comma.
            let cost = block.encodedBytes + (out.isEmpty ? 0 : 1)
            guard used + cost <= Self.chatTranscriptGroupByteBudget else { break }
            used += cost
            out.append(block.snapshot)
            if block.generation != nil {
                retained[session.id] = block
            }
        }
        // Only what was published this pass stays cached, so the cache is bound
        // by the same budget the file is.
        chatTranscriptBlockCache = retained
        // 2026-09-06: the version above came from the session list read BEFORE
        // these transcripts. A write landing in between shipped newer bytes
        // under an older counter, and the phone orders published transcripts by
        // that counter — so the genuinely newer publish that followed looked no
        // newer and was refused. Read the counter a second time now that every
        // transcript is in hand: a session whose counter did not move was not
        // written during the whole window, so its bytes and its version are the
        // same state. Anything that moved is dropped from THIS pass — the write
        // that moved it publishes a consistent pair on the next one.
        //
        // 2026-09-06: a session MISSING from the reread is not a match. The map
        // used to omit both a row that had vanished and a legacy row carrying
        // no counter, and `nil == nil` passed the filter for both — so a
        // session whose index row was removed mid-pass still shipped. Absence
        // now means "the row moved": drop it. A row that is present but has no
        // counter (an older Mac build) still publishes, exactly as before.
        guard let generationsAfter = Self.currentTranscriptGenerations() else { return out }
        return out.filter { snapshot in
            guard let after = generationsAfter[snapshot.sessionId] else { return false }
            return after == snapshot.transcriptGeneration
        }
    }

    /// The transcript version each session's index row carries right now, or nil
    /// when the index could not be read (in which case the caller keeps today's
    /// behaviour rather than publishing nothing).
    ///
    /// EVERY row present in the index gets an entry, with a nil value for a row
    /// that carries no counter — a missing KEY therefore means the row itself
    /// is gone, which is not the same answer as "this row has no counter".
    private nonisolated static func currentTranscriptGenerations() -> [String: Int?]? {
        let path = NativeAgentPaths.dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard let rows = try? ChatSessionIndexFile.loadObjectRowsForMutation(at: path) else {
            return nil
        }
        var out: [String: Int?] = [:]
        for row in rows {
            guard case .string(let id)? = row["id"] else { continue }
            out.updateValue(
                ChatSessionIndexFile.transcriptGeneration(in: row).map { Int(clamping: $0) },
                forKey: id
            )
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

    func writeSnapshotData(
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

    /// Digest keys whose snapshot file is present in `dir`. Pure, so the
    /// retire-a-snapshot lifecycle (file removed, digest must go too) is pinned
    /// without driving the engine.
    nonisolated static func digestsPrunedToExistingFiles(_ digests: [String: String], in dir: URL) -> [String: String] {
        digests.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.key).path) }
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
            let projection = try MobileInboxProjection.data(
                from: items,
                encoder: enc,
                alreadyNewestFirst: true
            )
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
            return .built(try await Self.retryingCancelledGroupRead("knowledge_graph") {
                try await NativeClient.canonicalKnowledgeGraphSnapshotData()
            })
        } catch {
            NSLog(
                "[MacSyncEngine] canonical knowledge graph unreadable — keeping last good snapshot: %@",
                String(describing: error)
            )
            return .skipped("knowledge graph unreadable: \(error.localizedDescription)")
        }
    }

    func organismLivingStatusSnapshot() async -> OrganismLivingStatusFile {
        Self.organismLivingStatusSnapshot(from: await organismSnapshotProvider())
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
            },
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
    func turnSummariesSnapshotData(
        sourceRoot: URL? = nil,
        now: Date = Date()
    ) async -> Data? {
        let root = sourceRoot ?? stateDataRootOverride ?? TurnSummarySource.liveRoot()
        return await Task.detached(priority: .utility) { () -> Data? in
            let events = TurnSummarySource.loadEvents(root: root, now: now)
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
    /// Sweep 2026-09-01 item 2: the phone's Memory and Knowledge Graph screens
    /// held yesterday's rows because those two group reads lost a race and threw
    /// `Swift.CancellationError` — a lost race, not a decision, and the pass
    /// recorded a durable skip on the first one.
    nonisolated static func snapshotReadWasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain.contains("CancellationError")
    }

    /// Read a snapshot group, retrying EXACTLY once when the first attempt was
    /// cancelled while this pass itself is still live. A pass that is genuinely
    /// cancelled retries nothing — the second read would fail identically and
    /// the caller must still record the skip.
    static func retryingCancelledGroupRead<T>(
        _ label: String,
        _ read: () async throws -> T
    ) async throws -> T {
        do {
            return try await read()
        } catch {
            guard snapshotReadWasCancelled(error), !Task.isCancelled else { throw error }
            NSLog(
                "[MacSyncEngine] snapshot group %@ read was cancelled — retrying once before calling the phone stale",
                label
            )
            return try await read()
        }
    }

    /// The staleness marker the phone renders per screen.
    ///
    /// `snapshot_skips.json` is LOCAL Mac bookkeeping (Doctor reads it), so a
    /// skipped group was invisible on the device that was showing the stale
    /// rows. This publishes the same group→reason map into the snapshot bundle
    /// iOS already decodes.
    ///
    /// Deliberately carries NO timestamp: the file's digest drives snapshot
    /// publication, and a per-pass timestamp would wake the phone with a
    /// changed core group on every single tick. A healthy pass publishes `{}`
    /// rather than deleting the file, because the phone's CloudKit cache only
    /// ever gains files — a deleted marker would badge Memory as stale forever.
    nonisolated static let snapshotStalenessFilename = "snapshot_staleness.json"

    nonisolated static func snapshotStalenessMarkerData(
        unresolvedGroups: [String: String]
    ) -> Data? {
        let groups = unresolvedGroups.filter { !$0.key.hasPrefix("_") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(groups)
    }

    /// Reconcile one pass with durable stale-state truth. A lightweight pass
    /// must not clear a heavyweight group's prior failure merely because that
    /// group was not attempted. Successfully attempted groups are cleared;
    /// current failures replace their prior reason.
    @discardableResult
    nonisolated static func updateSnapshotSkipState(
        currentSkips: [String: String],
        attemptedGroups: Set<String>,
        dataRoot: URL
    ) -> [String: String] {
        let url = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
        var unresolved: [String: String] = [:]
        if let data = try? Data(contentsOf: url),
           let prior = try? JSONDecoder().decode([String: String].self, from: data) {
            unresolved = prior.filter { $0.key != "_observedAt" }
        }
        for group in attemptedGroups { unresolved.removeValue(forKey: group) }
        for (group, reason) in currentSkips where group != "_observedAt" {
            unresolved[group] = reason
        }
        persistSnapshotSkipState(unresolved, dataRoot: dataRoot)
        return unresolved
    }

    /// Full replacement helper retained for isolated callers and tests.
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
