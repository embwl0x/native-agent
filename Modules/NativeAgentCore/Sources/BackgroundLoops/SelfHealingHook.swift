import DoctorChecks
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

/// Self-healing hook (U2b wave 3 item 2 + plan A4 source #3). Watches two
/// signals the app already writes and, on a real fault, runs a diagnostic LLM
/// pass and files a `needs_diff` evolution proposal with redacted evidence —
/// turning a silent Doctor failure / error burst into something Agent (or
/// Claude / the user) can pick up, write a diff for, and feed the candidate
/// builder. It NEVER writes code itself and never stages an approval card; it
/// only files prose into the proposal store (status `needs_diff`).
///
/// Detectors (both fire independently; either trips a diagnostic pass):
///  1. Doctor HEALTHY→FAIL transition on the auto-doctor loop's
///     `doctor/latest.json`. "Healthy" = no HEARTBEAT-ELIGIBLE check has
///     status "fail" — Doctor-only diagnostic rows are skipped entirely,
///     because filing a proposal is an unattended decision (see
///     `DoctorHeartbeatPolicy`). A
///     transition is only claimed when the PRIOR observed state was healthy
///     and the current state is not — a first run (no prior stamp) asserts
///     nothing, and a sustained-fail state does not re-fire every tick.
///  2. Error-feed burst — `errorBurstThreshold` rows across the watched error
///     sinks (`errorFeeds`) whose timestamp falls inside `errorBurstWindow`. A
///     handful of transient errors is normal; a tight cluster signals a
///     systemic fault worth diagnosing.
///
/// Cooldown: a flapping Doctor or a sustained error stream must not spam the
/// proposal store. After a diagnostic proposal is filed, no further proposal
/// fires for `cooldownSeconds` (stamp file under the data root).
///
/// Dependency-clean: the proposal filing is an injected closure (the module
/// has no SelfImprovement dep — same rule as WeeklySelfImprovementLoop's
/// `fileCodeFinding`). tick() is non-throwing by LoopRunner contract.
public struct SelfHealingHook: LoopRunner {
    public let loopId: String = "self_healing"
    public let interval: TimeInterval
    /// One cheap diagnostic LLM turn at most per tick (and usually none).
    /// Same generous-but-bounded ceiling as the heartbeat.
    public var tickTimeoutOverride: TimeInterval? { 120 }

    /// The surface name; its own MODEL_SURFACES entry (added this wave) so the
    /// diagnostic pass routes via the picker (the user's HARD RULE), pinnable
    /// independently of chat.
    public static let surface = "diagnostics"

    // MARK: Detector constants (rationale inline — constant-change class)

    /// Rows across the watched error feeds within the window required to call
    /// it a "burst."
    /// Below this, transient/expected errors (a one-off network blip, a single
    /// failed probe) should NOT wake the diagnostic pass. 10 is high enough to
    /// mean "something is repeatedly failing," low enough to catch a fault
    /// before it floods.
    public static let errorBurstThreshold = 10
    /// The recency window for the burst count. Short enough that the count
    /// reflects a CURRENT cluster, not errors accumulated over hours/days
    /// (which the feeds retain). 10 minutes ≈ two doctor cadences.
    public static let errorBurstWindow: TimeInterval = 10 * 60
    /// A watched feed with no write in this long carries NO signal. It is not
    /// evidence of health: `logs/errors.jsonl` reported "0 recent errors … ok"
    /// for three months after its only writer (the retired Python daemon) went
    /// away. 7 days is longer than any real quiet stretch on a live sink and
    /// short enough to catch a writer that silently stopped.
    public static let feedSilentAfter: TimeInterval = 7 * 24 * 60 * 60
    /// Minimum gap between diagnostic proposals. A Doctor that flaps
    /// fail→ok→fail, or a steady error stream, would otherwise file a fresh
    /// proposal every tick. 6 hours bounds it to a handful per day while still
    /// re-engaging if a NEW fault appears after the window.
    public static let cooldownSeconds: TimeInterval = 6 * 60 * 60

    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    /// Files a `needs_diff` evolution proposal (title, evidence). Injected so
    /// this module gains no SelfImprovement dep; the assembly wires it to
    /// `EvolutionProposalStore.propose(source: .selfHeal, ...)`.
    private let fileProposal: @Sendable (_ title: String, _ evidence: String) async throws -> Void
    /// Closes stale Doctor-failure self-heal proposals once Doctor is healthy
    /// again. Injected for the same dependency-clean reason as fileProposal.
    private let closeDoctorFailureProposals: @Sendable () async -> Void

