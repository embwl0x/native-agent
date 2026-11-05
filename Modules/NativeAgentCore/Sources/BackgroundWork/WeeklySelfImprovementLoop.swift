import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import Cognition
import PersistenceCore
import DreamREMCycle
import ProviderRouting
// Blueprint: | `WeeklySelfImprovementLoop.swift` | `WeeklySelfImprovementLoop`; Shared reservation, checked proposals and digest |

/// Runtime findings stage approval; code findings use the builder queue or digest only.
/// Operational failures remain failed scheduler outcomes.
public struct WeeklySelfImprovementLoop: LoopRunner {
    public static let defaultPeriod: TimeInterval = 7 * 24 * 60 * 60
    public let loopId: String = "self_improvement_sweep"
    let period: TimeInterval
    public var wake: OrganWake { .every(period) }
    public var tickTimeoutOverride: TimeInterval? { 3600 }

    private let llm: any LLMClient
    let dataRoot: URL
    private let clock: @Sendable () -> Date
    private let isEnabled: @Sendable () async -> Bool
    /// Staging failures release the weekly reservation for retry.
    private let stageProposal: @Sendable (SelfImprovementProposal) async throws -> String
    /// The factory files code findings on the builder's queue; nil keeps them digest-only.
    private let fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)?
    /// The agent's jobs that ended lately; none omits the signal, unreadable jobs fail the pass.
    private let jobOutcomes: @Sendable () async throws -> String
    /// Missing prior learning contributes nothing; it cannot invent a correction.
    private let learning: @Sendable (_ previousCards: [String]?) async throws -> SelfImprovementLearning
    /// REM staging shares proposal failure semantics so incomplete learning cannot commit the pass.
    private let stageStandingLessons: @Sendable ([String: String]) async throws -> [String]

    public init(
        interval: TimeInterval = Self.defaultPeriod,
        llm: any LLMClient,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping @Sendable () async -> Bool,
        stageProposal: @escaping @Sendable (SelfImprovementProposal) async throws -> String,
        fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)? = nil,
        jobOutcomes: @escaping @Sendable () async throws -> String,
        learning: @escaping @Sendable (_ previousCards: [String]?) async throws -> SelfImprovementLearning = { _ in SelfImprovementLearning() },
        stageStandingLessons: @escaping @Sendable ([String: String]) async throws -> [String] = { _ in [] }
    ) {
        self.period = interval
        self.llm = llm
        self.dataRoot = dataRoot
        self.clock = clock
        self.isEnabled = isEnabled
        self.stageProposal = stageProposal
        self.fileCodeFinding = fileCodeFinding
        self.jobOutcomes = jobOutcomes
        self.learning = learning
        self.stageStandingLessons = stageStandingLessons
    }

    /// Share the stamp’s cross-process lock so a manual request cannot duplicate periodic or BGTask work.
    public static func requestManualRun(dataRoot: URL) async throws -> String {
        let directory = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
        let marker = directory.appendingPathComponent("last_weekly_run")
        let request = directory.appendingPathComponent("manual_run_requested")
        let token = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await SwiftNativePersistenceCore.withFileLock(marker) {
            try Data(token.utf8).write(to: request, options: .atomic)
        }
        return token
    }

    /// Clear only unconsumed requests after the caller receives its terminal or coalesced result.
    public static func clearManualRunRequest(dataRoot: URL, token: String) async throws {
        let directory = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
        let marker = directory.appendingPathComponent("last_weekly_run")
        let request = directory.appendingPathComponent("manual_run_requested")
        try await SwiftNativePersistenceCore.withFileLock(marker) {
            guard FileManager.default.fileExists(atPath: request.path) else { return }
            let current = try String(contentsOf: request, encoding: .utf8)
            if current == token {
                try FileManager.default.removeItem(at: request)
            }
        }
    }

    /// Its loop and the manual run both tick here, so the sweep beats here once per pass, worked with the cards it staged.
    public func tickOutcome() async -> LoopTickOutcome {
        let (outcome, staged) = await sweep()
        if case .skipped(let reason, _) = outcome, reason == Self.cancelledReason {
            OrganJudge.beat(loopId, .stopped, note: reason, cadence: wake.period)
        } else {
            OrganJudge.beat(loopId, tick: outcome, yield: staged, cadence: wake.period)
        }
        return outcome
    }

    static let cancelledReason = "weekly pass cancelled"

    private func sweep() async -> (outcome: LoopTickOutcome, staged: Int?) {
        guard await isEnabled() else {
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: disabled (enableAutonomy off)\n".utf8
            ))
            return (.off("self-improvement or unattended work switched off"), nil)
        }
        do {
            try Task.checkCancellation()
            let now = clock()
            // The shared period reservation prevents duplicate passes across scheduler drivers.
            let marker = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
                .appendingPathComponent("last_weekly_run")
            let manualRequest = marker.deletingLastPathComponent()
                .appendingPathComponent("manual_run_requested")
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Reserve under the cross-process lock before analysis; consume manual requests there too.
            // Failures release the reservation so the next tick can retry.
            let nowStamp = ISO8601DateFormatter().string(from: now)
            let intervalFloor = period - 24 * 60 * 60
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
                return (.skipped(reason: "weekly pass already committed"), nil)
            case .failed(let error):
                throw error
            case .reserved(_, let rb):
                rollback = rb
            }
            var passSucceeded = false
            var stagingStarted = false
            var produced: (raw: String, result: Result, outcomes: String)?
            var cards: [String] = []
            // Release the reservation on failure; cancellation after staging keeps it.
            do {
            try Task.checkCancellation()
            var signals = try await gatherSignals(now: now)
            // Empty execution history contributes no prompt section.
            let outcomes = try await jobOutcomes()
            try Task.checkCancellation()
            if !outcomes.isEmpty { signals += "\n\n" + outcomes }
            let learned = try await learning(previousPassCards())
            try Task.checkCancellation()
            if !learned.signals.isEmpty { signals += "\n\n" + learned.signals }
            if !learned.standing.isEmpty {
                signals += "\n\n## Standing lessons (recalled in nearly every conversation this week)\n"
                    + learned.standing.sorted { $0.key < $1.key }
                        .map { "- [\($0.key)] " + TurnSecretRedactor.redactText($0.value) }.joined(separator: "\n")
            }
            try Task.checkCancellation()
            let raw = try await llm.complete(
                prompt: Self.analysisPrompt(signals: signals, now: now),
                system: Self.systemPrompt,
                model: nil,
                tools: nil,
                call: LLMCall(turn: nil, surface: "self_improvement", purpose: "self_improvement")
            )
            // Invalid output fails the pass; retain the returned bytes in its failed digest.
            let parsed = Self.parseResult(raw)
            produced = (raw, parsed ?? Result(summary: "Unparseable model response", proposals: []), outcomes)
            guard var result = parsed else {
                throw NSError(domain: "WeeklySelfImprovementLoop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        """
                            invalid weekly analysis response: expected nonempty summary, findings with complete evidence/change and valid runtime operations, \
                            and standing lesson rows. Returned bytes are retained in the failed digest.
                            """
                ])
            }
            // Retain card ids so the next pass can follow their outcomes.
            try Task.checkCancellation()
            for proposal in result.proposals where proposal.kind == .runtime {
                try Task.checkCancellation()
                stagingStarted = true
                cards.append("approval:" + (try await stageProposal(proposal)))
                try Task.checkCancellation()
            }
            // Code findings use the same staging and retry boundary as runtime findings.
            if let fileCodeFinding {
                for proposal in result.proposals where proposal.kind == .code {
                    try Task.checkCancellation()
                    stagingStarted = true
                    try await fileCodeFinding(proposal)
                    try Task.checkCancellation()
                }
            }
            // Only lessons it was offered; an invented id stages nothing.
            result.standing = result.standing.filter { learned.standing[$0.key] != nil }
            if !result.standing.isEmpty {
                stagingStarted = true
                cards += try await stageStandingLessons(result.standing).map { "rem:" + $0 }
            }
            try Task.checkCancellation()
            // Staging commits the pass; a digest failure must not cause duplicate proposals.
            passSucceeded = true
            await saveDigest(result: result, raw: raw, outcomes: outcomes, cards: cards, now: now, terminal: "done")
            FileHandle.standardError.write(Data(
                """
                    WeeklySelfImprovementLoop: runtime=\(result.proposals.filter { $0.kind == .runtime }.count) \
                    code=\(result.proposals.filter { $0.kind == .code }.count)\n
                    """.utf8
            ))
            return (.completed(result: "weekly proposals staged"), cards.count)
            } catch {
                if let produced {
                    await saveDigest(result: produced.result, raw: produced.raw, outcomes: produced.outcomes,
                                     cards: cards, now: now,
                                     terminal: Task.isCancelled || error is CancellationError ? "stopped" : "failed: \(error)")
                }
                // Staged effects cannot be unstaged on cancellation; retain the reservation to prevent duplicates.
                if !passSucceeded && !(stagingStarted && (Task.isCancelled || error is CancellationError)) {
                    await rollback()
                }
                throw error
            }
        } catch is CancellationError {
            return (.skipped(reason: Self.cancelledReason), nil)
        } catch {
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: tick failed: \(error)\n".utf8
            ))
            return (.failed(error: String(describing: error)), nil)
        }
    }

    // MARK: - LLM prompt

    static var systemPrompt: String {
        get throws {
            try completionPolicy("weekly-improvement", section: "system", arguments: [REMProposalStore.growthPassageBoundSentence])
        }
    }

    /// Only safe reversible user-triggerable operations may be proposed, and explicit approval must precede application.
    static let applyOps: Set<String> = ["disable_skill", "enable_skill"]

    static func analysisPrompt(signals: String, now: Date) throws -> String {
        try completionPolicy("weekly-improvement", section: "prompt", arguments: [todayString(now), signals])
    }

    // MARK: - Parsing

    struct Result: Sendable {
        var summary: String
        var proposals: [SelfImprovementProposal]
        var standing: [String: String] = [:]
    }

    /// Invalid complete responses fail the pass; nil cannot mean that analysis found nothing.
    static func parseResult(_ raw: String) -> Result? {
        guard let fields = try? JSONValue.decodeCompletion(raw, as: [String: JSONValue].self) else { return nil }
        let obj = fields.mapValues(\.foundationObject)
        guard let summary = obj["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawFindings = obj["findings"] as? [[String: Any]],
              let rawStanding = obj["standing"] as? [[String: Any]] else { return nil }
        let proposals: [SelfImprovementProposal] = rawFindings.compactMap { f in
            guard let title = f["title"] as? String,
                  let evidence = f["evidence"] as? String,
                  let change = f["proposedChange"] as? String,
                  [title, evidence, change].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            switch f["kind"] as? String {
            case "runtime":
                // Reject runtime proposals without an executable op so approval cannot become a dead button.
                guard let apply = f["apply"] as? [String: Any],
                      let op = apply["op"] as? String,
                      applyOps.contains(op),
                      !change.isEmpty else { return nil }
                let target = (apply["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard target != nil else { return nil }
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
        guard proposals.count == rawFindings.count else { return nil }
        var standing: [String: String] = [:]
        for row in rawStanding {
            guard let id = row["memory_id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  standing[id] == nil,
                  let line = (row["line"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return nil }
            standing[id] = line
        }
        return Result(summary: summary, proposals: proposals, standing: standing)
    }

    // MARK: - Digest

    /// Retain every finding so the digest and UI share one pass’s evidence.
    private func saveDigest(result: Result, raw: String, outcomes: String, cards: [String], now: Date, terminal: String) async {
        await settle {
            do { try self.writeDigest(result: result, raw: raw, outcomes: outcomes, cards: cards, now: now, terminal: terminal) }
            catch {
                FileHandle.standardError.write(Data("WeeklySelfImprovementLoop: returned output/\(terminal) digest save failed: \(error)\n".utf8))
            }
        }
    }

    private func writeDigest(result: Result, raw: String, outcomes: String, cards: [String], now: Date, terminal: String) throws {
        let dir = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var md = "# Self-Improvement Digest — \(Self.todayString(now))\n\nOutcome: \(terminal)\n\n\(result.summary)\n"
        // Preserve the execution-outcome evidence as it stood when this pass made its proposals.
        if !outcomes.isEmpty {
            md += "\n\(outcomes)\n"
        }
        let runtime = result.proposals.filter { $0.kind == .runtime }
        let code = result.proposals.filter { $0.kind == .code }
        if !runtime.isEmpty {
            md += "\n## Runtime proposals (staged cards listed below)\n"
            for p in runtime { md += "- **\(p.title)** — \(p.proposedChange)\n  - evidence: \(p.evidence)\n" }
        }
        if !code.isEmpty {
            md += "\n## Code findings (report only — needs a developer)\n"
            for p in code { md += "- **\(p.title)** — \(p.proposedChange)\n  - evidence: \(p.evidence)\n" }
        }
        if !result.standing.isEmpty {
            md += "\n## Standing lesson proposals (staged cards listed below)\n"
            for line in result.standing.values.sorted() { md += "- \(line)\n" }
        }
        if !cards.isEmpty {
            md += "\n## Cards (the next pass follows these up)\n" + cards.map { "- card \($0)\n" }.joined()
        }
        let target = dir.appendingPathComponent("\(Self.todayString(now)).md")
        md += "\n## Returned model output\n\n" + raw + "\n"
        try Data(md.utf8).write(to: target, options: .atomic)
    }

    // MARK: - Helpers

    /// Follow the newest recorded digest; absence supplies no previous cards.
    private func previousPassCards() throws -> [String]? {
        let dir = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        guard let newest = names.filter({ $0.hasSuffix(".md") }).max() else { return nil }
        let text = try String(contentsOf: dir.appendingPathComponent(newest), encoding: .utf8)
        return text.split(separator: "\n").filter { $0.hasPrefix("- card ") }.map { String($0.dropFirst("- card ".count)) }
    }

    static func parseISO(_ s: String) -> Date? {
        NativeTimestampFormat.parseISO8601(s)
    }

    static func todayString(_ date: Date) -> String {
        NativeTimestampFormat.calendarDay(date)
    }
}

extension WeeklySelfImprovementLoop {
    @MainActor
    public static func runManually(
        dataRoot: URL, run: () async -> LoopTickOutcome
    ) async -> (outcome: LoopTickOutcome?, cleanupError: String?) {
        let token: String
        do { token = try await requestManualRun(dataRoot: dataRoot) }
        catch { return (nil, nil) }
        let outcome = await run()
        do {
            try await clearManualRunRequest(dataRoot: dataRoot, token: token)
            return (outcome, nil)
        } catch {
            return (outcome, error.localizedDescription)
        }
    }
}
