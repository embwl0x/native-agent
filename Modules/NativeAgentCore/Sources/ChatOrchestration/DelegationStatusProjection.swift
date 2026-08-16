import Foundation
import PersistenceCore

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
//          plus the `undelivered/` subdirectory: a DELIVERED job is unlinked
//          (finalizeReplyJobFile, L3601-3611) while an undeliverable one is
//          preserved there. Presence under undelivered/ IS the delivery-lost
//          signal — there is no `deliveryLost` field on the codex record.
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
    }

    public var id: String
    /// Which bridge store this row came from: "claude" | "codex" | "omp".
    public var source: String
    /// The agent that runs the job. Currently 1:1 with `source`, kept separate
    /// because the claude store is also where a future third runner would land.
    public var agent: String
    public var topicSlug: String?
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
    /// Coarse delivery disposition: "delivered" | "lost" | "unknown".
    ///
    /// The distinction is load-bearing. On the codex side a job preserved
    /// under `undelivered/` is NOT proven lost — replyJobDisposition
    /// (codex_thread_wakeup.js L3540-3547) preserves there exactly when
    /// replyStatus is `outcome_unknown` or `conflict`, i.e. the bridge could
    /// not confirm either way. Reporting those as lost would invent a fact,
    /// which is the precise failure this tool exists to stop.
    public var deliveryOutcome: String?
    /// First 200 characters of the completion text, when the record carries it.
    ///
    /// Absent on most claude rows BY DESIGN: the runner nulls completionText
    /// once delivery succeeds (claude_thread_wakeup.js L1551) and only retains
    /// it when the text still needs replaying. Its absence means "delivered",
    /// not "missing".
    public var completionTextHead: String?

    /// Newest-first ordering key: the most recent timestamp the record proves.
    var recencyKey: Date?

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
        put("state", state)
        put("status", status)
        put("run_status", runStatus)
        put("created_at", createdAt)
        put("claimed_at", claimedAt)
        put("started_at", startedAt)
        put("last_liveness", lastLiveness)
        put("completed_at", completedAt)
        put("completion_text_head", completionTextHead)
        put("delivery_outcome", deliveryOutcome)
        if let elapsedSeconds { obj["elapsed_seconds"] = .int(Int64(elapsedSeconds)) }
        if let deliveryLost { obj["delivery_lost"] = .bool(deliveryLost) }
        return .object(obj)
    }
}

