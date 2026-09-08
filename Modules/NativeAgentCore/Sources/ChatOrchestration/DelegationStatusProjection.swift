import Foundation
import PersistenceCore

/// Process-local read acceleration only. The ledger remains authoritative.
/// One lock covers stamp validation, append reads and publication across tool
/// observations and the outcome loop. Terminal projections have no clock input.
final class DelegationDeliveryCache: @unchecked Sendable {
    struct Snapshot {
        var byID: [String: DelegationJobProjection] = [:]
        var ordered: [DelegationJobProjection] = []
        var deliveredIDs: Set<String> = []
        var availability = DelegationSourceAvailability(source: "codex_deliveries", agent: "codex")
    }
    private struct Stamp: Equatable {
        let inode: UInt64
        let device: UInt64
        let modified: Date
        let created: Date
        let size: UInt64
        let permissions: UInt16

        init(_ url: URL) throws {
            let a = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            guard a[.type] as? FileAttributeType == .typeRegular,
                  let inode = a[.systemFileNumber] as? NSNumber,
                  let device = a[.systemNumber] as? NSNumber,
                  let modified = a[.modificationDate] as? Date,
                  let created = a[.creationDate] as? Date,
                  let size = a[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
            self.inode = inode.uint64Value; self.device = device.uint64Value
            self.modified = modified; self.created = created; self.size = size.uint64Value
            self.permissions = (a[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        }

        func sameFile(as other: Stamp) -> Bool {
            inode == other.inode && device == other.device && created == other.created
        }
    }
    private struct Entry {
        var stamp: Stamp
        var offset: UInt64 = 0
        var committed = Snapshot()
        var visible = Snapshot()
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var decodeCount = 0
    var decodedLineCount: Int { lock.lock(); defer { lock.unlock() }; return decodeCount }

    func read(_ url: URL) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let key = url.standardizedFileURL.path
        do {
            let stamp = try Stamp(url)
            if let entry = entries[key], entry.stamp == stamp { return entry.visible }
            var entry: Entry
            if let previous = entries[key], stamp.sameFile(as: previous.stamp), stamp.size > previous.stamp.size {
                entry = previous
            } else {
                entry = Entry(stamp: stamp)
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try file.seek(toOffset: entry.offset)
            let data = try file.readToEnd() ?? Data()
            // A moving/replaced file is unavailable for this observation. Never
            // publish a mixed generation or advance its cursor.
            guard try Stamp(url) == stamp, UInt64(data.count) == stamp.size - entry.offset else {
                throw CocoaError(.fileReadUnknown)
            }
            let completeEnd = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            for line in data[..<completeEnd].split(separator: 0x0A) {
                consume(Data(line), into: &entry.committed)
            }
            entry.offset += UInt64(completeEnd - data.startIndex)
            entry.visible = entry.committed
            // Preserve legacy files with a final JSON object but no newline.
            // This suffix is provisional: a later append re-reads it from the
            // last complete-line offset, without double-counting malformed rows.
            if completeEnd < data.endIndex { consume(Data(data[completeEnd...]), into: &entry.visible) }
            entry.visible.ordered = entry.visible.byID.values.sorted(by: DelegationStatusProjector.newestFirst)
            if entry.visible.availability.malformedRecords > 0 { entry.visible.availability.status = "partial" }
            entry.stamp = stamp
            entries[key] = entry
            return entry.visible
        } catch {
            entries.removeValue(forKey: key)
            var result = Snapshot()
            let error = error as NSError
            let absent = error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
            result.availability.status = absent ? "absent" : "unavailable"
            result.availability.unreadableFiles = absent ? 0 : 1
            return result
        }
    }

    private func consume(_ line: Data, into snapshot: inout Snapshot) {
        guard !line.allSatisfy({ [0x20, 0x09, 0x0D].contains($0) }) else { return }
        decodeCount += 1
        guard let parsed = try? JSONValue.parse(line), case .object(let object) = parsed,
              case .array(let ids)? = object["messageIds"], ids.contains(where: {
                  if case .string(let id) = $0 { return !id.isEmpty }; return false
              }) else {
            snapshot.availability.malformedRecords += 1
            return
        }
        snapshot.availability.readableRecords += 1
        for row in DelegationStatusProjector.projectCodexDeliveries(now: .distantPast, objects: [object]) {
            snapshot.byID[row.id] = row
            if row.deliveryOutcome == "delivered" { snapshot.deliveredIDs.insert(row.id) }
        }
    }
}

// MARK: - Delegation status projection (W2, upgrade campaign 2026-08 Track A)
//
// THE PROBLEM this closes: Agent delegates repo work to Claude (Claude Code)
// and Codex via the thread-wakeup bridges, but between "enqueued" and the
// terminal completion event she was BLIND. The whole job lifecycle is already
// durably on disk as JSON — she just had no Swift reader for it, so she
// computed deadlines by hand and filed stuck-job reports that the job files
// themselves refuted.
//
// This file is the read-only projection over the supported bridge stores. It is
// deliberately a pure value transform: directory URLs and the clock are
// INJECTED, so the tests are hermetic and never touch the live ~/.config.
//
// ── PREMISE VERIFICATION (2026-08-11, read from the JS writers, not assumed) ──
// The stores do NOT share a record shape. That mattered enough to write down,
// because the naive assumption (one field set, several directories) would
// have produced a projection that silently reports `null` for every codex job.
//
// Claude — script/claude_thread_wakeup.js
//   dir:   ~/.config/claude-bridge/wake-jobs/*.json   (WAKE_JOBS_DIR, L35)
//   claim: O_EXCL create per messageId (claimJob, L422) — the file IS the
//          dedup marker, so records survive past completion.
//   shape: messageId, createdAt, claimedAt, startedAt, deadlineAt,
//          heartbeatAt (runner liveness), progressAt/progressCpuMs (CHILD
//          liveness — deliberately distinct, L1372), state, status, runStatus,
//          runReason, completedAt, deliveryLost, completionText, stallSeconds,
//          timeoutSeconds, topicSlug, pid, bridgeStatus, commitPolicy.
//
// Codex — script/codex_thread_wakeup.js
//   dir:   ~/.config/codex-nativeagent-bridge/reply-jobs/*.json  (L26-27)
//          plus the `undelivered/` subdirectory and sibling
//          `reply-deliveries.jsonl`. A delivered job is unlinked
//          (finalizeReplyJobFile), but the delivery ledger durably preserves
//          its originating messageIds, terminal turn result, and bridge
//          receipt. An undeliverable job is preserved under `undelivered/`.
//   shape: id, phase, createdAt, threadId, turnId, clientUserMessageId,
//          entries[].payload.topic, boundAt, lastWait.observedAt,
//          completedExecution.turnResult{status, completedAt, message, ...}.
//   MISSING vs claude: no startedAt, no deadlineAt, no stallSeconds, no
//          heartbeat. So `stalled` is NOT COMPUTABLE for codex jobs — we say
//          so via `stall_basis: "none"` rather than reporting a confident
//          `false` that reads like "verified healthy".
//
// OMP — script/omp_thread_wakeup.js
//   dir:   ~/.config/omp-bridge/wake-jobs/*.json
//   shape: messageId, payload.topic, state, status, createdAt, startedAt,
//          lastActivityAt, updatedAt, completedAt, bridge.status, and retained
//          completionText/reply/stderrTail.
//
// The wire fence holds: nothing here writes, and neither JS helper is touched.

/// One job's projected lifecycle, normalized across the bridge stores.
/// Every timestamp is the RAW string from the record (already ISO-8601 from
/// both writers) — we never reformat, so a malformed legacy value round-trips
/// visibly instead of silently becoming `null`.
public struct DelegationJobProjection: Sendable, Equatable {
    public enum StallBasis: String, Sendable {
        /// `now` is past the runner's own recorded `deadlineAt`.
        case deadline
        /// Liveness went quiet for longer than the record's `stallSeconds`.
        case stallSeconds = "stall_seconds"
        /// Terminal record — a settled job cannot be stalled.
        case terminal
        /// The record carries neither a deadline nor a stall threshold.
        /// `stalled` is reported false but that is ABSENCE OF EVIDENCE.
        case none
        /// 2026-09-06: the run ended (`state: delivering`) and no settlement
        /// followed within the delivery grace. The runner writes `delivering`
        /// BEFORE it awaits the bridge POST, so a worker that dies there leaves
        /// a record that says the run is over and never settles.
        case deliveryStall = "delivery_stall"
    }

    public var id: String
    /// Exact identity returned to the dispatching turn and therefore used by
    /// the shared motor lifecycle. Codex has a separate internal reply-job id;
    /// keeping both prevents its terminal projection from closing a different
    /// action than the one dispatch opened.
    public var motorOwnerID: String? = nil
    /// Read-only lookup identities, independent of the single motor owner.
    /// A batched Codex reply job may contain several accepted messages.
    var acceptedMessageIDs: Set<String> = []
    var recordedThreadID: String? = nil
    var recordedTurnID: String? = nil
    /// Which bridge store this row came from: "claude" | "codex" | "omp".
    public var source: String
    /// The agent that runs the job. Currently 1:1 with `source`, kept separate
    /// because the claude store is also where a future third runner would land.
    public var agent: String
    public var topicSlug: String?
    /// Exact stable Desk item bound at dispatch, never inferred from prose.
    public var deskHandle: String?
    public var state: String?
    public var status: String?
    public var runStatus: String?
    public var createdAt: String?
    public var claimedAt: String?
    public var startedAt: String?
    /// max(heartbeatAt, progressAt) for claude; lastWait.observedAt for codex.
    public var lastLiveness: String?
    public var completedAt: String?
    /// Wall-clock seconds from the earliest known start (startedAt ?? claimedAt
    /// ?? createdAt) to completedAt, or to `now` while the job is still open.
    /// nil when no start timestamp exists at all (legacy record).
    public var elapsedSeconds: Int?
    public var stalled: Bool
    public var stallBasis: StallBasis
    /// Only set when the record ITSELF asserts it (claude's `deliveryLost`
    /// field). Never inferred — see `deliveryOutcome`.
    public var deliveryLost: Bool?
    /// Coarse delivery disposition: "delivered" | "lost" | "unknown" | "blocked".
    ///
    /// The distinction is load-bearing. On the codex side a job preserved
    /// under `undelivered/` is NOT proven lost — replyJobDisposition
    /// (`replyJobDisposition` in codex_thread_wakeup.js) preserves there exactly when
    /// replyStatus is `outcome_unknown` or `conflict`, i.e. the bridge could
    /// not confirm either way. Reporting those as lost would invent a fact,
    /// which is the precise failure this tool exists to stop.
    public var deliveryOutcome: String?
    /// Allowlisted machine reason only; never raw helper errors or prose.
    public var deliveryReason: String? = nil
    /// First 200 characters of the completion text, when the record carries it.
    ///
    /// Absent on most claude rows BY DESIGN: the runner nulls completionText
    /// once delivery succeeds (claude_thread_wakeup.js L1551) and only retains
    /// it when the text still needs replaying. Its absence means "delivered",
    /// not "missing".
    public var completionTextHead: String?
    /// Read-only recovery evidence. A later receipt is not an automatic replay
    /// authorization or proof that a different completion was consumed.
    public var recoveryNote: String? = nil
    /// Contract/build identity stamped by the NativeAgent runtime that
    /// originated this wake. Absence means a legacy/unversioned producer.
    public var producerSchemaVersion: Int? = nil
    public var producerSourceRevision: String? = nil

    /// Newest-first ordering key: the most recent timestamp the record proves.
    var recencyKey: Date?
    /// Exact future crossing at which this open record's existing liveness
    /// rule becomes stalled. Internal scheduling evidence only; the public
    /// JSON continues to expose the verdict and basis, not another workflow
    /// field.
    var stallDeadline: Date?

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "source": .string(source),
            "agent": .string(agent),
            "stalled": .bool(stalled),
            "stall_basis": .string(stallBasis.rawValue),
        ]
        // Absent fields are OMITTED, not emitted as null: an older record that
        // predates a field should read as "this record doesn't say", and an
        // explicit null in the envelope invites the model to narrate it as a
        // finding.
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        put("topic_slug", topicSlug)
        put("motor_owner_id", motorOwnerID)
        put("desk_handle", deskHandle)
        put("state", state)
        put("status", status)
        put("run_status", runStatus)
        put("created_at", createdAt)
        put("claimed_at", claimedAt)
        put("started_at", startedAt)
        put("last_liveness", lastLiveness)
        put("completed_at", completedAt)
        put("completion_text_head", completionTextHead)
        put("recovery_note", recoveryNote)
        put("thread_id", recordedThreadID)
        put("turn_id", recordedTurnID)
        obj["accepted_message_ids"] = .array(acceptedMessageIDs.sorted().map(JSONValue.string))
        put("delivery_outcome", deliveryOutcome)
        put("delivery_reason", deliveryReason)
        put("producer_source_revision", producerSourceRevision)
        if let producerSchemaVersion {
            obj["producer_schema_version"] = .int(Int64(producerSchemaVersion))
        }
        if let elapsedSeconds { obj["elapsed_seconds"] = .int(Int64(elapsedSeconds)) }
        if let deliveryLost { obj["delivery_lost"] = .bool(deliveryLost) }
        return .object(obj)
    }

    /// Provider-facing status row for ordinary progress checks. Lifecycle
    /// truth stays intact while low-value duplicate provenance/timestamps are
    /// reserved for `detail=full`.
    public func toCompactJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "agent": .string(agent),
            "stalled": .bool(stalled),
            "stall_basis": .string(stallBasis.rawValue),
        ]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { obj[key] = .string(value) }
        }
        put("topic_slug", topicSlug)
        put("motor_owner_id", motorOwnerID)
        put("desk_handle", deskHandle)
        put("state", state)
        put("status", status)
        put("run_status", runStatus)
        put("last_liveness", lastLiveness)
        put("completed_at", completedAt)
        put("completion_text_head", completionTextHead)
        put("delivery_outcome", deliveryOutcome)
        put("delivery_reason", deliveryReason)
        if let elapsedSeconds { obj["elapsed_seconds"] = .int(Int64(elapsedSeconds)) }
        return .object(obj)
    }
}