    public init(
        interval: TimeInterval = 30 * 60,
        llm: any LLMClient,
        router: any ProviderRoutingProtocol = SwiftNativeProviderRouting(),
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        fileProposal: @escaping @Sendable (_ title: String, _ evidence: String) async throws -> Void,
        closeDoctorFailureProposals: @escaping @Sendable () async -> Void = {}
    ) {
        self.interval = interval
        self.llm = llm
        self.router = router
        self.dataRoot = dataRoot
        self.clock = clock
        self.fileProposal = fileProposal
        self.closeDoctorFailureProposals = closeDoctorFailureProposals
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let now = clock()

        // --- Detector 1: Doctor healthy→fail transition ---------------------
        let snapshot = loadDoctorSnapshot()
        var doctorTransition = false
        if let snapshot {
            let priorHealthy = loadPriorDoctorHealthy()
            // Transition only when we KNOW the prior state was healthy.
            doctorTransition = (priorHealthy == true) && !snapshot.healthy
            if snapshot.healthy {
                await closeDoctorFailureProposals()
            }
            // Persist the current observation ONLY when no transition is
            // pending. A transition is "consumed" by writing healthy=false —
            // if we stamp it before the proposal durably lands (cooldown
            // suppression, LLM failure, store-write failure below), the
            // healthy→fail edge is lost forever while Doctor stays failing.
            // Pending transitions re-evaluate every tick until filed.
            if !doctorTransition, priorHealthy != snapshot.healthy {
                do {
                    try savePriorDoctorHealthy(snapshot.healthy, at: now)
                } catch {
                    return .failed(error: "self-healing doctor-state stamp: \(error)")
                }
            }
        }

        // --- Cooldown (evaluated BEFORE the feed scan) ----------------------
        // The watched feeds are live firehoses: `telegram/errors.jsonl` took
        // 10,774 rows in one bad hour, and this hook wakes on every write to
        // them. Re-reading four tails on each of those wakes, for six hours,
        // to re-discover a burst it is not allowed to act on, would trade one
        // dead nerve for an I/O storm. Nothing can be filed while the cooldown
        // holds, so nothing is read.
        if let last = loadCooldownStamp(), now.timeIntervalSince(last) < Self.cooldownSeconds {
            if doctorTransition {
                FileHandle.standardError.write(Data(
                    "SelfHealingHook: trigger suppressed by cooldown (last \(Self.isoString(last)))\n".utf8))
            }
            return .skipped(reason: "self-healing cooldown active")
        }

        // --- Detector 2: error-feed burst -----------------------------------
        let burst = errorBurst(now: now)   // (count, lines) when over threshold

        guard doctorTransition || burst != nil else {
            return .skipped(reason: "no self-healing trigger")
        }

        // --- Build evidence (redacted) --------------------------------------
        var reasons: [String] = []
        if doctorTransition { reasons.append("Doctor health transitioned healthy→fail") }
        if let burst {
            reasons.append("\(burst.count) errors logged within \(Int(Self.errorBurstWindow / 60))m")
        }
        let reason = reasons.joined(separator: "; ")

        var evidenceParts: [String] = ["Trigger: \(reason) (at \(Self.isoString(now)))."]
        if let snapshot, doctorTransition {
            evidenceParts.append("## Doctor snapshot (failing)\n"
                + Self.redactSecrets(String(snapshot.rawText.prefix(2000))))
        }
        if let burst, !burst.lines.isEmpty {
            evidenceParts.append("## Error burst (last \(Int(Self.errorBurstWindow / 60))m, up to "
                + "\(burst.lines.count) lines)\n"
                + Self.redactSecrets(burst.lines.joined(separator: "\n")))
        }
        let evidence = evidenceParts.joined(separator: "\n\n")

        // --- Diagnostic LLM pass (own surface, via the picker) --------------
        let diagnosis: String
        do {
            let model = await router.modelStringForSurface(Self.surface)
            let raw = try await llm.complete(
                prompt: Self.diagnosticPrompt(reason: reason, evidence: evidence, now: now),
                system: Self.systemPrompt,
                model: model,
                surface: Self.surface
            )
            diagnosis = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // A failed diagnostic pass must NOT consume the cooldown — file
            // nothing and let the next tick retry while the fault persists.
            FileHandle.standardError.write(Data(
                "SelfHealingHook: diagnostic LLM pass failed (no proposal filed, no cooldown): \(error)\n".utf8))
            return .failed(error: "self-healing diagnosis: \(error)")
        }

        let title = "Self-heal: " + (doctorTransition
            ? "Doctor failure detected"
            : "error burst detected")
        let body = (diagnosis.isEmpty ? "(diagnostic pass returned no text)" : diagnosis)
            + "\n\n---\n" + evidence

        // Never file durable state after cancel/restart (scheduler lets
        // timed-out ticks run until they observe cancellation).
        if Task.isCancelled { return .skipped(reason: "canceled") }

        do {
            try await fileProposal(title, body)
        } catch {
            // A failed store write must NOT consume the cooldown or the
            // doctor transition — retry on the next tick while the fault
            // persists. (The injected closure rethrows; swallowing here
            // would stamp a \(Int(Self.cooldownSeconds / 3600))h cooldown
            // with no proposal on disk.)
            FileHandle.standardError.write(Data(
                "SelfHealingHook: proposal store write failed (no cooldown consumed): \(error)\n".utf8))
            return .failed(error: "self-healing proposal write: \(error)")
        }
        // Stamp cooldown + consume the doctor transition only AFTER the
        // proposal durably landed.
        do {
            try saveCooldownStamp(now)
            if let snapshot, doctorTransition {
                try savePriorDoctorHealthy(snapshot.healthy, at: now)
            }
        } catch {
            return .failed(error: "self-healing completion stamp: \(error)")
        }
        FileHandle.standardError.write(Data(
            "SelfHealingHook: filed needs_diff proposal (\(reason))\n".utf8))
        return .completed(result: "self-healing proposal filed")
    }

