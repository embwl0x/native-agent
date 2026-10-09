// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: every N seconds writes app-owned Swift runtime state to iCloud Drive `snapshots/`.
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
import CognitiveSubstrate
import KnowledgeGraph
import MemoryV2
import MacIntegration
import ApprovalInbox
import NotificationInbox
import PersistenceCore
import Desk
import Transcripts
import ProviderRouting

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

public struct MobileToolCatalogRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String?
    public var status: String?
    public var description: String?
    public var autoRun: Bool?
    public var riskClass: String?
    public var updatedAt: String?

    public init(
        id: String, name: String, kind: String?, status: String?, description: String?,
        autoRun: Bool?, riskClass: String?, updatedAt: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.description = description
        self.autoRun = autoRun
        self.riskClass = riskClass
        self.updatedAt = updatedAt
    }
}

/// One non-main executor for all snapshot CPU work, including bridge envelopes.
/// Jobs are synchronous within this actor: no suspension can interleave builds.
/// The engine retains ownership of demand, lifecycle fences and publication.
actor MobileSnapshotBuilder {
    static let shared = MobileSnapshotBuilder()

    func build<Value: Sendable>(_ operation: @Sendable () throws -> Value) rethrows -> Value {
        try operation()
    }

    func encode<Value: Encodable & Sendable>(_ value: Value) throws -> Data {
        try Self.encoder().encode(value)
    }

    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    func inbox(_ items: [InboxItemRecord]) throws -> (data: Data, included: Int) {
        try MobileInboxProjection.data(from: items, encoder: Self.encoder(), alreadyNewestFirst: true)
    }

    func desk(_ items: [DeskItem], executions: Data?) throws -> (data: Data, included: Int) {
        let evidence = try executions.map { try JSONDecoder().decode([DeskExecutionEvidence].self, from: $0) }
        return try MobileDeskProjection.data(from: items, evidence: evidence ?? [], encoder: Self.encoder())
    }

    func deskReadingCopies(_ items: [DeskItem]) throws -> (data: Data, included: Int) {
        try MobileDeskReadingCopyProjection.data(from: items, encoder: Self.encoder())
    }

    func status(group: NAMobileSnapshotGroup, directory: URL) throws -> String? {
        var files: [String: Data] = [:]
        for filename in group.filenames {
            let url = directory.appendingPathComponent(filename)
            // Missing is optional; unreadable must fail and retain retry demand.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            files[filename] = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        guard !files.isEmpty else { return nil }
        do {
            return try NAMobileSnapshotStatusCodec.encode(group: group, files: files)
        } catch DeviceSyncError.payloadTooLarge {
            // 2026-09-13: every file of a group shares ONE status envelope, so
            // a file that is merely a reading convenience could take the whole
            // group down with it — legitimately large Desk notes made the
            // reading copies big enough that desk.json, the board the phone
            // actually navigates by, stopped publishing. Shed the trimmable
            // files and publish the rest. A dropped file is simply absent from
            // this envelope: the phone keeps whatever copy it already has, and
            // those copies carry their own capturedAt, so nothing starts
            // claiming to be fresher than it is.
            for filename in group.trimmableFilenames {
                // Never shed the last file: an empty set is not a publishable
                // group, and the caller is owed the size failure, not a
                // different one.
                guard files.count > 1, files.removeValue(forKey: filename) != nil else { continue }
                nativeLog(
                    "[MacSyncEngine] mobile snapshot %@ exceeded the status envelope — trimmed %@ so the rest still publishes",
                    group.rawValue,
                    filename
                )
                if let value = try? NAMobileSnapshotStatusCodec.encode(group: group, files: files) {
                    return value
                }
            }
            // Nothing trimmable left: the authoritative rows themselves do not
            // fit, which is a real publication failure and keeps retry demand.
            return try NAMobileSnapshotStatusCodec.encode(group: group, files: files)
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
    static let maximumRows = MobileDeskProjectionBounds.maximumRows
    static let maximumNotesPerItem = 5
    static let maximumEncodedBytes = 512 * 1024

    static func data(from items: [DeskItem], evidence: [DeskExecutionEvidence], encoder: JSONEncoder) throws -> (data: Data, included: Int) {
        let latest = Dictionary(grouping: evidence.filter { $0.deskHandle != nil }, by: { $0.deskHandle! })
            .compactMapValues { $0.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") } }
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
                summary: item.summary.map {
                    MobileDeskProjectionBounds.clipped(
                        $0, to: MobileDeskProjectionBounds.maximumSummaryCharacters)
                },
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
                    MobileDeskNote(
                        timestamp: $0.ts,
                        text: MobileDeskProjectionBounds.clipped(
                            $0.text, to: MobileDeskProjectionBounds.maximumNoteCharacters))
                },
                executionEvidence: latest[item.handle]
            )
        }
        return try MobileProjectionEncoder.largestPrefix(
            of: records,
            maximumEncodedBytes: maximumEncodedBytes,
            encoder: encoder
        )
    }
}

/// Complete reading copies of the few Desk items worth having in a pocket. The
/// compact board (`desk.json`) is unchanged and still carries every row; this
/// rides beside it and carries the UNCLIPPED text of the items you are most
/// likely to open away from the Mac — the ones waiting on you, the pinned
/// active ones, and then the most recently touched ones. Priority order is also
/// the encoding order, so the size bound drops the least-wanted copies first.
enum MobileDeskReadingCopyProjection {
    static let maximumItems = 25
    static let maximumNotesPerItem = 60
    /// Half the compact board's bound, because the two travel together: the
    /// .desk group packs desk.json, desk_bounds.json and this file into a
    /// single 800 KiB status envelope. At 512 KiB each, an ordinary pair of
    /// full files left the envelope no margin at all; at 256 KiB the copies
    /// still carry ~10 KiB per item, which is a long note, not a clipped one.
    static let maximumEncodedBytes = 256 * 1024
    /// Generous per-string ceilings. These exist so one pathological item
    /// cannot consume the whole file, not to clip ordinary reading material.
    static let maximumTextCharacters = 20_000

    static func priorityRank(requiresOwnerInput: Bool, pinned: Bool) -> Int {
        if requiresOwnerInput { return 0 }
        if pinned { return 1 }
        return 2
    }

    static func data(from items: [DeskItem], encoder: JSONEncoder) throws -> (data: Data, included: Int) {
        let records = items
            .filter { !$0.status.isTerminal }
            .sorted { lhs, rhs in
                let lhsRank = priorityRank(requiresOwnerInput: lhs.requiresOwnerInput, pinned: lhs.pinned)
                let rhsRank = priorityRank(requiresOwnerInput: rhs.requiresOwnerInput, pinned: rhs.pinned)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.handle < rhs.handle
            }
            .prefix(maximumItems)
            .map { item in
                MobileDeskItemReadingCopy(
                    handle: item.handle,
                    // The source timestamp of the copy, so the phone can say how
                    // old this reading material is rather than imply it is live.
                    capturedAt: item.updatedAt,
                    summary: item.summary.map { String($0.prefix(maximumTextCharacters)) },
                    blockedReason: item.blockedReason.map { String($0.prefix(maximumTextCharacters)) },
                    notes: item.notes.suffix(maximumNotesPerItem).map {
                        MobileDeskNote(
                            timestamp: $0.ts,
                            text: String($0.text.prefix(maximumTextCharacters))
                        )
                    }
                )
            }
        return try MobileProjectionEncoder.largestPrefix(
            of: Array(records),
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

    public enum SnapshotWriteScope: Sendable {
        case standard
        case chatSessions
    }

    // MARK: - Snapshot writer
    // 2026-05-09 / 2026-05-31: trust_policy.json is the raw checked policy's
    // bytes (engine.trust.snapshotData()), not a re-encode of the typed model,
    // so keys the Mac model does not name still reach the phone. iOS decodes
    // the raw JSON with lenient, fully-optional structs so the failure mode
    // is "field missing in UI", not "snapshot file disappears".

    public func writeSnapshots(
        forceHeavy: Bool = false,
        includeMemories: Bool = false,
        includeChatTranscripts: Bool = false,
        scope: SnapshotWriteScope = .standard
    ) async {
        guard isActive, let snapshotDir else { return }
        requestWorkActivityPublication()
        if snapshotWriteInFlight {
            snapshotWriteQueued = true
            snapshotWriteQueuedNeedsHeavy = snapshotWriteQueuedNeedsHeavy || forceHeavy
            snapshotWriteQueuedNeedsMemories = snapshotWriteQueuedNeedsMemories || includeMemories
            snapshotWriteQueuedNeedsChatTranscripts =
                snapshotWriteQueuedNeedsChatTranscripts || includeChatTranscripts
            snapshotWriteQueuedNeedsStandardPass =
                snapshotWriteQueuedNeedsStandardPass || scope == .standard
            return
        }
        let lifecycleGeneration = snapshotLifecycleGeneration
        snapshotWriteInFlight = true
        defer {
            snapshotWriteInFlight = false
            if isActive, snapshotWriteQueued {
                snapshotWriteQueued = false
                let queuedForceHeavy = snapshotWriteQueuedNeedsHeavy
                let queuedIncludeMemories = snapshotWriteQueuedNeedsMemories
                let queuedIncludeChatTranscripts = snapshotWriteQueuedNeedsChatTranscripts
                let queuedScope: SnapshotWriteScope = snapshotWriteQueuedNeedsStandardPass
                    ? .standard
                    : .chatSessions
                snapshotWriteQueuedNeedsHeavy = false
                snapshotWriteQueuedNeedsMemories = false
                snapshotWriteQueuedNeedsChatTranscripts = false
                snapshotWriteQueuedNeedsStandardPass = false
                Task { @MainActor in
                    await self.writeSnapshots(
                        forceHeavy: queuedForceHeavy,
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
        let memories = includeMemories || snapshotWriteQueuedNeedsMemories
        let transcripts = includeChatTranscripts || snapshotWriteQueuedNeedsChatTranscripts
        let mergedScope: SnapshotWriteScope = scope == .standard || snapshotWriteQueuedNeedsStandardPass
            ? .standard : .chatSessions
        snapshotWriteQueued = false
        snapshotWriteQueuedNeedsHeavy = false
        snapshotWriteQueuedNeedsMemories = false
        snapshotWriteQueuedNeedsChatTranscripts = false
        snapshotWriteQueuedNeedsStandardPass = false
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

        do {
            // Fire lightweight freshness fetches. Full inventory/readout
            // snapshots are force-triggered so the idle timer does not rebuild
            // provider catalogs, turn summaries, chat transcripts, KG, etc.
            async let executionsTask = api.getWorkshopExecutions()
            async let sessionsTask = api.getChatSessions()
            async let healthTask = api.getHealth()
            async let memProposalsTask = api.pendingMemoryProposals()
            async let trainingTask = api.getTrainingProposals()
            async let promotionTask = api.getPromotionPending()
            async let organismTask = self.organismLivingStatusSnapshot()
            async let overviewTask = api.workOverview()

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
                nativeLog("[MacSyncEngine] snapshot fetch failed for %@ — keeping last good file: %@", label, "\(error)")
            }
            // Sweep R4 item 2: groups the native helpers could not build. Same
            // publish behavior as before (keep last good), but the group is now
            // NAMED — in syncError and in the durable skip file Doctor reads —
            // so "iPhone is showing stale approvals" stops being invisible.
            func recordGroupSkip(_ label: String, _ reason: String) {
                attemptedSnapshotGroups.insert(label)
                skippedSnapshotGroups[label] = reason
                snapshotFetchFailures.append("\(label): \(reason)")
                nativeLog("[MacSyncEngine] snapshot group %@ SKIPPED — keeping last good file: %@", label, reason)
            }

            var executions: DeviceSyncSnapshotRows?
            do { executions = try await executionsTask } catch { recordFetchFailure("workshop_tasks", error) }
            var skills: DeviceSyncSnapshotRows?
            var memories: [MemoryRecord]?
            var connectors: DeviceSyncSnapshotRows?
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
            var training: DeviceSyncSnapshotRows?
            do { training = try await trainingTask } catch { recordFetchFailure("training_proposals", error) }
            var promotion: DeviceSyncSnapshotRows?
            do { promotion = try await promotionTask } catch { recordFetchFailure("promotion_candidates", error) }
            var organismLivingStatus = await organismTask
            // One Desk read per pass: the overview and desk.json come from the
            // same board. needsUser is the overview's Needs you, the number
            // every Mac surface shows. The needs-you push runs off the app's
            // own overview read (DeviceSync.evaluateNeedsUser), not this pass.
            let (overview, deskItems) = await overviewTask
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
            var providers: DeviceSyncSnapshotRows?
            if includeHeavySnapshots {
                do { skills = try await api.getSkills() } catch { recordFetchFailure("skills_snapshot", error) }
            }
            if includeHeavySnapshots || includeMemories {
                do {
                    memories = try await Self.retryingCancelledGroupRead("memories") {
                        try await api.activeMemories().map(MemoryRecord.init(phoneRow:))
                    }
                } catch { recordFetchFailure("memories", error) }
            }
            if includeHeavySnapshots {
                do { connectors = try await api.getConnectors() } catch { recordFetchFailure("connectors", error) }
                do { toolCatalog = try await api.mobileToolCatalog() } catch {
                    recordFetchFailure("tools_snapshot", error)
                }
                // PATCH-2026-05-07: leftover-1 providers.json snapshot so iOS reads provider state.
                // This can refresh provider catalogs, so keep it out of the idle timer.
                do { providers = try await api.providers() } catch { recordFetchFailure("providers", error) }
            }

            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
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
                    changedSnapshotFilenames.insert(filename)
                case .failed(let reason):
                    recordGroupSkip(group, "write failed: \(reason)")
                case .unchanged:
                    break
                }
            }

            func write<T: Encodable & Sendable>(_ value: T, to filename: String) async {
                do {
                    await writeData(try await encodeSnapshot(value), to: filename)
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

            await publish(await helpersSnapshotData(), as: "helpers_agents", to: "helpers_agents.json")
            await write(overview, to: "work_overview.json")
            if let executions {
                await write(executions, to: "workshop_tasks.json")
                do { try projectWorkshopWorkActivities(try await encodeSnapshot(executions)) }
                catch { recordFetchFailure("work_activity", error) }
                try? FileManager.default.removeItem(
                    at: snapshotDir.appendingPathComponent("missions.json")
                )
            }
            if let deskItems {
                do {
                    var executionData: Data?
                    if let executions { executionData = try await encodeSnapshot(executions) }
                    let projection = try await MobileSnapshotBuilder.shared.desk(deskItems, executions: executionData)
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
            await publish(await schedulerSnapshotData(), as: "scheduler", to: "scheduler.json")
            if let skills { await write(skills, to: "skills_snapshot.json") }
            if let toolCatalog { await write(toolCatalog, to: "tools_snapshot.json") }
            if let memories { await write(memories, to: "memories.json") }
            // PATCH-2026-05-09: trust ships the raw policy bytes, not the typed
            // model: iOS decodes with its own lenient struct.
            async let trustData = try? api.trustSnapshotData()
            // R25 (2026-07-02): personality now has a native loader —
            // NativeClient.getPersonality() returns the SHARED PersonalityProfile
            // iOS decodes, so the daemon-era `{}` stub is gone. Nil-skip on
            // fetch failure (sync-audit #1: never replace last-good with
            // fabricated state).
            async let personalityFetch: PersonalityProfile? = {
                do { return try await api.getPersonality() } catch {
                    nativeLog("[MacSyncEngine] snapshot fetch failed for personality — keeping last good file: %@", "\(error)")
                    return nil
                }
            }()
            async let approvalsData: SnapshotGroupBuild = self.nativeApprovalsSnapshotData()
            async let inboxData: SnapshotGroupBuild = self.nativeInboxSnapshotData()
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
            do {
                let permissions = try await MacIntegrationPermissionStore.shared.currentChecked()
                var projection: [String: [String: Bool]] = [:]
                for id in MacIntegrationID.all {
                    guard let permission = permissions[id] else { continue }
                    var axes: [String: Bool] = [:]
                    if MacIntegrationID.supportsRead(id) { axes["read"] = permission.read }
                    if MacIntegrationID.supportsWrite(id) { axes["write"] = permission.write }
                    projection[id] = axes
                }
                await write(projection, to: "mac_integration_permissions.json")
            } catch {
                recordFetchFailure("mac_integration_permissions", error)
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
                        nativeLog("[MacSyncEngine] runs ledger unreadable — keeping last good runs.json")
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
                                return data
                            }
                            if bounded.count <= 1 {
                                nativeLog("[MacSyncEngine] runs.json over byte budget even at 1 run — skipping write")
                                break
                            }
                            bounded = Array(bounded.prefix(bounded.count / 2))
                        }
                        return nil
                    }
                    if let runsData { await writeData(runsData, to: "runs.json") }
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
            await publish(await telegramSnapshotData(), as: "telegram", to: "telegram.json")
            await write(organismLivingStatus, to: Self.organismLivingStatusSnapshotFilename)
            if let memProposals { await write(memProposals, to: "memory_proposals.json") }
            if let training { await write(training, to: "training_proposals.json") }
            if let promotion { await write(promotion, to: "promotion_candidates.json") }
            if let providers { await write(providers, to: "providers.json") }
            await write(api.providerSignInStates(), to: "provider_sign_ins.json")

            // 2026-06-05 picker-sync: publish the resolved per-surface model
            // preferences so iOS chat-box + iOS providers-panel can show the
            // SAME model the Mac picker shows, and so the iOS chat-box can
            // hydrate from the Mac's surfaces.json instead of carrying its
            // own stale @AppStorage cache. Shape: { surface: { model,
            // reasoningEffort } } — flat-string variants are tolerated by
            // the iOS reader for back-compat.
            if includeHeavySnapshots {
                await publish(
                    await self.modelPreferencesSnapshotData(),
                    as: "model_preferences",
                    to: "model_preferences.json"
                )
            }

            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            lastSnapshotAt = Date()
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
            // Publish before recording skips: a group that did not reach the
            // phone is stale exactly like one that did not build, and is named
            // with its reason in the skip state Doctor reads and the marker the
            // phone's stale badge reads.
            if !changedSnapshotFilenames.isEmpty {
                let failed = await publishChangedSnapshots(
                    changedSnapshotFilenames,
                    in: snapshotDir,
                    lifecycleGeneration: lifecycleGeneration,
                    scope: .standard
                )
                guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
                skippedSnapshotGroups.merge(Self.publishFailureSkips(failed, changed: changedSnapshotFilenames)) { _, publish in publish }
            }
            // fix-2026-06-10 sync-audit #1: surface skipped-fetch errors instead
            // of clearing them — the snapshot files themselves kept last-good data.
            // Sweep R4 item 2: lead with the SKIPPED GROUP NAMES, because that
            // is what tells the owner which iPhone surface is stale.
            let currentSkips = skippedSnapshotGroups
            let attemptedGroups = attemptedSnapshotGroups
            let unresolvedSnapshotGroups = await MobileSnapshotBuilder.shared.build {
                Self.updateSnapshotSkipState(
                    currentSkips: currentSkips, attemptedGroups: attemptedGroups,
                    dataRoot: PersistenceCore.defaultDataRoot()
                )
            }
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            // Sweep 2026-09-01 item 2: the skip record above is LOCAL. Publish
            // the same per-group truth into the bundle so the phone's Memory
            // and Knowledge Graph screens can say they are holding old rows
            // instead of rendering them as current.
            changedSnapshotFilenames = []
            if let stalenessMarker = await MobileSnapshotBuilder.shared.build({
                Self.snapshotStalenessMarkerData(unresolvedGroups: unresolvedSnapshotGroups)
            }) {
                await writeData(stalenessMarker, to: Self.snapshotStalenessFilename)
            }
            if snapshotFetchFailures.isEmpty, unresolvedSnapshotGroups.isEmpty {
                syncError = nil
            } else {
                let messages = NAMobileSnapshotGroup.stalenessMessages(unresolvedSnapshotGroups)
                syncError = messages.keys.sorted().first.flatMap { messages[$0] }
                    ?? "iPhone updates could not be prepared. The last received data is still available. Open Connection in Settings to check the Mac link."
            }
            // The marker changed: it rides in .core, published on its own.
            if !changedSnapshotFilenames.isEmpty {
                await publishChangedSnapshots(
                    changedSnapshotFilenames,
                    in: snapshotDir,
                    lifecycleGeneration: lifecycleGeneration,
                    scope: .standard
                )
            }

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
        let api = sync.host
        let sessions: [ChatSession]
        do {
            sessions = try await api.getChatSessions()
        } catch {
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            syncError = "Chat session snapshot failed; the last proven phone sessions were retained: \(error.localizedDescription)"
            await sync.host.retryRequestedResults()
            return
        }
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }

        let pinnedSessions = pinnedChatSessions(from: sessions)
        var changedFilenames = Set<String>()
        var writeFailures: [String] = []

        func write<T: Encodable & Sendable>(_ value: T, filename: String) async {
            guard lifecycleGeneration == snapshotLifecycleGeneration,
                  isActive,
                  let data = try? await encodeSnapshot(value) else { return }
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
        if !changedFilenames.isEmpty {
            let failed = await publishChangedSnapshots(
                changedFilenames,
                in: snapshotDir,
                lifecycleGeneration: lifecycleGeneration,
                scope: .chatSessions,
                clearErrorOnSuccess: writeFailures.isEmpty
            )
            guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return }
            // What this pass rebuilt and delivered is current again; a group
            // that did not publish is named with its reason.
            let failures = Self.publishFailureSkips(failed, changed: changedFilenames)
            let delivered = Set(changedFilenames.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
                .subtracting(failures.keys)
            _ = await MobileSnapshotBuilder.shared.build {
                Self.updateSnapshotSkipState(currentSkips: failures, attemptedGroups: delivered,
                                             dataRoot: PersistenceCore.defaultDataRoot())
            }
        }
        await sync.host.retryRequestedResults()
    }

    /// Both scopes publish, invalidate failed digests, signal legacy transport,
    /// then checkpoint. Only a successful chat-only pass clears an earlier error.
    /// Returns each group that did not publish, with why.
    @discardableResult
    func publishChangedSnapshots(
        _ changedFilenames: Set<String>,
        in snapshotDir: URL,
        lifecycleGeneration: UInt64,
        scope: SnapshotWriteScope,
        clearErrorOnSuccess: Bool = false
    ) async -> [NAMobileSnapshotGroup: DeviceSyncError] {
        let groups = NAMobileSnapshotGroup.groups(containingAny: changedFilenames)
        let failures = await sync.bridge.publishMobileSnapshotStatus(
            groups: groups,
            snapshotDirectory: snapshotDir,
            shouldPublish: { self.snapshotLifecycleGeneration == lifecycleGeneration && self.isActive }
        ) ?? [:]
        guard lifecycleGeneration == snapshotLifecycleGeneration, isActive else { return [:] }
        if !failures.isEmpty {
            let messages = NAMobileSnapshotGroup.stalenessMessages(Self.publishFailureSkips(failures, changed: changedFilenames))
            syncError = messages.keys.sorted().first.flatMap { messages[$0] }
            forgetSnapshotDigests(for: changedFilenames)
        } else if clearErrorOnSuccess {
            syncError = nil
        }
        if !sync.bridge.usesCloudKitDeviceTransport {
            let timeoutLabel = switch scope {
            case .standard: "MacSyncEngine.writeSnapshots.kvsSignal"
            case .chatSessions: "MacSyncEngine.writeChatSessionSnapshots.kvsSignal"
            }
            let signaled = await signalSnapshotGroups(groups, timeoutLabel: timeoutLabel)
            if signaled != true {
                syncError = "iPhone updates could not be delivered. The last received data is still available. The Mac will try again on its next update; keep NativeAgent open."
            }
        }
        saveSnapshotDigests()
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

    /// Only real pins belong in the phone's closable pinned tabs. Main has its
    /// own identity and other conversations remain available through history.
    private func pinnedChatSessionIds() -> [String] {
        sync.host.pinnedChatSessionIDs()
    }

    /// The phone's main chat follows the conversation User is in — the anchor
    /// every door publishes when he sends — not the Mac window.
    private func chatAnchorSnapshot() -> ConversationAnchorPin? {
        ConversationAnchor.current(dataRoot: sync.dataRoot)
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
        // The conversation User is in always rides first, whatever its source.
        let currentID = chatAnchorSnapshot()?.sessionId
        append(sessions.first { $0.id == currentID })
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
        // Keep recent history available after main advances, within the same
        // transcript count and byte budgets as the existing snapshot. Agent
        // bridge and bot chats ride only as the anchor or a pin — they were
        // filling half the window ahead of User's own conversations.
        for session in sessions.sorted(by: { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }) {
            guard out.count < Self.transcriptSnapshotSessionCeiling else { break }
            guard !["agent-bridge", "bot"].contains((session.source ?? "").lowercased()) else { continue }
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
    nonisolated static let transcriptSnapshotRowLimit = 80

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
    /// This raw-byte bound also limits compilation work. The completed
    /// candidate is checked against the actual status codec below because
    /// compression ratios cannot guarantee the 800 KiB transport limit.
    static let chatTranscriptGroupByteBudget = 2 * 1024 * 1024

    private func chatTranscriptSnapshots(for sessions: [ChatSession], api: any DeviceSyncHost) async -> [ChatTranscriptSnapshot] {
        var out: [ChatTranscriptSnapshot] = []
        var retained: [String: ChatTranscriptBlock] = [:]
        // The array framing the blocks ride in: "[" + "]".
        var used = 2
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
                    messages: await MobileSnapshotBuilder.shared.build { Self.compactTranscriptMessages(messages) },
                    transcriptGeneration: session.transcriptGeneration,
                    hasOlder: messages.count > Self.transcriptSnapshotRowLimit
                )
                // An unencodable block is treated as unaffordable rather than
                // free, so it can never be the one that breaches the contract.
                let encodedBytes = (try? await MobileSnapshotBuilder.shared.encode(snapshot))?.count
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
        if let generationsAfter = Self.currentTranscriptGenerations() {
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

    /// The transcript version each session's index row carries right now, or nil
    /// when the index could not be read (in which case the caller keeps today's
    /// behaviour rather than publishing nothing).
    ///
    /// EVERY row present in the index gets an entry, with a nil value for a row
    /// that carries no counter — a missing KEY therefore means the row itself
    /// is gone, which is not the same answer as "this row has no counter".
    private nonisolated static func currentTranscriptGenerations() -> [String: Int?]? {
        let path = PersistenceCore.defaultDataRoot()
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

    private nonisolated static func compactTranscriptMessages(
        _ messages: [any DeviceSyncTranscriptMessage & Sendable]
    ) -> [DeviceSyncTranscriptRow] {
        messages.suffix(transcriptSnapshotRowLimit).map { message in
            var copy = message
            copy.content = Self.truncateTranscriptContent(copy.content)
            return DeviceSyncTranscriptRow(message: copy)
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
        // A retiring write may have replaced bytes covered by a saved digest.
        // Invalidate that skip before admitting the restarted pass.
        guard expectedLifecycleGeneration == snapshotLifecycleGeneration,
              isActive else {
            snapshotFileDigests.removeValue(forKey: filename)
            saveSnapshotDigests()
            return .unchanged
        }
        if let writeError {
            syncError = "Snapshot write failed for \(filename): \(writeError)"
            return .failed(writeError)
        }
        snapshotFileDigests[filename] = digest
        return .changed
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
        func encoded(_ count: Int) -> Data? {
            let kept = Set(newestFirst.prefix(count))
            return try? JSONSerialization.data(withJSONObject: rows.indices.filter(kept.contains).map { rows[$0] },
                                               options: [.sortedKeys])
        }
        var low = 0, high = rows.count - 1
        var best = encoded(0) ?? Data("[]".utf8)
        while low < high {
            let mid = (low + high + 1) / 2
            if let candidate = encoded(mid), candidate.count <= maxBytes { low = mid; best = candidate } else { high = mid - 1 }
        }
        return (best, rows.count - low)
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
    private func nativeApprovalsSnapshotData() async -> SnapshotGroupBuild {
        let approvals: [ApprovalRequest]
        do { approvals = try await sync.host.approvals() } catch {
            return .skipped("approval store unreadable: \(error.localizedDescription)")
        }
        do { return .built(try await MobileSnapshotBuilder.shared.encode(approvals)) } catch {
            return .skipped("approvals could not be encoded: \(error.localizedDescription)")
        }
    }

    private func nativeInboxSnapshotData() async -> SnapshotGroupBuild {
        let items: [InboxItemRecord]
        do { items = try await sync.host.inboxItems() } catch {
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
        let snapshot = await organismSnapshotProvider()
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
                // Reflexes were retired in Phase 5 F; the shared file keeps
                // its fields so an older iPhone build still decodes it.
                reflexCandidates: 0,
                reflexesNeedReview: 0,
                approvedReflexBiases: nil,
                standingViewProposals: snapshot.dreamRepairSummary.proposedStandingViews
            ),
            reflexCandidates: nil,
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
        await sync.host.turnSummariesSnapshotData(root: sourceRoot ?? stateDataRootOverride, now: now)
    }

    /// 2026-06-05 picker-sync: encode the picker's resolved per-surface
    /// model preferences as JSON for iOS to pull. Shape:
    /// Each surface includes model, providerId, and optional reasoningEffort/serviceTier.
    /// Empty surfaces are omitted so iOS doesn't render rows the Mac can't
    /// honor. Returns nil only when the picker call itself throws — a stub
    /// `{}` would silently let iOS overwrite the Mac with empty state, so
    /// nil-skip is safer.
    private func modelPreferencesSnapshotData() async -> SnapshotGroupBuild {
        // UI and mobile snapshots expose the same recovered preferences as
        // execution. Damaged existing authority is unavailable, not a
        // successful empty projection that replaces the phone's last-good one.
        let routing: ProviderRoutingSnapshot
        do { routing = try await SwiftNativeProviderRouting(dataRoot: sync.dataRoot).checkedRoutingSnapshot() } catch {
            return .skipped("model preferences unreadable: \(error.localizedDescription)")
        }
        return await MobileSnapshotBuilder.shared.build {
            var out: [String: [String: String]] = [:]
            for (surface, preference) in routing.preferences {
                let model = preference.model
                guard !surface.isEmpty, !model.isEmpty else { continue }
                var row: [String: String] = ["model": model]
                if let provider = routing.activeProviders[surface] { row["providerId"] = provider }
                let effort = preference.reasoningEffort
                if !effort.isEmpty { row["reasoningEffort"] = effort }
                if !preference.serviceTier.isEmpty { row["serviceTier"] = preference.serviceTier }
                out[surface] = row
            }
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            do { return .built(try enc.encode(out)) } catch {
                return .skipped("model preferences could not be encoded: \(error.localizedDescription)")
            }
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
            nativeLog(
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
        var groups = unresolvedGroups.filter { !$0.key.hasPrefix("_") }
        for (group, message) in NAMobileSnapshotGroup.stalenessMessages(unresolvedGroups) {
            groups["_message.\(group)"] = message
        }
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
        for group in attemptedGroups {
            unresolved.removeValue(forKey: group)
            unresolved.removeValue(forKey: "_message.\(group)")
        }
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
            nativeLog("[MacSyncEngine] could not record snapshot skip state: %@", error.localizedDescription)
        }
    }
}

/// Sweep R4 item 2: the outcome of building ONE iOS snapshot group.
///
/// `.skipped` keeps the publish behavior identical to the old `nil` — the file
/// is not rewritten, so the phone keeps the last good copy — while carrying the
/// reason out so the pass can name the stale group in `syncError` and in the
/// durable state Doctor reads.
enum SnapshotGroupBuild: Sendable {
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

private extension MemoryRecord {
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