struct DelegationSourceAvailability: Sendable {
    let source: String
    let agent: String
    var status = "available"
    var readableRecords = 0
    var malformedRecords = 0
    var unreadableFiles = 0

    var json: JSONValue {
        .object(["source": .string(source), "agent": .string(agent), "status": .string(status),
                 "readable_records": .int(Int64(readableRecords)), "malformed_records": .int(Int64(malformedRecords)),
                 "unreadable_files": .int(Int64(unreadableFiles))])
    }
}

struct DelegationStatusReadSnapshot: Sendable {
    let jobs: [DelegationJobProjection]
    let sources: [DelegationSourceAvailability]
    let matchedCount: Int
}

/// Pure, injectable reader over the three wake-job stores.
public struct DelegationStatusProjector: Sendable {
    /// Default: `~/.config/claude-bridge/wake-jobs`.
    public var claudeJobsDirectory: URL
    /// Default: `~/.config/codex-nativeagent-bridge/reply-jobs`.
    public var codexJobsDirectory: URL
    /// Default: `~/.config/codex-nativeagent-bridge/reply-deliveries.jsonl`.
    /// This is the terminal half of the Codex lifecycle after successful jobs
    /// leave `reply-jobs/`.
    public var codexDeliveriesFile: URL
    /// Default: `~/.config/omp-bridge/wake-jobs`.
    public var ompJobsDirectory: URL

