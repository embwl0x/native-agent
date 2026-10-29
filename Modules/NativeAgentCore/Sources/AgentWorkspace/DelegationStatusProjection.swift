import ChatSessionWork
import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import Darwin
// Blueprint: | `DelegationStatusProjection.swift` | Delegation source inventory and read snapshots; retained facts preserve originating DataRootLife and unknown delivery |

public struct DelegationStatusProjector: Sendable {
    /// Default: `~/.config/claude-bridge/wake-jobs`.
    public var claudeJobsDirectory: URL
    /// Default: `~/.config/codex-nativeagent-bridge/reply-jobs`.
    public var codexJobsDirectory: URL
    /// Default: `~/.config/codex-nativeagent-bridge/reply-deliveries.jsonl`. This is the terminal half of the Codex lifecycle after successful jobs leave `reply-jobs/`.
    public var codexDeliveriesFile: URL
    /// Default: `~/.config/omp-bridge/wake-jobs`.
    public var ompJobsDirectory: URL
    private let dataRoot: URL

    public static let completionTextHeadLimit = 200
    public static let defaultLimit = 20
    public static let maxLimit = 100

    /// Every source read by the projection, including existing jobs updated in place.
    package var watchedPaths: [URL] {
        let directories = [claudeJobsDirectory, codexJobsDirectory, codexJobsDirectory.appendingPathComponent("undelivered"), ompJobsDirectory]
            + CodexCompletionReadout.directories(
                configRoot: claudeJobsDirectory.deletingLastPathComponent().deletingLastPathComponent(), dataRoot: dataRoot)
        return directories.flatMap { directory in
            [directory] + ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        } + [codexDeliveriesFile, codexDeliveriesFile.deletingLastPathComponent().appendingPathComponent("codex-inbox.jsonl")]
            + ["claude-inbox.jsonl", "claude-replies.jsonl"].map { claudeJobsDirectory.deletingLastPathComponent().appendingPathComponent($0) }
    }

    /// `configRoot` mirrors `SwiftToolDispatcher.agentBridgeConfigRoot`: the stand-in for `~/.config`, which is what makes the tests hermetic.
    public init(configRoot: URL? = nil, dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
        let root = configRoot ?? InstallPaths.current.bridgeConfigRoot
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
        ompJobsDirectory: URL? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.dataRoot = dataRoot
        self.claudeJobsDirectory = claudeJobsDirectory
        self.codexJobsDirectory = codexJobsDirectory
        self.codexDeliveriesFile = codexDeliveriesFile ?? codexJobsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("reply-deliveries.jsonl")
        self.ompJobsDirectory = ompJobsDirectory ?? codexJobsDirectory
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("omp-bridge/wake-jobs", isDirectory: true)
    }

    /// Read all supported stores and return the newest `limit` jobs, newest first. Unreadable/absent directories contribute zero rows rather than failing the whole call — a machine with only one bridge configured still gets a useful
    /// answer.
    public func recentJobs(now: Date, limit: Int = DelegationStatusProjector.defaultLimit) -> [DelegationReadout] {
        let bounded = max(1, min(limit, Self.maxLimit))
        return readSnapshot(now: now, limit: bounded).jobs
    }

    /// One disk read reports jobs and availability; only absent or fully readable stores count as readable.
    public func recentJobsWithAvailability(
        now: Date,
        limit: Int = DelegationStatusProjector.defaultLimit
    ) -> (jobs: [DelegationReadout], allStoresReadable: Bool) {
        let bounded = max(1, min(limit, Self.maxLimit))
        let snapshot = readSnapshot(now: now, limit: bounded)
        return (
            Array(snapshot.jobs.prefix(bounded)),
            snapshot.sources.allSatisfy { $0.status == "available" || $0.status == "absent" }
        )
    }

    /// Complete ordered projection for reconciliation owners. This is deliberately separate from `recentJobs`: the latter is a model-visible display budget, while a durable outcome cursor must never skip an older record merely because more
    /// than 100 newer jobs arrived in one burst.
    public func allJobs(now: Date) -> [DelegationReadout] {
        readSnapshot(now: now).jobs
    }

