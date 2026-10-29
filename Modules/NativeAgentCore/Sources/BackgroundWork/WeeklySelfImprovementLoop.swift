import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import PersistenceCore
import DreamREMCycle
import ProviderRouting
// Blueprint: | `WeeklySelfImprovementLoop.swift` | `WeeklySelfImprovementLoop`: weekly/manual reservation, model synthesis, proposal validation, settlement and digest; EngineLaunch supplies Workshop outcomes through the maintenance part door; unavailable evidence fails the pass; DoctorFacade owns observed digest reads |

/// Weekly analysis of chat, live errors and Doctor health using the configured LLM.
/// Runtime findings stage approval cards; code findings use the injected builder queue
/// or remain digest-only. Operational failures return a failed scheduler outcome.
public struct WeeklySelfImprovementLoop: LoopRunner {
    public let loopId: String = "self_improvement_sweep"
    public let interval: TimeInterval
    /// A weekly analysis has an hour to read usage and complete its model call.
    public var tickTimeoutOverride: TimeInterval? { 3600 }

    private let llm: any LLMClient
    let dataRoot: URL
    private let clock: @Sendable () -> Date
    /// The owning factory combines the self-improvement switch and unattended-work authority.
    private let isEnabled: @Sendable () async -> Bool
    /// Stages a runtime proposal through the approval inbox and returns its card id.
    /// Write failures fail the pass and release the weekly reservation.
    private let stageProposal: @Sendable (SelfImprovementProposal) async throws -> String
    /// The factory files code findings on the builder's queue; nil keeps them digest-only.
    private let fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)?
    /// EngineLaunch supplies weekly execution outcomes through the maintenance part door.
    /// Empty history omits the signal; unavailable evidence fails the pass.
    private let workshopOutcomes: @Sendable () async throws -> String
    /// Previous-card outcomes, lesson misses and standing corrections; the default learns nothing.
    private let learning: @Sendable (_ previousCards: [String]?) async -> SelfImprovementLearning
    /// Stages the standing lessons the analyst wrote (memory id → GROWTH line)
    /// as REM cards and returns their REM proposal ids. Throws like `stageProposal`.
    private let stageStandingLessons: @Sendable ([String: String]) async throws -> [String]

    public init(
        interval: TimeInterval = 7 * 24 * 60 * 60,
        llm: any LLMClient,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping @Sendable () async -> Bool,
        stageProposal: @escaping @Sendable (SelfImprovementProposal) async throws -> String,
        fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)? = nil,
        workshopOutcomes: @escaping @Sendable () async throws -> String,
        learning: @escaping @Sendable (_ previousCards: [String]?) async -> SelfImprovementLearning = { _ in SelfImprovementLearning() },
        stageStandingLessons: @escaping @Sendable ([String: String]) async throws -> [String] = { _ in [] }
    ) {
        self.interval = interval
        self.llm = llm
        self.dataRoot = dataRoot
        self.clock = clock
        self.isEnabled = isEnabled
        self.stageProposal = stageProposal
        self.fileCodeFinding = fileCodeFinding
        self.workshopOutcomes = workshopOutcomes
        self.learning = learning
        self.stageStandingLessons = stageStandingLessons
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
        try await SwiftNativePersistenceCore.withFileLock(marker) {
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
        try await SwiftNativePersistenceCore.withFileLock(marker) {
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
            return .off("self-improvement or unattended work switched off")
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
            var stagingStarted = false
            var produced: (raw: String, result: Result, outcomes: String)?
            var cards: [String] = []
            // Release the reservation on failure; cancellation after staging keeps it.
            do {
            try Task.checkCancellation()
            var signals = try gatherSignals(now: now)
            // Empty execution history contributes no prompt section.
            let outcomes = try await workshopOutcomes()
            try Task.checkCancellation()
            if !outcomes.isEmpty { signals += "\n\n" + outcomes }
            let learned = await learning(previousPassCards())
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
                surface: "self_improvement", purpose: "self_improvement", tools: nil
            )
            // Invalid output fails the pass; retain the returned bytes in its failed digest.
            let parsed = Self.parseResult(raw)
            produced = (raw, parsed ?? Result(summary: "Unparseable model response", proposals: []), outcomes)
            guard var result = parsed else {
                throw NSError(domain: "WeeklySelfImprovementLoop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "invalid weekly analysis response: expected nonempty summary, findings with complete evidence/change and valid runtime operations, and standing lesson rows. Returned bytes are retained in the failed digest."
                ])
            }
            // The cards this pass leaves, by id: the next pass follows them up.
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
                "WeeklySelfImprovementLoop: runtime=\(result.proposals.filter { $0.kind == .runtime }.count) code=\(result.proposals.filter { $0.kind == .code }.count)\n".utf8
            ))
            return .completed(result: "weekly proposals staged")
            } catch {
                if let produced {
                    await saveDigest(result: produced.result, raw: produced.raw, outcomes: produced.outcomes,
                                     cards: cards, now: now,
                                     terminal: Task.isCancelled || error is CancellationError ? "stopped" : "failed: \(error)")
                }
                // Once staging begins, cancellation cannot unstage its effects.
                // Keep the reservation then so a retry cannot duplicate them.
                if !passSucceeded && !(stagingStarted && (Task.isCancelled || error is CancellationError)) {
                    await rollback()
                }
                throw error
            }
        } catch is CancellationError {
            return .skipped(reason: "weekly pass cancelled")
        } catch {
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: tick failed: \(error)\n".utf8
            ))
            return .failed(error: String(describing: error))
        }
    }

    // MARK: - LLM prompt

    static var systemPrompt: String {
        get throws {
            try completionPolicy("weekly-improvement", section: "system", arguments: [REMProposalStore.growthPassageBoundSentence])
        }
    }

    /// The ONLY ops a runtime proposal may carry. Each is safe, reversible, and
    /// already a user-triggerable action; applied only on explicit approval.
    static let applyOps: Set<String> = ["disable_skill", "enable_skill"]

    static func analysisPrompt(signals: String, now: Date) throws -> String {
        try completionPolicy("weekly-improvement", section: "prompt", arguments: [todayString(now), signals])
    }

    // MARK: - Parsing

    struct Result: Sendable {
        var summary: String
        var proposals: [SelfImprovementProposal]
        /// Memory id → the GROWTH line the analyst wrote for it.
        var standing: [String: String] = [:]
    }

    /// Returns nil unless the complete declared response is valid —
    /// the caller must treat that as a failed pass (retry next tick), NOT as
    /// an empty "nothing found" result.
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
                // A staged runtime proposal MUST carry a valid, executable op —
                // otherwise its Approve button is a dead no-op. No valid op →
                // invalidate the response (the model was told to classify it "code").
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

    /// Writes the weekly digest (summary + every finding, runtime and code) to
    /// `<dataRoot>/self_improvement/digests/YYYY-MM-DD.md` for the UI/report.
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

    /// The cards the newest digest already written recorded — the previous
    /// pass's. Nil when there is no earlier digest.
    private func previousPassCards() -> [String]? {
        let dir = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        guard let newest = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter({ $0.hasSuffix(".md") }).max(),
              let text = try? String(contentsOf: dir.appendingPathComponent(newest), encoding: .utf8) else { return nil }
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