    public static let completionTextHeadLimit = 200
    public static let defaultLimit = 20
    public static let maxLimit = 100

    /// `configRoot` mirrors `SwiftToolDispatcher.agentBridgeConfigRoot`: the
    /// stand-in for `~/.config`, which is what makes the tests hermetic.
    public init(configRoot: URL? = nil) {
        let root = configRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        self.claudeJobsDirectory = root
            .appendingPathComponent("claude-bridge", isDirectory: true)
            .appendingPathComponent("wake-jobs", isDirectory: true)
        self.codexJobsDirectory = root
            .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
            .appendingPathComponent("reply-jobs", isDirectory: true)
        self.codexDeliveriesFile = root
            .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
            .appendingPathComponent("reply-deliveries.jsonl")
        self.ompJobsDirectory = root
            .appendingPathComponent("omp-bridge", isDirectory: true)
            .appendingPathComponent("wake-jobs", isDirectory: true)
    }

    public init(
        claudeJobsDirectory: URL,
        codexJobsDirectory: URL,
        codexDeliveriesFile: URL? = nil,
        ompJobsDirectory: URL? = nil
    ) {
        self.claudeJobsDirectory = claudeJobsDirectory
        self.codexJobsDirectory = codexJobsDirectory
        self.codexDeliveriesFile = codexDeliveriesFile ?? codexJobsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("reply-deliveries.jsonl")
        self.ompJobsDirectory = ompJobsDirectory ?? codexJobsDirectory
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("omp-bridge/wake-jobs", isDirectory: true)
    }

    /// Read all supported stores and return the newest `limit` jobs, newest first.
    /// Unreadable/absent directories contribute zero rows rather than failing
    /// the whole call — a machine with only one bridge configured still gets a
    /// useful answer.
    public func recentJobs(now: Date, limit: Int = DelegationStatusProjector.defaultLimit) -> [DelegationJobProjection] {
        let bounded = max(1, min(limit, Self.maxLimit))
        return readSnapshot(now: now, limit: bounded).jobs
    }