    // MARK: - Doctor health

    struct DoctorSnapshot { let healthy: Bool; let rawText: String }

    /// Reads `doctor/latest.json` and derives health. Healthy = no
    /// heartbeat-eligible check has status "fail" (warn is tolerated — it is
    /// not a failure). Returns nil when the file is missing/unparseable, or
    /// when every row it holds is one this hook may not judge (no observation
    /// to act on).
    func loadDoctorSnapshot() -> DoctorSnapshot? {
        let path = dataRoot.appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("latest.json")
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Malformed or shape-shifted snapshot = UNAVAILABLE, never "healthy"
        // (gpt-5.5 wave-1 NEEDS_FIX: `{}` or an older shape must not read as
        // 0 failing → healthy:true).
        guard let checks = obj["checks"] as? [[String: Any]] else {
            return nil
        }
        // 2026-09-02: filing an evolution proposal is an UNATTENDED decision,
        // exactly like the heartbeat's push. Doctor-only diagnostic rows
        // (`heartbeatEligible == false`) grade a measurement window and are
        // for a person reading Doctor — they must never flip this verdict.
        // The exclusion is derived from the real check registry, so it cannot
        // drift from the flags on the checks themselves.
        let judged = checks.filter { row in
            guard let id = row["id"] as? String else { return true }
            return DoctorHeartbeatPolicy.isEligible(id)
        }
        // Every row excluded ⇒ nothing was observed. Unavailable, never
        // "healthy" — the same rule the malformed-shape branch above follows.
        guard !judged.isEmpty else { return nil }
        let anyFail = judged.contains { ($0["status"] as? String) == "fail" }
        return DoctorSnapshot(healthy: !anyFail, rawText: text)
    }

    private var doctorStateStamp: URL {
        selfHealDir().appendingPathComponent("doctor_state.json")
    }