    /// One disk read reports all jobs and availability so cursors never advance past unreadable records.
    public func allJobsWithAvailability(
        now: Date
    ) -> (jobs: [DelegationReadout], allStoresReadable: Bool) {
        let snapshot = readSnapshot(now: now)
        return (
            snapshot.jobs,
            snapshot.sources.allSatisfy { $0.status == "available" || $0.status == "absent" }
        )
    }

    /// Read each source once. Availability describes this same observation, while the historical array APIs still return every readable job.
    package func readSnapshot(now: Date, limit: Int? = nil, offset: Int = 0,
                      agent: String? = nil, messageID: String? = nil) -> DelegationStatusReadSnapshot {
        let life: String
        do { life = try DataRootLife.current(in: dataRoot) }
        catch { return .init(jobs: [], sources: [.init(source: "life-id", agent: "self", status: "unavailable")], matchedCount: 0) }
        func inLife(_ original: DelegationReadout, _ job: [String: JSONValue]) -> DelegationReadout {
            guard DataRootLife.life(of: Self.string(job, "lifeID")) != life, original.deliveryOutcome != "delivered" else { return original }
            var row = original
            row.state = "stopped"; row.status = "stopped"; row.deliveryOutcome = "stopped"
            row.deliveryReason = DataRootLife.stoppedReason; row.stalled = false; row.stallBasis = .terminal; row.stallDeadline = nil
            return row
        }
        var rows: [DelegationReadout] = []
        var sources: [DelegationSourceAvailability] = []
        let claude = Self.readDirectory(claudeJobsDirectory, source: "claude_jobs", agent: "claude")
        sources.append(claude.availability)
        for (url, object) in claude.objects {
            if let row = Self.projectClaude(url: url, now: now, object: object) { rows.append(inLife(row, object)) }
        }
        // A live-session reply has a linked receipt, but no wake job. Exact reads must include that receipt without inventing a runner.
        if let messageID, agent == nil || agent == "claude",
           !rows.contains(where: { $0.acceptedMessageIDs.contains(messageID) }) {
            if let reply = liveReplies([messageID])[messageID] {
                let stamp = reply.createdAt
                var row = DelegationReadout(id: messageID, acceptedMessageIDs: [messageID],
                    source: "claude", agent: "claude", topicSlug: nil,
                    deskHandle: nil, state: "replied", status: "replied", runStatus: nil, createdAt: nil,
                    claimedAt: nil, startedAt: nil, lastLiveness: nil, completedAt: stamp, elapsedSeconds: nil,
                    stalled: false, stallBasis: .terminal, deliveryLost: nil, deliveryOutcome: nil,
                    completionTextHead: nil, recordKind: "linked_reply")
                Self.retainReply(reply.text, truncated: reply.truncated, in: &row)
                row.recencyKey = Self.date(stamp)
                rows.append(row)
                sources.append(DelegationSourceAvailability(source: "claude_replies", agent: "claude", readableRecords: 1))
            }
        }
        var codexRows: [String: DelegationReadout] = [:]
        for (directory, source, undelivered) in [
            (codexJobsDirectory, "codex_jobs", false),
            (codexJobsDirectory.appendingPathComponent("undelivered", isDirectory: true), "codex_undelivered", true),
        ] {
            let read = Self.readDirectory(directory, source: source, agent: "codex")
            sources.append(read.availability)
            for (url, object) in read.objects {
                if let row = Self.projectCodex(url: url, undelivered: undelivered, now: now, object: object) {
                    codexRows[row.id] = inLife(row, object)
                }
            }
        }
        // Successful delivery removes the reply-job file. The durable ledger is therefore not optional history: it is the canonical terminal half of the same lifecycle. A proven delivered receipt outranks a stale in-flight projection for
        // the same originating message id.
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
            guard let job = codexRows[key], !job.acceptedMessageIDs.isEmpty else { continue }
            let reconciled = job.acceptedMessageIDs.allSatisfy { id in
                guard let receipt = deliveries.byID[id] else { return false }
                if receipt.completionDeliveryID == job.completionDeliveryID,
                   ["owed", "failed_before_answer", "legacy_before_receipts", "let_go"].contains(receipt.deliveryOutcome ?? "") { return true }
                guard let thread = job.recordedThreadID, let turn = job.recordedTurnID,
                      receipt.recordedThreadID == thread, receipt.recordedTurnID == turn else { return false }
                return job.deliveryOutcome != "unknown" || receipt.deliveryOutcome == "delivered"
            }
            if reconciled {
                codexRows.removeValue(forKey: key)
            }
        }
        rows.append(contentsOf: codexRows.values)
        let omp = Self.readDirectory(ompJobsDirectory, source: "omp_jobs", agent: "omp")
        sources.append(omp.availability)
        for (url, object) in omp.objects {
            if let row = Self.projectOMP(url: url, now: now, object: object) { rows.append(inLife(row, object)) }
        }
        func matches(_ row: DelegationReadout) -> Bool {
            (agent == nil || row.agent == agent) && (messageID == nil || row.acceptedMessageIDs.contains(messageID!))
        }
        rows = rows.filter(matches)
        // Cached terminal rows are already ordered. Only retain enough candidates for this page; full reconciliation deliberately retains every receipt.
        if agent == nil || agent == "codex" {
            if let messageID {
                if let row = deliveries.byID[messageID], matches(row) {
                    rows.append(row)
                }
            } else {
                for row in deliveries.ordered {
                    rows.append(row)
                }
            }
        }
        var states: [String: (state: CodexCompletionReadout, path: URL)] = [:]
        let matchedLifecycles = Set(rows.compactMap(\.completionDeliveryID))
        for directory in CodexCompletionReadout.directories(
            configRoot: claudeJobsDirectory.deletingLastPathComponent().deletingLastPathComponent(), dataRoot: dataRoot) {
            var lifecycles = Self.readDirectory(directory, source: "completion_lifecycle", agent: "self")
            for (url, fields) in lifecycles.objects {
                guard let state = try? JSONDecoder().decode(CodexCompletionReadout.self,
                    from: JSONValue.object(fields).serializedData(pretty: false)).reading(life: life) else {
                    lifecycles.availability.status = "unreadable"
                    continue
                }
                guard let status = state.status else { continue }
                let id = state.deliveryId
                states[id] = (state: state, path: url)
                guard !matchedLifecycles.contains(id) else { continue }
                let principal = (try? state.knownPrincipal(dataRoot: dataRoot)) ?? "unattributed"
                let terminal = status != "owed"
                var row = DelegationReadout(id: id, source: state.source ?? principal, agent: principal,
                    topicSlug: nil, deskHandle: nil, state: status, status: nil, runStatus: nil,
                    createdAt: nil, claimedAt: nil, startedAt: nil, lastLiveness: nil,
                    completedAt: terminal ? state.updatedAt : nil, elapsedSeconds: nil, stalled: false,
                    stallBasis: terminal ? .terminal : .none, deliveryLost: nil, deliveryOutcome: nil, completionTextHead: nil)
                row.completionDeliveryID = id
                row.recordKind = "completion_lifecycle"
                row.recoveryNote = status == "stopped" ? DataRootLife.stoppedReason : url.path
                row.recencyKey = Self.firstDate(state.updatedAt)
                if matches(row) { rows.append(row) }
            }
            sources.append(lifecycles.availability)
        }
        for index in rows.indices {
            if rows[index].recordKind == "delivery_receipt",
               ["owed", "failed_before_answer", "legacy_before_receipts"].contains(rows[index].deliveryOutcome ?? "") {
                rows[index].recoveryNote = codexDeliveriesFile.path
            }
            guard let id = rows[index].completionDeliveryID, let lifecycle = states[id] else { continue }
            let state = lifecycle.state
            if let status = state.status,
               status == "stopped" || !["delivered", "owed", "failed_before_answer", "legacy_before_receipts", "let_go"].contains(rows[index].deliveryOutcome ?? "") {
                rows[index].deliveryOutcome = status
                rows[index].state = status == "delivered" ? "settled" : status
                if status == "stopped" { rows[index].recoveryNote = DataRootLife.stoppedReason }
                if status == "failed_before_answer" {
                    rows[index].recoveryNote = lifecycle.path.path
                    rows[index].completedAt = rows[index].completedAt ?? state.updatedAt
                }
            }
            rows[index].deliveryLost = nil
        }
        var answers: [String: DelegationReadout] = [:]
        rows = rows.sorted { $0.id < $1.id }.filter { row in
            guard let id = row.completionDeliveryID,
                  states[id] != nil || ["delivered", "owed", "failed_before_answer", "legacy_before_receipts", "let_go"].contains(row.deliveryOutcome ?? "") else { return true }
            let key = row.source + ":" + id
            if var prior = answers[key] {
                prior.acceptedMessageIDs.formUnion(row.acceptedMessageIDs)
                prior.completionTextHead = prior.completionTextHead ?? row.completionTextHead
                answers[key] = prior
            } else { answers[key] = row }
            return false
        }
        rows.append(contentsOf: answers.values)
        for index in rows.indices where rows[index].agent == "codex" && rows[index].completionDeliveryID != nil {
            // A new accepted action still needs settlement when its answer was already counted.
            rows[index].deliveryReceiptVersion = (rows[index].deliveryReceiptVersion ?? "")
                + "|" + rows[index].acceptedMessageIDs.sorted().joined(separator: ",")
        }
        let matchedCount = rows.count
        rows.sort(by: Self.newestFirst)
        var page = Array(rows.dropFirst(min(offset, rows.count)).prefix(limit ?? rows.count))
        // A thread reads as ask and answer. Only the returned page is joined, from the tail of the inbox, so this stays a bounded read.
        let wanted = Set(page.flatMap { $0.acceptedMessageIDs })
        if !wanted.isEmpty {
            let asks = Self.requestRecords(inbox: codexDeliveriesFile.deletingLastPathComponent()
                .appendingPathComponent("codex-inbox.jsonl"), ids: wanted)
            for index in page.indices where page[index].requestTextHead == nil {
                page[index].requestTextHead = page[index].acceptedMessageIDs.sorted().lazy.compactMap { asks[$0]?["text"] }.first.flatMap(Self.head)
            }
        }
        // Conversation handles come from the bridge inbox.
        let claudeIDs = Set(page.filter { $0.agent == "claude" }.flatMap { $0.acceptedMessageIDs })
        if !claudeIDs.isEmpty {
            let handles = Self.requestRecords(inbox: claudeJobsDirectory.deletingLastPathComponent()
                .appendingPathComponent("claude-inbox.jsonl"), ids: claudeIDs)
            // Live replies join by accepted message ID from the bridge chat.
            let replies = liveReplies(claudeIDs)
            for index in page.indices where page[index].agent == "claude" {
                page[index].conversationID = page[index].acceptedMessageIDs.sorted().lazy.compactMap { handles[$0]?["conversationId"] }.first
                if page[index].agentReplyTextHead == nil,
                   let reply = page[index].acceptedMessageIDs.sorted().lazy.compactMap({ replies[$0] }).first {
                    Self.retainReply(reply.text, truncated: reply.truncated, in: &page[index])
                }
            }
        }
        return DelegationStatusReadSnapshot(jobs: page, sources: sources, matchedCount: matchedCount)
    }

    /// Live-session answers retain full text or a 400-character head.
    private func liveReplies(_ ids: Set<String>) -> [String: (text: String, truncated: Bool, createdAt: String?)] {
        let url = claudeJobsDirectory.deletingLastPathComponent().appendingPathComponent("claude-replies.jsonl")
        // Read whole: the bridge's own retention (500 answers) bounds this file, and a tail window would drop older answers it still keeps.
        return Self.requestRecords(inbox: url, ids: ids, window: .max).compactMapValues { record in
            guard let text = record["replyText"] ?? record["replyTextHead"] else { return nil }
            return (text, record["replyText"] != nil ? record["replyTruncated"] == "true" : text.hasSuffix("…"), record["createdAt"])
        }
    }

    public static func requestRecords(inbox url: URL, ids: Set<String>, window: Int = 524_288) -> [String: [String: String]] {
        let key = url.standardizedFileURL.path + "#" + String(window)
        let stamp = try? DelegationFileCache.stamp(url)
        let all: [String: [String: String]]
        if let stamp, let cached = fileCache.tail(key, stamp: stamp) {
            all = cached
        } else {
            all = tailTexts(inbox: url, window: window)
            if let stamp { fileCache.putTail(key, stamp: stamp, all) }
        }
        return all.filter { ids.contains($0.key) }
    }

    private static func tailTexts(inbox url: URL, window: Int) -> [String: [String: String]] {
        guard let read = try? SwiftNativePersistenceCore.tailPhysicalLines(url, limit: .max, maxBytes: window) else { return [:] }
        var lines = read.lines.filter { !$0.isEmpty }
        if read.truncatedToByteWindow, !lines.isEmpty { lines.removeFirst() }
        var found: [String: [String: String]] = [:]
        for line in lines {
            // A true flag (the inbox's `read`) reads as "true"; false is absent.
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let fields = object.compactMapValues { value -> String? in
                guard let text = value as? String ?? ((value as? Bool) == true ? "true" : nil), !text.isEmpty else { return nil }
                return text
            }
            for key in ["id", "messageId"] {
                if let id = object[key] as? String { found[id, default: [:]].merge(fields) { _, new in new } }
            }
        }
        return found
    }

    static func newestFirst(_ lhs: DelegationReadout, _ rhs: DelegationReadout) -> Bool {
        switch (lhs.recencyKey, rhs.recencyKey) {
        case let (l?, r?) where l != r: return l > r
        case (nil, .some): return false
        case (.some, nil): return true
        default: return lhs.id > rhs.id
        }
    }

    private static let deliveryCache = DelegationDeliveryCache()
    private static let fileCache = DelegationFileCache()

    /// Earliest future crossing of the same deadline/stall-seconds rules used by `stalled`. File events trigger immediate rereads while work moves; this exact deadline is what makes a writer that goes quiet observable without adding a
    /// polling heartbeat.
    public func nextStallDeadline(after now: Date) -> Date? {
        allJobs(now: now)
            .compactMap(\.stallDeadline)
            .filter { $0 > now }
            .min()
    }

    // MARK: - Directory scanning

    /// Only an initial missing-path error means absent. A later read failure or a wrong file kind is unavailable, never an empty healthy source.
    private static func sourceStatus(_ url: URL, expected: FileAttributeType) -> String {
        do {
            // Existing reads follow configured symlinks; availability is not a new path/authority restriction on those readable sources.
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
        let previous = fileCache.jobSnapshot(directory.path)
        var parsedFiles: [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])] = [:]
        for name in names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted() {
            let url = directory.appendingPathComponent(name)
            let stamp: SnapshotTailOpLog.FileStamp?
            do { stamp = try DelegationFileCache.stamp(url) }
            catch {
                availability.unreadableFiles += 1
                continue
            }
            // Unchanged since the last read: reuse its parse.
            if let stamp, let cached = previous[name], cached.stamp == stamp {
                parsedFiles[name] = cached
                availability.readableRecords += 1
                objects.append((url, cached.object))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                availability.unreadableFiles += 1
                continue
            }
            guard let parsed = try? JSONValue.parse(data), case .object(let object) = parsed else {
                availability.malformedRecords += 1
                continue
            }
            if let stamp { parsedFiles[name] = (stamp, object) }
            availability.readableRecords += 1
            objects.append((url, object))
        }
        fileCache.putJobs(directory.path, parsedFiles)
        if availability.unreadableFiles > 0 || availability.malformedRecords > 0 { availability.status = "partial" }
        return (objects, availability)
    }

    // MARK: - Shared helpers

    /// Delivery grace stays above the bridge POST ceiling to allow settlement.
    static let deliveryStallSeconds: TimeInterval = 660
}