    /// Item 5 (2026-09-02): the jobs AND whether every configured store
    /// actually answered, from ONE read of disk.
    ///
    /// `recentJobs` cannot express this. It swallows absent and unreadable
    /// stores alike so that "a machine with only one bridge configured still
    /// gets a useful answer" — which is right for a display, and wrong for any
    /// caller that reads an EMPTY result as a fact about the world. The horizon
    /// register is such a caller: a peer disappearing from the pending set means
    /// "they wrote back", so a bridge directory that briefly could not be read
    /// would otherwise mint relief for a reply that never came.
    ///
    /// `allStoresReadable` is true when every source is either `available` or
    /// `absent`. Absent is deliberately fine: a bridge that is not configured on
    /// this machine is not a failed read, it is a peer she does not have. Only
    /// `unavailable` (present but unreadable) and `partial` (some records
    /// unreadable or malformed) make the answer untrustworthy.
    public func recentJobsWithAvailability(
        now: Date,
        limit: Int = DelegationStatusProjector.defaultLimit
    ) -> (jobs: [DelegationJobProjection], allStoresReadable: Bool) {
        let bounded = max(1, min(limit, Self.maxLimit))
        let snapshot = readSnapshot(now: now, limit: bounded)
        return (
            Array(snapshot.jobs.prefix(bounded)),
            snapshot.sources.allSatisfy { $0.status == "available" || $0.status == "absent" }
        )
    }

    /// Complete ordered projection for reconciliation owners. This is
    /// deliberately separate from `recentJobs`: the latter is a model-visible
    /// display budget, while a durable outcome cursor must never skip an older
    /// record merely because more than 100 newer jobs arrived in one burst.
    public func allJobs(now: Date) -> [DelegationJobProjection] {
        readSnapshot(now: now).jobs
    }

    /// 2026-09-06: `allJobs` for a cursor owner, PLUS whether the read was
    /// complete. An unreadable job file simply vanishes from the array, and a
    /// cursor that advances its `last_seen` past that job while a newer sibling
    /// settles rejects it forever once it becomes readable again. The
    /// reconciliation owner needs the same availability half `delegation_status`
    /// already gets from `recentJobsWithAvailability`, from ONE read of disk.
    public func allJobsWithAvailability(
        now: Date
    ) -> (jobs: [DelegationJobProjection], allStoresReadable: Bool) {
        let snapshot = readSnapshot(now: now)
        return (
            snapshot.jobs,
            snapshot.sources.allSatisfy { $0.status == "available" || $0.status == "absent" }
        )
    }

    /// Read each source once. Availability describes this same observation,
    /// while the historical array APIs still return every readable job.
    func readSnapshot(now: Date, limit: Int? = nil, offset: Int = 0,
                      agent: String? = nil, messageID: String? = nil) -> DelegationStatusReadSnapshot {
        var rows: [DelegationJobProjection] = []
        var sources: [DelegationSourceAvailability] = []
        let claude = Self.readDirectory(claudeJobsDirectory, source: "claude_jobs", agent: "claude")
        sources.append(claude.availability)
        for (url, object) in claude.objects {
            if let row = Self.projectClaude(url: url, now: now, object: object) { rows.append(row) }
        }
        var codexRows: [String: DelegationJobProjection] = [:]
        for (directory, source, undelivered) in [
            (codexJobsDirectory, "codex_jobs", false),
            (codexJobsDirectory.appendingPathComponent("undelivered", isDirectory: true), "codex_undelivered", true),
        ] {
            let read = Self.readDirectory(directory, source: source, agent: "codex")
            sources.append(read.availability)
            for (url, object) in read.objects {
                if let row = Self.projectCodex(url: url, undelivered: undelivered, now: now, object: object) {
                    codexRows[row.id] = row
                }
            }
        }
        // Successful delivery removes the reply-job file. The durable ledger
        // is therefore not optional history: it is the canonical terminal half
        // of the same lifecycle. A proven delivered receipt outranks a stale
        // in-flight projection for the same originating message id.
        let deliveries = Self.deliveryCache.read(codexDeliveriesFile)
        sources.append(deliveries.availability)
        for key in Array(codexRows.keys) {
            guard var retained = codexRows[key], retained.deliveryOutcome == "unknown" else { continue }
            let ids = retained.acceptedMessageIDs.intersection(deliveries.deliveredIDs).sorted()
            retained.recoveryNote = ids.isEmpty
                ? "No later delivered receipt matched the retained accepted-message IDs in readable evidence. Inspect the original reply before deciding; absence is not proof of loss."
                : "Delivered receipt(s) also reference accepted message ID(s): \(ids.joined(separator: ", ")). Compare thread/turn identity and completion before treating this retained reply as consumed; no replay or deletion performed."
            codexRows[key] = retained
        }
        for key in Array(codexRows.keys) {
            guard let receipt = deliveries.byID[key] else { continue }
            if codexRows[key]?.deliveryOutcome != "unknown" || receipt.deliveryOutcome == "delivered"
                || deliveries.deliveredIDs.contains(key) {
                codexRows.removeValue(forKey: key)
            }
        }
        rows.append(contentsOf: codexRows.values)
        let omp = Self.readDirectory(ompJobsDirectory, source: "omp_jobs", agent: "omp")
        sources.append(omp.availability)
        for (url, object) in omp.objects {
            if let row = Self.projectOMP(url: url, now: now, object: object) { rows.append(row) }
        }
        func matches(_ row: DelegationJobProjection) -> Bool {
            (agent == nil || row.agent == agent) && (messageID == nil || row.acceptedMessageIDs.contains(messageID!))
        }
        rows = rows.filter(matches)
        var matchedCount = rows.count
        // Cached terminal rows are already ordered. Only retain enough candidates
        // for this page; full reconciliation deliberately retains every receipt.
        let capacity = limit.map { offset > Int.max - $0 ? Int.max : offset + $0 } ?? Int.max
        if agent == nil || agent == "codex" {
            if let messageID {
                if let row = deliveries.byID[messageID], codexRows[row.id] == nil, matches(row) {
                    matchedCount += 1
                    rows.append(row)
                }
            } else {
                matchedCount += deliveries.byID.count - codexRows.keys.filter { deliveries.byID[$0] != nil }.count
                var selected = 0
                for row in deliveries.ordered where codexRows[row.id] == nil {
                    if selected >= capacity { break }
                    rows.append(row)
                    selected += 1
                }
            }
        }
        rows.sort(by: Self.newestFirst)
        let page = Array(rows.dropFirst(min(offset, rows.count)).prefix(limit ?? rows.count))
        return DelegationStatusReadSnapshot(jobs: page, sources: sources, matchedCount: matchedCount)
    }