    /// The last observed doctor health, or nil if never observed.
    func loadPriorDoctorHealthy() -> Bool? {
        guard let data = try? Data(contentsOf: doctorStateStamp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["healthy"] as? Bool
    }

    func savePriorDoctorHealthy(_ healthy: Bool, at: Date) throws {
        let obj: [String: Any] = ["healthy": healthy, "at": Self.isoString(at)]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try FileManager.default.createDirectory(
            at: selfHealDir(), withIntermediateDirectories: true)
        try data.write(to: doctorStateStamp, options: .atomic)
    }

    // MARK: - Watched error feeds

    /// One watched error sink.
    public struct ErrorFeed: Sendable, Equatable {
        /// Short name used in evidence and in the heartbeat line.
        public let label: String
        /// Path relative to the data root.
        public let relativePath: String

        public init(label: String, relativePath: String) {
            self.label = label
            self.relativePath = relativePath
        }

        public func url(dataRoot: URL) -> URL {
            relativePath.split(separator: "/").reduce(dataRoot) {
                $0.appendingPathComponent(String($1))
            }
        }
    }

    /// The error sinks this hook (and the heartbeat) watch.
    ///
    /// `logs/errors.jsonl` used to be the ONLY one, and it has had no Swift
    /// writer since the Python daemon was retired — last row 2026-06-02, while
    /// thirteen readers kept treating its emptiness as health. The live sinks
    /// are the surface error feeds and the background-loop failure receipts.
    /// The dead file stays listed so a returning writer is still seen, but the
    /// `feedSilentAfter` guard now reports it as "no signal", never "clean".
    public static let errorFeeds: [ErrorFeed] = [
        ErrorFeed(label: "telegram", relativePath: "telegram/errors.jsonl"),
        ErrorFeed(label: "slack", relativePath: "slack/errors.jsonl"),
        ErrorFeed(label: "loops", relativePath: "logs/background_loop_failures.jsonl"),
        ErrorFeed(label: "legacy", relativePath: "logs/errors.jsonl"),
    ]

    /// What one watched feed currently says. `silent` is the honesty flag: a
    /// missing or long-unwritten feed proves nothing, so a zero `recentCount`
    /// on a silent feed must never be reported as "no errors".
    public struct ErrorFeedStatus: Sendable {
        public let feed: ErrorFeed
        /// Last modification time, or nil when the file does not exist.
        public let lastWriteAt: Date?
        /// Rows inside `errorBurstWindow` (always 0 for a silent feed — it is
        /// not read at all).
        public let recentCount: Int
        /// Up to 30 of those rows, oldest-first, truncated for evidence.
        public let recentLines: [String]
        /// Missing, unreadable, or unwritten for `feedSilentAfter`.
        public let silent: Bool

        /// Human phrasing for the heartbeat line — "no signal" for a silent
        /// feed, a row count for a live one.
        public func summary(now: Date) -> String {
            guard silent else { return "\(recentCount) row(s)" }
            guard let lastWriteAt else { return "no signal (never written)" }
            let days = Int(now.timeIntervalSince(lastWriteAt) / 86_400)
            return "no signal (last write \(days)d ago)"
        }
    }

    /// Max bytes read from the END of each feed per tick. The files are
    /// append-only and can be large; reading them whole every tick is a
    /// cooperative-pool blocker. 256 KiB of tail comfortably covers any
    /// realistic 15-minute window (a burst that overflows it still trips
    /// the threshold from the lines that fit).
    static let errorLogTailBytes = 256 * 1024

    /// Reads every watched feed's bounded tail and reports what it saw. Rows
    /// WITHOUT a parseable timestamp are SKIPPED from the count — counting
    /// undated/malformed historical rows as "current" makes a stale corrupt log
    /// a permanent false burst trigger. The whole bounded tail is scanned (no
    /// early break — interleaved out-of-order timestamps must not hide newer
    /// rows). A silent feed is never opened: its rows cannot be current, and a
    /// bogus future timestamp in a dead file must not manufacture a burst.
    public static func scanErrorFeeds(dataRoot: URL, now: Date) -> [ErrorFeedStatus] {
        errorFeeds.map { feed in
            let path = feed.url(dataRoot: dataRoot)
            let lastWriteAt = (try? FileManager.default.attributesOfItem(atPath: path.path))?[
                .modificationDate] as? Date
            let silent = lastWriteAt.map { now.timeIntervalSince($0) > feedSilentAfter } ?? true
            guard !silent else {
                return ErrorFeedStatus(
                    feed: feed, lastWriteAt: lastWriteAt,
                    recentCount: 0, recentLines: [], silent: true)
            }
            let kept = recentRows(at: path, now: now)
            return ErrorFeedStatus(
                feed: feed, lastWriteAt: lastWriteAt,
                recentCount: kept.count,
                recentLines: Array(kept.prefix(30).reversed()),
                silent: false)
        }
    }

    /// Newest-first rows inside the burst window from one feed's bounded tail.
    private static func recentRows(at path: URL, now: Date) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(errorLogTailBytes) ? size - UInt64(errorLogTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = now.addingTimeInterval(-errorBurstWindow)
        var kept: [String] = []
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = (obj["createdAt"] as? String ?? obj["at"] as? String
                    ?? obj["ts"] as? String ?? obj["timestamp"] as? String).flatMap(parseISO)
            else { continue }  // undated/malformed: never counted as current
            // No early break: writers can interleave slightly out-of-order
            // timestamps, and one stale row must not hide newer rows behind
            // it. The scan is already bounded by errorLogTailBytes.
            if ts < cutoff { continue }
            kept.append(line.prefix(280).description)
        }
        return kept
    }

