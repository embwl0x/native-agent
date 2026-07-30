import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

/// Weekly, app-owned, data-driven self-improvement pass.
///
/// Replaces the dead "sweep" janitor. Once per ~7 days (and only when the
/// `enableAutonomy` switch is on), it ingests a week of REAL usage — chat
/// transcripts, error logs, Doctor health, skill registry — asks the app's
/// OWN configured LLM (the same `LLMClient` every other loop uses, routed by
/// the `self_improvement` surface picker) what is failing / degrading /
/// underused, and turns the answer into one-tap-approvable proposals plus a
/// weekly digest.
///
/// Design notes:
/// - App-owned: the brain is `llm.complete(...)` (provider routing the chat
///   already uses), NOT codex or any developer-only tooling, so a downloader
///   with any provider configured gets it.
/// - Honest split: runtime-class findings (skills / prompts / config / memory)
///   are stageable for one-tap apply; code-class findings flow into the
///   injected `fileCodeFinding` lane (U2b: filed as `needs_diff` evolution
///   proposals on repo-stamped installs) and fall back to digest-only when
///   that lane is not wired (non-repo installs).
/// - Dependency-clean: staging + the enable-gate are injected closures, so
///   this loop needs no new module deps. BackgroundLoopsAssembly wires the real
///   ApprovalInbox + trust policy.
/// - tick() is non-throwing by LoopRunner contract. Operational failure is
///   returned through `tickOutcome()` so scheduler state and durable receipts
///   cannot claim the pass succeeded merely because the function returned.
public struct WeeklySelfImprovementLoop: LoopRunner {
    public let loopId: String = "self_improvement_sweep"
    public let interval: TimeInterval
    /// U5 W-D (2026-06-11): a tick ingests a week of usage and runs the
    /// weekly self-improvement LLM pass. The scheduler's default 300s budget
    /// cancels long LLM passes mid-call with no user-visible trace (audit
    /// 2026-06-09 — same lesson as telegram_poll / mission_executor; the
    /// mission-runner comment already cited a "self-improvement override" —
    /// this makes that claim true).
    public var tickTimeoutOverride: TimeInterval? { 3600 }

    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    /// The on/off switch. Wired to the `enableAutonomy` trust-policy flag.
    private let isEnabled: @Sendable () async -> Bool
    /// Stages one runtime-class proposal as a one-tap-approvable item.
    /// Wired by the assembly to `SwiftNativeApprovalInbox.create(...)`.
    ///
    /// 2026-07-23 FIX 3 (A4.5): `throws` so a failed staging write is
    /// OBSERVABLE. Previously `async -> Void` swallowed the write failure and
    /// the tick still returned `.completed("weekly proposals staged")` — a
    /// silent proposal drop. A throw now propagates to the outer catch, which
    /// rolls back the weekly marker (retry next tick) and returns `.failed`,
    /// tripping the manager's background_loop_failures.jsonl receipt net.
    private let stageProposal: @Sendable (SelfImprovementProposal) async throws -> Void
    /// U2b wave 2: code-class findings used to die in the digest ("a signed
    /// app can't recompile itself" — no longer true on a repo-stamped
    /// install). When wired, every code finding is ALSO handed here; the
    /// assembly files it into the EvolutionProposalStore as a `needs_diff`
    /// proposal. Injected closure so this module gains no SelfImprovement
    /// dep (same dependency-clean rule as stageProposal). nil → digest-only
    /// (the pre-U2b behavior, and the honest default for non-repo installs).
    private let fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)?
    /// MEASURE leg (north-star, 2026-06-15): a compact week-over-week
    /// mission-outcome summary so the self-improvement brain reasons over REAL
    /// job OUTCOMES (completion rate / steps / wall-time trend), not only
    /// chat/error/doctor proxies. Injected so this module gains no Missions dep
    /// (same dependency-clean rule as stageProposal); the assembly wires it to
    /// `SwiftNativeWorkshopRunner.weeklyOutcomeStats()`. Default "" → the signal
    /// is omitted (pre-MEASURE behavior, honest for installs with no missions).
    private let workshopOutcomes: @Sendable () async -> String

    public init(
        interval: TimeInterval = 7 * 24 * 60 * 60,
        llm: any LLMClient,
        router: any ProviderRoutingProtocol = SwiftNativeProviderRouting(),
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping @Sendable () async -> Bool,
        stageProposal: @escaping @Sendable (SelfImprovementProposal) async throws -> Void,
        fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)? = nil,
        workshopOutcomes: @escaping @Sendable () async -> String = { "" }
    ) {
        self.interval = interval
        self.llm = llm
        self.router = router
        self.dataRoot = dataRoot
        self.clock = clock
        self.isEnabled = isEnabled
        self.stageProposal = stageProposal
        self.fileCodeFinding = fileCodeFinding
        self.workshopOutcomes = workshopOutcomes
    }

    /// Requests one cadence-bypassing pass without deleting the canonical
    /// weekly stamp from a view. The request and the loop's stamp decision use
    /// the same cross-process lock, so a manual click cannot open a duplicate
    /// execution window beside a periodic/BGTask tick.
    public static func requestManualRun(dataRoot: URL) async throws -> String {
        let directory = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
        let marker = directory.appendingPathComponent("last_weekly_run")
        let request = directory.appendingPathComponent("manual_run_requested")
        let token = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(marker) {
            try Data(token.utf8).write(to: request, options: .atomic)
        }
        return token
    }

    /// Clears any unconsumed request after the one-shot caller has received a
    /// terminal/coalesced result. If the loop consumed it, this is a no-op.
    public static func clearManualRunRequest(dataRoot: URL, token: String) async throws {
        let directory = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
        let marker = directory.appendingPathComponent("last_weekly_run")
        let request = directory.appendingPathComponent("manual_run_requested")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(marker) {
            guard FileManager.default.fileExists(atPath: request.path) else { return }
            let current = try String(contentsOf: request, encoding: .utf8)
            if current == token {
                try FileManager.default.removeItem(at: request)
            }
        }
    }

    public func tickOutcome() async -> LoopTickOutcome {
        guard await isEnabled() else {
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: disabled (enableAutonomy off)\n".utf8
            ))
            return .skipped(reason: "autonomy disabled")
        }
        do {
            let now = clock()
            // Weekly idempotency: BOTH the BGTask and the in-app scheduler can
            // drive this loop. Without a marker a same-week double-tick would
            // re-run the analysis and stage duplicate proposals. Skip if we ran
            // within ~6 days (the same guard used by scheduled reflective work).
            let marker = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
                .appendingPathComponent("last_weekly_run")
            let manualRequest = marker.deletingLastPathComponent()
                .appendingPathComponent("manual_run_requested")
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Check-and-stamp under the cross-process file lock, BEFORE the
            // multi-minute LLM pass: check-then-stamp-after left a window
            // where a second driver (BGTask wake, the "run now" button) also
            // passed the 6-day guard and staged a full duplicate proposal
            // set (audit + gpt-5.5 review 2026-06-09). Restore the prior
            // stamp on failure so a failed pass doesn't suppress the retry. A
            // pending manual-run request forces this period (consumed inside
            // the lock so a click cannot open a duplicate window beside a tick).
            let nowStamp = ISO8601DateFormatter().string(from: now)
            let intervalFloor = interval - 24 * 60 * 60
            let reservation = await reserveOncePerPeriod(at: marker, stamp: nowStamp) { stored in
                let forced = FileManager.default.fileExists(atPath: manualRequest.path)
                if forced {
                    try FileManager.default.removeItem(at: manualRequest)
                    return false
                }
                guard let stamp = stored.flatMap(Self.parseISO) else { return false }
                return now.timeIntervalSince(stamp) < intervalFloor
            }
            let rollback: @Sendable () async -> Void
            switch reservation {
            case .alreadyReserved:
                return .skipped(reason: "weekly pass already committed")
            case .failed(let error):
                throw error
            case .reserved(_, let rb):
                rollback = rb
            }
            var passSucceeded = false
            // Inner do/catch replaces the old sync defer: the rollback is now
            // an async flock'd compare-and-restore (2026-07-21 audit), which a
            // defer cannot await. Any throw before passSucceeded restores the
            // marker so the next tick retries; the error then propagates to
            // the outer catch unchanged.
            do {
            var signals = try gatherSignals(now: now)
            // MEASURE leg: fold in the real Workshop execution-outcome trend (async — reads
            // mission.json off disk). Empty when there's no history, so the
            // prompt is unchanged on a fresh install.
            let outcomes = await workshopOutcomes()
            if !outcomes.isEmpty { signals += "\n\n" + outcomes }
            let pickedModel = await router.modelStringForSurface("self_improvement")
            let raw = try await llm.complete(
                prompt: Self.analysisPrompt(signals: signals, now: now),
                system: Self.systemPrompt,
                model: pickedModel,
                surface: "self_improvement"
            )
            // Non-JSON output is a FAILED pass, not "nothing found" — the old
            // collapse to (summary: prefix, proposals: []) consumed the weekly
            // window on garbage. Throwing here lets the restore-marker catch
            // below rerun the pass next tick.
            guard let result = Self.parseResult(raw) else {
                throw NSError(domain: "WeeklySelfImprovementLoop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "no parseable JSON object in LLM output (first 200 chars: \(raw.prefix(200)))"
                ])
            }
            for proposal in result.proposals where proposal.kind == .runtime {
                try await stageProposal(proposal)
            }
            // U2b wave 2: code findings get a lane instead of a dead end.
            // Same crash-window exposure as the runtime staging above (a
            // restored marker re-runs the whole pass): acceptable parity.
            if let fileCodeFinding {
                for proposal in result.proposals where proposal.kind == .code {
                    try await fileCodeFinding(proposal)
                }
            }
            // The pass IS the staging — mark success BEFORE the digest write.
            // A digest throw after staging used to restore the marker, so the
            // next tick re-ran the whole pass and DOUBLE-STAGED every
            // proposal. The digest is reporting, not the work: log-and-go.
            passSucceeded = true
            do {
                try writeDigest(result: result, outcomes: outcomes, now: now)
            } catch {
                FileHandle.standardError.write(Data(
                    "WeeklySelfImprovementLoop: digest write failed (proposals already staged): \(error)\n".utf8
                ))
            }
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: runtime=\(result.proposals.filter { $0.kind == .runtime }.count) code=\(result.proposals.filter { $0.kind == .code }.count)\n".utf8
            ))
            return .completed(result: "weekly proposals staged")
            } catch {
                if !passSucceeded { await rollback() }
                throw error
            }
        } catch {
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: tick failed: \(error)\n".utf8
            ))
            return .failed(error: String(describing: error))
        }
    }

    // MARK: - Signal collection

    /// Reads a week of real usage into a compact, LLM-readable summary.
    private func gatherSignals(now: Date) throws -> String {
        let weekAgo = now.addingTimeInterval(-interval)
        let fm = FileManager.default
        var sections: [String] = []

        // 1. Chat activity — volume + the user's own recent messages (where
        //    corrections / dissatisfaction show up).
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        var userMessages: [String] = []
        var totalMessages = 0
        var sessionCount = 0
        if let files = try? fm.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var sessionHadRecent = false
                for line in text.split(separator: "\n") {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    if let created = (obj["createdAt"] as? String).flatMap(Self.parseISO),
                       created < weekAgo { continue }
                    totalMessages += 1
                    sessionHadRecent = true
                    if (obj["role"] as? String) == "user",
                       let content = obj["content"] as? String,
                       userMessages.count < 40 {
                        userMessages.append(content.prefix(280).description)
                    }
                }
                if sessionHadRecent { sessionCount += 1 }
            }
        }
        sections.append("""
        ## Chat activity (last 7 days)
        Messages: \(totalMessages) across \(sessionCount) session(s).
        Recent user messages (look for corrections, repeated asks, frustration, things the assistant got wrong):
        \(userMessages.isEmpty ? "(none)" : userMessages.map { "- \($0)" }.joined(separator: "\n"))
        """)

        // 2. Errors logged this week.
        sections.append(Self.recentLines(
            at: dataRoot.appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("errors.jsonl"),
            since: weekAgo, label: "Error log (last 7 days)", limit: 30, fm: fm
        ))

        // 3. Doctor health.
        let doctorPath = dataRoot.appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("latest.json")
        if let text = try? String(contentsOf: doctorPath, encoding: .utf8) {
            sections.append("## Doctor health (latest)\n\(text.prefix(1500))")
        }

        // 4. Skills — which exist; an empty registry is itself a signal.
        let skillsPath = dataRoot.appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("registry.json")
        if let text = try? String(contentsOf: skillsPath, encoding: .utf8) {
            sections.append("## Skill registry\n\(text.prefix(1200))")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Tail of a JSONL log, keeping rows whose `createdAt`/`ts` is within the
    /// window (rows without a parseable timestamp are kept — better noisy than
    /// silently dropped).
    private static func recentLines(
        at url: URL, since: Date, label: String, limit: Int, fm: FileManager
    ) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "## \(label)\n(none)"
        }
        var kept: [String] = []
        for line in text.split(separator: "\n").reversed() {
            if kept.count >= limit { break }
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ts = (obj["createdAt"] as? String ?? obj["at"] as? String
                    ?? obj["ts"] as? String ?? obj["timestamp"] as? String).flatMap(parseISO)
                if let ts, ts < since { continue }
            }
            kept.append(line.prefix(280).description)
        }
        return "## \(label)\n\(kept.isEmpty ? "(none)" : kept.reversed().joined(separator: "\n"))"
    }

    // MARK: - LLM prompt

    static let systemPrompt = """
    You are the self-improvement analyst for NativeAgent, a native Mac + iOS AI \
    assistant app. You are given a week of the app's REAL usage data. Find \
    concrete, evidence-backed improvements — what is failing, degrading, \
    underused, or noisy. Do NOT invent problems; every finding must cite \
    specific evidence from the data. Prefer a few high-value findings over a \
    long list.

    Classify each finding as "runtime" or "code".

    A "runtime" finding MUST map to exactly one of these safe, reversible ops, \
    given as an "apply" object — these are the ONLY changes that get applied on \
    one-tap approval:
      {"op": "run_memory_hygiene"}                     // consolidate/clean memory
      {"op": "disable_skill", "target": "<skill id>"}  // turn a skill off
      {"op": "enable_skill",  "target": "<skill id>"}  // turn a skill on
    If a finding does NOT map to one of these ops, it is NOT runtime — classify \
    it "code" instead. Never invent ops or targets.

    A "code" finding needs a source change (or is a good idea with no applicable \
    op above). These are report-only — a shipped app cannot recompile itself.

    Respond with ONLY a JSON object, no prose:
    {
      "summary": "<2-3 sentence overview of the week>",
      "findings": [
        {
          "kind": "runtime",
          "title": "<short imperative>",
          "evidence": "<what in the data shows this>",
          "proposedChange": "<the specific change>",
          "apply": {"op": "disable_skill", "target": "<skill id>"}
        },
        {
          "kind": "code",
          "title": "<short imperative>",
          "evidence": "<evidence>",
          "proposedChange": "<what a developer should change>"
        }
      ]
    }
    """

    /// The ONLY ops a runtime proposal may carry. Each is safe, reversible, and
    /// already a user-triggerable action; applied only on explicit approval.
    static let applyOps: Set<String> = ["run_memory_hygiene", "disable_skill", "enable_skill"]

    static func analysisPrompt(signals: String, now: Date) -> String {
        """
        Here is NativeAgent's real usage for the week ending \(todayString(now)):

        \(signals)

        Analyze it and return the JSON described in the system prompt.
        """
    }

    // MARK: - Parsing

    struct Result: Sendable {
        var summary: String
        var proposals: [SelfImprovementProposal]
    }

    /// Returns nil when the raw output contains NO parseable JSON object —
    /// the caller must treat that as a failed pass (retry next tick), NOT as
    /// an empty "nothing found" result.
    static func parseResult(_ raw: String) -> Result? {
        // The model may wrap JSON in prose or a code fence; extract the object.
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let summary = obj["summary"] as? String ?? ""
        let rawFindings = obj["findings"] as? [[String: Any]] ?? []
        let proposals: [SelfImprovementProposal] = rawFindings.compactMap { f in
            guard let title = f["title"] as? String, !title.isEmpty else { return nil }
            let evidence = f["evidence"] as? String ?? ""
            let change = f["proposedChange"] as? String ?? ""
            switch f["kind"] as? String {
            case "runtime":
                // A staged runtime proposal MUST carry a valid, executable op —
                // otherwise its Approve button is a dead no-op. No valid op →
                // skip it (the model was told to mark such findings "code").
                guard let apply = f["apply"] as? [String: Any],
                      let op = apply["op"] as? String,
                      applyOps.contains(op),
                      !change.isEmpty else { return nil }
                let target = (apply["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                // Skill ops require a target; memory hygiene does not.
                if (op == "disable_skill" || op == "enable_skill") && target == nil { return nil }
                return SelfImprovementProposal(
                    kind: .runtime, title: title, evidence: evidence,
                    proposedChange: change, applyOp: op, applyTarget: target
                )
            case "code":
                return SelfImprovementProposal(
                    kind: .code, title: title, evidence: evidence, proposedChange: change
                )
            default:
                return nil   // unknown/missing class
            }
        }
        return Result(summary: summary, proposals: proposals)
    }

    // MARK: - Digest

    /// Writes the weekly digest (summary + every finding, runtime and code) to
    /// `<dataRoot>/self_improvement/digests/YYYY-MM-DD.md` for the UI/report.
    private func writeDigest(result: Result, outcomes: String, now: Date) throws {
        let dir = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var md = "# Self-Improvement Digest — \(Self.todayString(now))\n\n\(result.summary)\n"
        // MEASURE attribution: persist the week-over-week Workshop execution-outcome
        // snapshot AT THIS PASS into the durable digest, so a later reader can
        // tie this pass's proposals to what the number actually was when they
        // were made (the live scoreboard recomputes from current data; this is
        // the point-in-time record). Empty on installs with no Workshop execution history.
        if !outcomes.isEmpty {
            md += "\n\(outcomes)\n"
        }
        let runtime = result.proposals.filter { $0.kind == .runtime }
        let code = result.proposals.filter { $0.kind == .code }
        if !runtime.isEmpty {
            md += "\n## Staged for one-tap approval (runtime)\n"
            for p in runtime { md += "- **\(p.title)** — \(p.proposedChange)\n  - evidence: \(p.evidence)\n" }
        }
        if !code.isEmpty {
            md += "\n## Code findings (report only — needs a developer)\n"
            for p in code { md += "- **\(p.title)** — \(p.proposedChange)\n  - evidence: \(p.evidence)\n" }
        }
        let target = dir.appendingPathComponent("\(Self.todayString(now)).md")
        try md.data(using: .utf8)?.write(to: target, options: .atomic)
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

    static func todayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// One improvement the weekly analyzer found. `runtime` proposals carry a
/// safe, reversible `applyOp` and are staged for one-tap approval (approval
/// runs the op); `code` proposals are report-only.
public struct SelfImprovementProposal: Sendable {
    public enum Kind: Sendable { case runtime, code }
    public let kind: Kind
    public let title: String
    public let evidence: String
    public let proposedChange: String
    /// The applied-on-approval op. ONE of `WeeklySelfImprovementLoop.applyOps`.
    /// Non-nil for every staged runtime proposal (guaranteed by parseResult),
    /// nil for code/report findings.
    public let applyOp: String?
    public let applyTarget: String?

    public init(
        kind: Kind, title: String, evidence: String, proposedChange: String,
        applyOp: String? = nil, applyTarget: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.evidence = evidence
        self.proposedChange = proposedChange
        self.applyOp = applyOp
        self.applyTarget = applyTarget
    }
}