    fileprivate static func newestFirst(_ lhs: DelegationJobProjection, _ rhs: DelegationJobProjection) -> Bool {
        switch (lhs.recencyKey, rhs.recencyKey) {
        case let (l?, r?) where l != r: return l > r
        case (nil, .some): return false
        case (.some, nil): return true
        default: return lhs.id > rhs.id
        }
    }

    private static let deliveryCache = DelegationDeliveryCache()

    /// Earliest future crossing of the same deadline/stall-seconds rules used
    /// by `stalled`. File events trigger immediate rereads while work moves;
    /// this exact deadline is what makes a writer that goes quiet observable
    /// without adding a polling heartbeat.
    public func nextStallDeadline(after now: Date) -> Date? {
        allJobs(now: now)
            .compactMap(\.stallDeadline)
            .filter { $0 > now }
            .min()
    }

    // MARK: - Directory scanning

    /// Only an initial missing-path error means absent. A later read failure
    /// or a wrong file kind is unavailable, never an empty healthy source.
    private static func sourceStatus(_ url: URL, expected: FileAttributeType) -> String {
        do {
            // Existing reads follow configured symlinks; availability is not
            // a new path/authority restriction on those readable sources.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            return attributes[.type] as? FileAttributeType == expected ? "available" : "unavailable"
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
                ? "absent" : "unavailable"
        }
    }