    /// Total rows across every live feed inside the burst window and, when over
    /// threshold, the feed-labelled evidence lines.
    func errorBurst(now: Date) -> (count: Int, lines: [String])? {
        let statuses = Self.scanErrorFeeds(dataRoot: dataRoot, now: now)
        let total = statuses.reduce(0) { $0 + $1.recentCount }
        guard total >= Self.errorBurstThreshold else { return nil }
        let lines = statuses.flatMap { status in
            status.recentLines.map { "[\(status.feed.label)] \($0)" }
        }
        return (count: total, lines: Array(lines.prefix(30)))
    }

    // MARK: - Cooldown

    private var cooldownStamp: URL {
        selfHealDir().appendingPathComponent("last_proposal.json")
    }

    func loadCooldownStamp() -> Date? {
        guard let data = try? Data(contentsOf: cooldownStamp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["at"] as? String else { return nil }
        return Self.parseISO(at)
    }

    /// The next exact time at which a cooldown-suppressed fault may be
    /// reconsidered. Event-driven owners use this instead of polling every
    /// thirty minutes. Returning nil once the crossing is due lets the event
    /// tick (or the slow integrity sweep) decide whether a fault still exists.
    public func nextMeaningfulDeadline(after now: Date) -> Date? {
        guard let last = loadCooldownStamp() else { return nil }
        let deadline = last.addingTimeInterval(Self.cooldownSeconds)
        return deadline > now ? deadline : nil
    }

    func saveCooldownStamp(_ at: Date) throws {
        let obj: [String: Any] = ["at": Self.isoString(at)]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try FileManager.default.createDirectory(
            at: selfHealDir(), withIntermediateDirectories: true)
        try data.write(to: cooldownStamp, options: .atomic)
    }

    private func selfHealDir() -> URL {
        dataRoot.appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("self_heal", isDirectory: true)
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You are the self-healing diagnostician for NativeAgent, a native Mac + iOS \
    AI assistant app. You are given the trigger reason and redacted evidence \
    (a failing Doctor snapshot and/or a burst of error-log lines). Produce a \
    concise root-cause diagnosis a developer could act on.

    Respond with plain text (no JSON, no code fences):
    • the most likely root cause, named specifically and tied to the evidence;
    • the file/subsystem to look at if you can infer it from the evidence;
    • a one-line suggested direction for a fix.

    Do NOT fabricate a cause the evidence does not support — if the evidence is \
    too thin to localize, say so and name what additional signal would help. \
    Do NOT include any secrets, tokens, or credentials in your reply.
    """

    static func diagnosticPrompt(reason: String, evidence: String, now: Date) -> String {
        """
        A self-healing trigger fired at \(isoString(now)).

        Trigger: \(reason)

        \(evidence)

        Diagnose the most likely root cause per the system prompt.
        """
    }

    // MARK: - Redaction

    /// Best-effort scrub of obvious secrets before evidence leaves the local
    /// failure context (it is persisted into the proposal store and shown on a
    /// card). Not a security boundary — a defense-in-depth scrub of the
    /// patterns that actually show up in logs/snapshots.
    static func redactSecrets(_ s: String) -> String {
        var out = s
        let patterns = [
            // Provider key prefixes: sk-..., sk-ant-..., etc.
            "(?i)\\bsk-[A-Za-z0-9_-]{8,}",
            // Bearer tokens.
            "(?i)\\bBearer\\s+[A-Za-z0-9._-]{8,}",
            // GitHub-style tokens.
            "\\bgh[pousr]_[A-Za-z0-9]{8,}",
            // key/token/secret/password = "value" or : "value".
            "(?i)\"?(api[_-]?key|token|secret|password|authorization)\"?\\s*[:=]\\s*\"?[A-Za-z0-9._\\-/+]{6,}\"?",
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(
                in: out, range: range, withTemplate: "[REDACTED]")
        }
        return out
    }

    // MARK: - Helpers

    static func parseISO(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
            ?? {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: s)
            }()
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