/// Pure, injectable reader over the three wake-job stores.
public struct DelegationStatusProjector: Sendable {
    /// Default: `~/.config/claude-bridge/wake-jobs`.
    public var claudeJobsDirectory: URL
    /// Default: `~/.config/codex-nativeagent-bridge/reply-jobs`.
    public var codexJobsDirectory: URL
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
        self.ompJobsDirectory = root
            .appendingPathComponent("omp-bridge", isDirectory: true)
            .appendingPathComponent("wake-jobs", isDirectory: true)
    }

    public init(claudeJobsDirectory: URL, codexJobsDirectory: URL, ompJobsDirectory: URL? = nil) {
        self.claudeJobsDirectory = claudeJobsDirectory
        self.codexJobsDirectory = codexJobsDirectory
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
        return Array(allJobs(now: now).prefix(bounded))
    }

    /// Complete ordered projection for reconciliation owners. This is
    /// deliberately separate from `recentJobs`: the latter is a model-visible
    /// display budget, while a durable outcome cursor must never skip an older
    /// record merely because more than 100 newer jobs arrived in one burst.
    public func allJobs(now: Date) -> [DelegationJobProjection] {
        var rows: [DelegationJobProjection] = []
        for url in Self.jsonFiles(in: claudeJobsDirectory) {
            if let row = Self.projectClaude(url: url, now: now) { rows.append(row) }
        }
        for (url, undelivered) in Self.codexJobFiles(in: codexJobsDirectory) {
            if let row = Self.projectCodex(url: url, undelivered: undelivered, now: now) { rows.append(row) }
        }
        for url in Self.jsonFiles(in: ompJobsDirectory) {
            if let row = Self.projectOMP(url: url, now: now) { rows.append(row) }
        }
        rows.sort { lhs, rhs in
            switch (lhs.recencyKey, rhs.recencyKey) {
            case let (l?, r?) where l != r: return l > r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.id > rhs.id  // stable tiebreak
            }
        }
        return rows
    }

    // MARK: - Directory scanning

    static func jsonFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// reply-jobs/ holds in-flight jobs; reply-jobs/undelivered/ holds jobs
    /// whose bridge delivery failed and were preserved instead of unlinked.
    static func codexJobFiles(in directory: URL) -> [(URL, Bool)] {
        jsonFiles(in: directory).map { ($0, false) }
            + jsonFiles(in: directory.appendingPathComponent("undelivered", isDirectory: true)).map { ($0, true) }
    }

    static func readObject(_ url: URL) -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed else { return nil }
        return obj
    }

    // MARK: - Claude projection

    static func projectClaude(url: URL, now: Date) -> DelegationJobProjection? {
        guard let job = readObject(url) else { return nil }
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
        // pass. Without them in the terminal set, a job that finished an hour
        // ago and is merely waiting on bridge delivery reads as STALLED — the
        // exact false stuck-job report this tool exists to prevent.
        let state = string(job, "state")
        let terminal = completedAt != nil
            || string(job, "runStatus") != nil
            || ["settled", "delivering", "spawn_failed"].contains(state ?? "")
        let (stalled, basis) = stallVerdict(
            terminal: terminal,
            deadlineAt: string(job, "deadlineAt"),
            stallSeconds: number(job, "stallSeconds"),
            lastLiveness: liveness ?? startedAt ?? claimedAt ?? createdAt,
            now: now
        )

        var row = DelegationJobProjection(
            id: id,
            source: "claude",
            agent: "claude",
            topicSlug: string(job, "topicSlug"),
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
            completionTextHead: head(string(job, "completionText"))
        )
        row.recencyKey = firstDate(completedAt, liveness, startedAt, claimedAt, createdAt)
        return row
    }

    // MARK: - Codex projection

    static func projectCodex(url: URL, undelivered: Bool, now: Date) -> DelegationJobProjection? {
        guard let job = readObject(url) else { return nil }
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
        let (stalled, basis) = stallVerdict(
            terminal: terminal, deadlineAt: nil, stallSeconds: nil, lastLiveness: liveness, now: now
        )

        var row = DelegationJobProjection(
            id: id,
            source: "codex",
            agent: "codex",
            topicSlug: codexTopicSlug(job),
            state: string(job, "phase"),
            status: nil,  // codex writes no separate delivery status onto the job
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
            deliveryOutcome: undelivered ? "unknown" : nil,
            completionTextHead: head(string(turnResult, "message") ?? string(turnResult, "lastAgentMessage"))
        )
        row.recencyKey = firstDate(completedAt, liveness, claimedAt, createdAt)
        return row
    }

    // MARK: - OMP projection

    /// OMP keeps settled job records, like Claude, but writes the delivery
    /// result as a nested `bridge.status` and the topic inside `payload`.
    static func projectOMP(url: URL, now: Date) -> DelegationJobProjection? {
        guard let job = readObject(url) else { return nil }
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
        let (stalled, basis) = stallVerdict(
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
        default: nil
        }
        let retained = string(job, "completionText")
            ?? string(job, "reply")
            ?? string(job, "stderrTail")
        var row = DelegationJobProjection(
            id: id,
            source: "omp",
            agent: "omp",
            topicSlug: string(payload, "topic").map(slug),
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
            completionTextHead: head(retained)
        )
        row.recencyKey = firstDate(completedAt, liveness, startedAt, createdAt)
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

    static func slug(_ topic: String) -> String {
        let value = String(topic.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(value.prefix(64))
    }

    // MARK: - Shared helpers

    /// The single place a stall verdict is made, for every store.
    static func stallVerdict(
        terminal: Bool,
        deadlineAt: String?,
        stallSeconds: Double?,
        lastLiveness: String?,
        now: Date
    ) -> (Bool, DelegationJobProjection.StallBasis) {
        if terminal { return (false, .terminal) }
        if let deadline = date(deadlineAt) {
            return (now > deadline, .deadline)
        }
        if let stallSeconds, stallSeconds > 0, let last = date(lastLiveness) {
            return (now.timeIntervalSince(last) > stallSeconds, .stallSeconds)
        }
        return (false, .none)
    }

    static func head(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(completionTextHeadLimit))
    }

    static func string(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s.isEmpty ? nil : s }
        return nil
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