    private static func readDirectory(_ directory: URL, source: String, agent: String)
        -> (objects: [(URL, [String: JSONValue])], availability: DelegationSourceAvailability) {
        var availability = DelegationSourceAvailability(source: source, agent: agent)
        availability.status = sourceStatus(directory, expected: .typeDirectory)
        guard availability.status == "available" else { return ([], availability) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch { availability.status = "unavailable"; return ([], availability) }
        var objects: [(URL, [String: JSONValue])] = []
        for name in names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted() {
            let url = directory.appendingPathComponent(name)
            guard sourceStatus(url, expected: .typeRegular) == "available", let data = try? Data(contentsOf: url) else {
                availability.unreadableFiles += 1
                continue
            }
            guard let parsed = try? JSONValue.parse(data), case .object(let object) = parsed else {
                availability.malformedRecords += 1
                continue
            }
            availability.readableRecords += 1
            objects.append((url, object))
        }
        if availability.unreadableFiles > 0 || availability.malformedRecords > 0 { availability.status = "partial" }
        return (objects, availability)
    }

    // MARK: - Claude projection

    static func projectClaude(url: URL, now: Date, object job: [String: JSONValue]) -> DelegationJobProjection? {
        // messageId is the claude record's identity (it is also the filename
        // stem). Fall back to the stem so a record that lost the field still
        // shows up addressable rather than being dropped.
        let id = string(job, "messageId") ?? url.deletingPathExtension().lastPathComponent
        let createdAt = string(job, "createdAt")
        let claimedAt = string(job, "claimedAt")
        let startedAt = string(job, "startedAt")
        let completedAt = string(job, "completedAt")
        // heartbeatAt proves the RUNNER is alive; progressAt proves the CHILD
        // is. Either one is liveness, so the projection takes the later.
        let liveness = laterISO(string(job, "heartbeatAt"), string(job, "progressAt"))

        let start = firstDate(startedAt, claimedAt, createdAt)
        let end = date(completedAt) ?? now
        let elapsed = start.map { Int(max(0, end.timeIntervalSince($0)).rounded()) }

        // A stall verdict is about a RUN that stopped making progress. The run
        // is over the moment the runner stamps runStatus — `delivering`
        // (L1457) and `spawn_failed` (L2222) both sit past that point with no
        // completedAt yet, and both carry a deadlineAt that will eventually
        // pass, so neither may be judged against the RUN's deadline: a job that
        // finished an hour ago and is merely waiting on bridge delivery would
        // read as STALLED, the exact false stuck-job report this tool exists to
        // prevent. `spawn_failed` is terminal outright; `delivering` keeps a
        // stall clock of its own, below.
        let state = string(job, "state")
        // 2026-09-06: `delivering` is no longer counted as terminal. The run IS
        // over there, but the answer is still in flight, and the runner writes
        // that state before it awaits the bridge POST — so a worker that dies
        // in the POST leaves a record excluded from stall detection forever.
        // Its clock is the delivery stamp (`runEndedAt`), never the run's own
        // `deadlineAt`, which a long run has usually passed already: an
        // ordinary delivery of a few seconds cannot trip it, and one that never
        // lands does.
        let delivering = completedAt == nil && state == "delivering"
        let terminal = !delivering && (completedAt != nil
            || string(job, "runStatus") != nil
            || ["settled", "spawn_failed"].contains(state ?? ""))
        let stalled: Bool
        let basis: DelegationJobProjection.StallBasis
        let stallDeadline: Date?
        if delivering {
            let clock = firstDate(string(job, "runEndedAt"), liveness, startedAt, claimedAt, createdAt)
            let deadline = clock?.addingTimeInterval(deliveryStallSeconds)
            stalled = deadline.map { now >= $0 } ?? false
            basis = deadline == nil ? .none : .deliveryStall
            stallDeadline = deadline
        } else {
            (stalled, basis, stallDeadline) = stallVerdict(
                terminal: terminal,
                deadlineAt: string(job, "deadlineAt"),
                stallSeconds: number(job, "stallSeconds"),
                lastLiveness: liveness ?? startedAt ?? claimedAt ?? createdAt,
                now: now
            )
        }

        var row = DelegationJobProjection(
            id: id,
            motorOwnerID: id,
            source: "claude",
            agent: "claude",
            topicSlug: string(job, "topicSlug"),
            deskHandle: nestedString(job, objectKey: "payload", field: "deskHandle"),
            state: state,
            status: string(job, "status"),
            runStatus: string(job, "runStatus"),
            createdAt: createdAt,
            claimedAt: claimedAt,
            startedAt: startedAt,
            lastLiveness: liveness,
            completedAt: completedAt,
            elapsedSeconds: elapsed,
            stalled: stalled,
            stallBasis: basis,
            deliveryLost: bool(job, "deliveryLost"),
            deliveryOutcome: claudeDeliveryOutcome(job),
            completionTextHead: head(string(job, "completionText")),
            producerSchemaVersion: nestedInt(job, objectKey: "payload", field: "producerSchemaVersion"),
            producerSourceRevision: nestedString(job, objectKey: "payload", field: "producerSourceRevision"),
            stallDeadline: stallDeadline
        )
        row.recencyKey = firstDate(completedAt, liveness, startedAt, claimedAt, createdAt)
        row.acceptedMessageIDs = Set([Self.recordedLookupID(job["messageId"])].compactMap { $0 })
        if row.deliveryOutcome == "blocked", string(job, "bridgeReason") == "missing_origin_session" {
            row.deliveryReason = "missing_origin_session"
        }
        return row
    }

    // MARK: - Codex projection

    static func projectCodex(url: URL, undelivered: Bool, now: Date, object job: [String: JSONValue]) -> DelegationJobProjection? {
        let id = string(job, "id") ?? url.deletingPathExtension().lastPathComponent
        let createdAt = string(job, "createdAt")
        // boundAt is when the watcher bound this job to a live turn — the
        // closest analogue the codex record has to claude's claimedAt.
        let claimedAt = string(job, "boundAt")

        var turnResult: [String: JSONValue] = [:]
        if case .object(let exec)? = job["completedExecution"], case .object(let tr)? = exec["turnResult"] {
            turnResult = tr
        }
        let completedAt = string(turnResult, "completedAt")
        let runStatus = string(turnResult, "status")

        // lastWait is rewritten on every bounded wait interval that did NOT
        // observe a terminal turn — i.e. it is exactly a liveness beacon.
        var liveness: String?
        if case .object(let wait)? = job["lastWait"] { liveness = string(wait, "observedAt") }

        let start = firstDate(claimedAt, createdAt)
        let end = date(completedAt) ?? now
        let elapsed = start.map { Int(max(0, end.timeIntervalSince($0)).rounded()) }

        // The codex record carries NO deadline and NO stall threshold, so a
        // stall verdict here would be invented. Terminal jobs still resolve.
        let terminal = completedAt != nil || !turnResult.isEmpty
        let (stalled, basis, stallDeadline) = stallVerdict(
            terminal: terminal, deadlineAt: nil, stallSeconds: nil, lastLiveness: liveness, now: now
        )
        var recordedDeliveryStatus: String?
        var recordedDeliveryOutcome: String?
        if case .object(let delivery)? = job["delivery"] {
            recordedDeliveryStatus = string(delivery, "status")
            recordedDeliveryOutcome = string(delivery, "outcome")
        }
        let deliveryOutcome = recordedDeliveryOutcome ?? (undelivered ? "unknown" : nil)
        let recordedPhase = string(job, "phase")
        let effectiveState: String? = {
            guard terminal else { return recordedPhase }
            switch deliveryOutcome {
            case "delivered": return "settled"
            case "unknown": return "delivery_unknown"
            default:
                // Old records predate the explicit execution/delivery split.
                // Their completedExecution is canonical terminal evidence, so
                // never repeat the stale pre-terminal `watching_turn` label.
                return recordedPhase == "watching_turn" ? "execution_completed" : recordedPhase
            }
        }()

        var row = DelegationJobProjection(
            id: id,
            motorOwnerID: codexSoleMessageID(job),
            source: "codex",
            agent: "codex",
            topicSlug: codexTopicSlug(job),
            deskHandle: codexDeskHandle(job),
            state: effectiveState,
            status: recordedDeliveryStatus,
            runStatus: runStatus,
            createdAt: createdAt,
            claimedAt: claimedAt,
            startedAt: nil,  // codex records no runner start; boundAt is the closest
            lastLiveness: liveness,
            completedAt: completedAt,
            elapsedSeconds: elapsed,
            stalled: stalled,
            stallBasis: basis,
            // The codex record has NO deliveryLost field, and living under
            // undelivered/ does not prove loss — it proves the bridge could
            // not confirm the outcome. So `deliveryLost` stays nil and the
            // disposition is reported as "unknown" instead.
            deliveryLost: nil,
            deliveryOutcome: deliveryOutcome,
            completionTextHead: head(string(turnResult, "message") ?? string(turnResult, "lastAgentMessage")),
            producerSchemaVersion: codexProducerSchemaVersion(job),
            producerSourceRevision: codexProducerSourceRevision(job),
            stallDeadline: stallDeadline
        )
        row.recencyKey = firstDate(completedAt, liveness, claimedAt, createdAt)
        row.acceptedMessageIDs = Set(Self.codexPayloadValues(job, field: "messageId").compactMap { Self.recordedLookupID($0) })
        // A completed execution may belong to a later recovery turn. Keep its
        // recorded pair together instead of mixing it with initial job IDs.
        let identity: [String: JSONValue]
        if case .object(let execution)? = job["completedExecution"] { identity = execution }
        else { identity = job }
        row.recordedThreadID = Self.recordedLookupID(identity["threadId"])
        row.recordedTurnID = Self.recordedLookupID(identity["turnId"])
        return row
    }

    /// Project the durable completion receipt that survives after a successful
    /// Codex reply job is unlinked. One delivery may batch several originating
    /// messages, so each message id receives the same proven terminal result;
    /// this preserves the exact identity emitted at dispatch time.
    static func projectCodexDeliveries(
        now: Date,
        objects: [[String: JSONValue]]
    ) -> [DelegationJobProjection] {
        objects.flatMap { delivery -> [DelegationJobProjection] in
            guard case .array(let rawIDs)? = delivery["messageIds"] else { return [] }
            let ids = rawIDs.compactMap { value -> String? in
                guard case .string(let id) = value, !id.isEmpty else { return nil }
                return id
            }
            guard !ids.isEmpty else { return [] }

            var turnResult: [String: JSONValue] = [:]
            if case .object(let value)? = delivery["turnResult"] { turnResult = value }
            var bridge: [String: JSONValue] = [:]
            if case .object(let value)? = delivery["bridge"] { bridge = value }
            let runStatus = string(turnResult, "status")
            let completedAt = string(turnResult, "completedAt") ?? string(delivery, "createdAt")
            let bridgeStatus = string(bridge, "status")
            let replyStatus = string(bridge, "replyStatus")
            let outcome: String? = switch (bridgeStatus, replyStatus) {
            case ("delivered", _), (_, "ok"): "delivered"
            case ("failed", _), (_, "failed"): "lost"
            case (.some, _), (_, .some): "unknown"
            default: nil
            }
            let effectiveState: String = switch outcome {
            case "delivered": "settled"
            case "lost": "delivery_failed"
            case "unknown": "delivery_unknown"
            default: "execution_completed"
            }
            let completion = string(bridge, "nativeAgentReplyPreview")
                ?? string(turnResult, "messagePreview")
            return ids.map { id in
                var row = DelegationJobProjection(
                    id: id,
                    motorOwnerID: id,
                    source: "codex",
                    agent: "codex",
                    topicSlug: nil,
                    deskHandle: nil,
                    state: effectiveState,
                    status: bridgeStatus ?? replyStatus,
                    runStatus: runStatus,
                    createdAt: nil,
                    claimedAt: nil,
                    startedAt: nil,
                    lastLiveness: nil,
                    completedAt: completedAt,
                    elapsedSeconds: nil,
                    stalled: false,
                    stallBasis: .terminal,
                    deliveryLost: outcome == "lost" ? true : nil,
                    deliveryOutcome: outcome,
                    completionTextHead: head(completion),
                    producerSchemaVersion: nil,
                    producerSourceRevision: nil,
                    stallDeadline: nil
                )
                row.recencyKey = date(completedAt)
                row.acceptedMessageIDs = Set([Self.recordedLookupID(.string(id))].compactMap { $0 })
                row.recordedThreadID = Self.recordedLookupID(delivery["threadId"])
                row.recordedTurnID = Self.recordedLookupID(delivery["turnId"])
                return row
            }
        }
    }

    // MARK: - OMP projection

    /// OMP keeps settled job records, like Claude, but writes the delivery
    /// result as a nested `bridge.status` and the topic inside `payload`.
    static func projectOMP(url: URL, now: Date, object job: [String: JSONValue]) -> DelegationJobProjection? {
        let id = string(job, "messageId") ?? url.deletingPathExtension().lastPathComponent
        let createdAt = string(job, "createdAt")
        let startedAt = string(job, "startedAt")
        let completedAt = string(job, "completedAt")
        let liveness = laterISO(string(job, "lastActivityAt"), string(job, "updatedAt"))
        let start = firstDate(startedAt, createdAt)
        let end = date(completedAt) ?? now
        let elapsed = start.map { Int(max(0, end.timeIntervalSince($0)).rounded()) }
        let state = string(job, "state")
        let status = string(job, "status")
        let terminal = completedAt != nil || state == "settled"
        let (stalled, basis, stallDeadline) = stallVerdict(
            terminal: terminal,
            deadlineAt: nil,
            stallSeconds: number(job, "idleSeconds"),
            lastLiveness: liveness ?? startedAt ?? createdAt,
            now: now
        )
        var payload: [String: JSONValue] = [:]
        if case .object(let value)? = job["payload"] { payload = value }
        var bridge: [String: JSONValue] = [:]
        if case .object(let value)? = job["bridge"] { bridge = value }
        let bridgeStatus = string(bridge, "status")
        let delivery: String? = switch bridgeStatus {
        case "delivered", "dry_run": "delivered"
        case "failed": "lost"
        case "unknown": "unknown"
        case "blocked": "blocked"
        default: nil
        }
        let retained = string(job, "completionText")
            ?? string(job, "reply")
            ?? string(job, "stderrTail")
        var row = DelegationJobProjection(
            id: id,
            motorOwnerID: id,
            source: "omp",
            agent: "omp",
            topicSlug: string(payload, "topic").map(slug),
            deskHandle: string(payload, "deskHandle"),
            state: state,
            status: status,
            runStatus: status,
            createdAt: createdAt,
            claimedAt: nil,
            startedAt: startedAt,
            lastLiveness: liveness,
            completedAt: completedAt,
            elapsedSeconds: elapsed,
            stalled: stalled,
            stallBasis: basis,
            deliveryLost: bridgeStatus == "failed" ? true : nil,
            deliveryOutcome: delivery,
            completionTextHead: head(retained),
            producerSchemaVersion: int(payload, "producerSchemaVersion"),
            producerSourceRevision: string(payload, "producerSourceRevision"),
            stallDeadline: stallDeadline
        )
        row.recencyKey = firstDate(completedAt, liveness, startedAt, createdAt)
        row.acceptedMessageIDs = Set([Self.recordedLookupID(job["messageId"])].compactMap { $0 })
        if delivery == "blocked", string(bridge, "reason") == "missing_origin_session" {
            row.deliveryReason = "missing_origin_session"
        }
        return row
    }

    /// Claude's runner records BOTH an explicit `deliveryLost` boolean and a
    /// `bridgeStatus`. Only those two are consulted — the disposition is never
    /// guessed from the presence or absence of other fields.
    static func claudeDeliveryOutcome(_ job: [String: JSONValue]) -> String? {
        if bool(job, "deliveryLost") == true { return "lost" }
        switch string(job, "bridgeStatus") {
        case "delivered": return "delivered"
        case "unknown": return "unknown"
        case "blocked": return "blocked"
        case .some(let other) where !other.isEmpty: return "unknown"
        default: return nil
        }
    }

    /// Mirrors `topicSlug()` in claude_thread_wakeup.js (L165-172) so a topic
    /// slugs identically on both sides. Returns nil — never the JS writer's
    /// "general" default — when the record carries no topic, because inventing
    /// a topic the record does not contain is fabrication.
    static func codexTopicSlug(_ job: [String: JSONValue]) -> String? {
        guard case .array(let entries)? = job["entries"] else { return nil }
        for entry in entries {
            guard case .object(let e) = entry,
                  case .object(let payload)? = e["payload"],
                  let topic = string(payload, "topic") else { continue }
            let trimmed = slug(topic)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// A reply job can batch entries. One exact originating id is safe to bind
    /// into a single motor projection; a mixed batch remains explicitly
    /// unbound until it is split by the terminal delivery ledger, which lists
    /// every message id separately.
    static func codexSoleMessageID(_ job: [String: JSONValue]) -> String? {
        let ids = Set(codexPayloadValues(job, field: "messageId").compactMap { value -> String? in
            guard case .string(let raw) = value, !raw.isEmpty else { return nil }
            return raw
        })
        return ids.count == 1 ? ids.first : nil
    }

    /// Preserve exact opaque IDs or omit them. Never clip one into a different
    /// handle, infer one from a filename/topic, or serialize the whole batch.
    private static func recordedLookupID(_ value: JSONValue?) -> String? {
        guard case .string(let id)? = value, !id.isEmpty, id.count <= 160 else { return nil }
        return id
    }

    /// A Codex reply job can batch several inbox entries. Bind it to a Desk
    /// item only when every bound entry names the same exact stable handle;
    /// mixed ownership is ambiguous and therefore stays unbound.
    static func codexDeskHandle(_ job: [String: JSONValue]) -> String? {
        guard case .array(let entries)? = job["entries"] else { return nil }
        let handles = Set(entries.compactMap { entry -> String? in
            guard case .object(let object) = entry,
                  case .object(let payload)? = object["payload"] else { return nil }
            return string(payload, "deskHandle")
        })
        return handles.count == 1 ? handles.first : nil
    }

    static func codexProducerSchemaVersion(_ job: [String: JSONValue]) -> Int? {
        codexPayloadValues(job, field: "producerSchemaVersion").compactMap { value in
            switch value {
            case .int(let raw): return Int(raw)
            case .double(let raw): return Int(exactly: raw.rounded(.towardZero))
            case .string(let raw): return Int(raw)
            default: return nil
            }
        }.max()
    }

    static func codexProducerSourceRevision(_ job: [String: JSONValue]) -> String? {
        let revisions: Set<String> = Set(codexPayloadValues(job, field: "producerSourceRevision").compactMap { value -> String? in
            guard case .string(let raw) = value, !raw.isEmpty else { return nil }
            return raw.lowercased()
        })
        return revisions.count == 1 ? revisions.first : nil
    }

    static func codexPayloadValues(_ job: [String: JSONValue], field: String) -> [JSONValue] {
        guard case .array(let entries)? = job["entries"] else { return [] }
        return entries.compactMap { entry in
            guard case .object(let object) = entry,
                  case .object(let payload)? = object["payload"] else { return nil }
            return payload[field]
        }
    }

    static func slug(_ topic: String) -> String {
        let value = String(topic.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(value.prefix(64))
    }

    // MARK: - Shared helpers

    /// How long a finished run may sit in `delivering` before the delivery
    /// itself is the stuck step. The POST is a localhost call with an ack, so
    /// minutes here mean the worker died between the stamp and the settlement.
    ///
    /// 2026-09-06: must stay ABOVE the bridge POST's own ceiling. The helper
    /// allows a delivery 600s (NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_TIMEOUT_MS in
    /// script/claude_thread_wakeup.js), so at 300s this clock called a
    /// supported, still-running delivery stalled. 660s leaves the helper its
    /// full window plus a minute to settle.
    static let deliveryStallSeconds: TimeInterval = 660

    /// The single place a stall verdict is made, for every store.
    static func stallVerdict(
        terminal: Bool,
        deadlineAt: String?,
        stallSeconds: Double?,
        lastLiveness: String?,
        now: Date
    ) -> (Bool, DelegationJobProjection.StallBasis, Date?) {
        if terminal { return (false, .terminal, nil) }
        if let deadline = date(deadlineAt) {
            return (now >= deadline, .deadline, deadline)
        }
        if let stallSeconds, stallSeconds > 0, let last = date(lastLiveness) {
            let deadline = last.addingTimeInterval(stallSeconds)
            return (now >= deadline, .stallSeconds, deadline)
        }
        return (false, .none, nil)
    }

    static func head(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(completionTextHeadLimit))
    }

    static func string(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s.isEmpty ? nil : s }
        return nil
    }

    static func nestedString(
        _ obj: [String: JSONValue], objectKey: String, field: String
    ) -> String? {
        guard case .object(let nested)? = obj[objectKey] else { return nil }
        return string(nested, field)
    }

    static func nestedInt(
        _ obj: [String: JSONValue], objectKey: String, field: String
    ) -> Int? {
        guard case .object(let nested)? = obj[objectKey] else { return nil }
        return int(nested, field)
    }

    static func int(_ obj: [String: JSONValue], _ key: String) -> Int? {
        switch obj[key] {
        case .some(.int(let value)): return Int(value)
        case .some(.double(let value)): return Int(exactly: value.rounded(.towardZero))
        case .some(.string(let value)): return Int(value)
        default: return nil
        }
    }

    static func bool(_ obj: [String: JSONValue], _ key: String) -> Bool? {
        if case .bool(let b)? = obj[key] { return b }
        return nil
    }

    static func number(_ obj: [String: JSONValue], _ key: String) -> Double? {
        switch obj[key] {
        case .some(.int(let i)): return Double(i)
        case .some(.double(let d)): return d
        case .some(.string(let s)): return Double(s)
        default: return nil
        }
    }

    /// Both writers emit `new Date().toISOString()` — fractional-second UTC.
    /// The no-fractional variant is the fallback so a hand-edited or older
    /// record still parses.
    static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso)
    }

    static func laterISO(_ a: String?, _ b: String?) -> String? {
        switch (date(a), date(b)) {
        case let (x?, y?): return x >= y ? a : b
        case (_?, nil): return a
        case (nil, _?): return b
        case (nil, nil): return a ?? b
        }
    }

    static func firstDate(_ candidates: String?...) -> Date? {
        for candidate in candidates {
            if let d = date(candidate) { return d }
        }
        return nil
    }
}
