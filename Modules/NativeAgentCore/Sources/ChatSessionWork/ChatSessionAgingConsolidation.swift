import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Continuous consolidation — NORTHSTAR clause 4, sweep item 45 (2026-09-01).
//
// Compaction used to be a stop-the-world event on User's critical path: between
// persisting his message and building context, the turn measured the
// transcript, and at 200k tokens (or 40% of the model window) it backed up,
// distilled, replaced and — on any failure — ABORTED the turn. A threshold with
// a backup and a watchdog is the machinery clause 4 names.
//
// The inversion: older turns decay into recollection AS THEY AGE, off the
// critical path. The append that crosses the aging boundary schedules one
// background pass (no timer, no schedule, no budget — the signal reached it);
// by the time a session could approach the old threshold, its older turns are
// already recollection and the synchronous check finds nothing to do. The
// threshold stays exactly where it was, as a rare BACKSTOP, and every receipt
// now names which lane ran (`lane: aging` vs `lane: backstop`).
//
// What does NOT change: the aging pass runs the SAME `ChatSessionAutocompactor`
// selection and replacement, with the same verified pre-compaction backup, the
// same transcript validator, and the same durable write. What DOES change is
// where a failure goes — a background pass may never take a turn down with it,
// so failure is loud in the receipt and on stderr instead — and when the model
// works: aging distills BEFORE it replaces, with the transcript unlocked, so
// no turn ever waits on a background recollection (2026-10-19: a 114 s aging
// distill held User's next message, because the pass wrote its row pending
// first and the turn waited for it).

/// Verdict from the host's background-cognition gate.
public enum BackgroundConsolidationGateDecision: Sendable, Equatable {
    case allowed
    case deferred(String)
}

/// The seam through which the aging lane inherits the SAME throttle every other
/// background-cognition lane respects (low power, thermal pressure, organism
/// loop budget). The gate itself lives in the app runtime — the only place that
/// can see the host and the organism — and is installed once at launch.
/// Uninstalled (tests, CLI, headless tools) → allowed, so the lane is testable
/// without a body.
public final class BackgroundConsolidationGate: @unchecked Sendable {
    public typealias Gate = @Sendable (_ reason: String) async -> BackgroundConsolidationGateDecision

    public static let shared = BackgroundConsolidationGate()

    private let lock = NSLock()
    private var gate: Gate?

    public init() {}

    public func install(_ gate: @escaping Gate) {
        lock.lock()
        self.gate = gate
        lock.unlock()
    }

    /// Test seam: drop an installed gate so a suite cannot leak one into the next.
    public func uninstall() {
        lock.lock()
        gate = nil
        lock.unlock()
    }

    public func evaluate(reason: String) async -> BackgroundConsolidationGateDecision {
        guard let installed = installedGate() else { return .allowed }
        return await installed(reason)
    }

    // Read the installed gate OUTSIDE the async context: NSLock is unavailable
    // from one, and the gate must not be held across the await anyway.
    private func installedGate() -> Gate? {
        lock.lock()
        defer { lock.unlock() }
        return gate
    }
}

/// One aging pass per session at a time. Three lanes (text-compat, structured,
/// structured-stream) and rapid consecutive turns all reach the same transcript;
/// without this, two passes would queue on the file lock and the second would
/// re-consolidate what the first just wrote.
actor ChatTranscriptAgingCoordinator {
    static let shared = ChatTranscriptAgingCoordinator()

    private var inFlight: Set<String> = []
    private var lastDeferralReason: [String: String] = [:]

    func claim(_ sessionId: String) -> Bool {
        inFlight.insert(sessionId).inserted
    }

    func release(_ sessionId: String) {
        inFlight.remove(sessionId)
    }

    func isInFlight(_ sessionId: String) -> Bool {
        inFlight.contains(sessionId)
    }

    /// A deferral is the normal case while the Mac is hot or conserving, and it
    /// re-decides on every append past the boundary. Only a CHANGE is worth a
    /// receipt — otherwise the honest record of "not now" drowns the feed it
    /// belongs in. (Same reasoning as the pressure-dream lane's quiet decisions.)
    func shouldRecordDeferral(_ sessionId: String, reason: String) -> Bool {
        guard lastDeferralReason[sessionId] != reason else { return false }
        lastDeferralReason[sessionId] = reason
        return true
    }

    func clearDeferral(_ sessionId: String) {
        lastDeferralReason.removeValue(forKey: sessionId)
    }
}

public struct ChatSessionAgingConsolidation: Sendable {
    let dataRoot: URL
    let autocompactionConfig: ChatSessionAutocompactionConfig
    let llm: any LLMClient
    let clock: @Sendable () -> Date

    public init(
        dataRoot: URL,
        autocompactionConfig: ChatSessionAutocompactionConfig,
        llm: any LLMClient,
        clock: @escaping @Sendable () -> Date
    ) {
        self.dataRoot = dataRoot
        self.autocompactionConfig = autocompactionConfig
        self.llm = llm
        self.clock = clock
    }

    static let agingTrigger = "aging_boundary"
    static let agingGateReason = "transcript_aging:reflection"
    /// Wall-clock bound on ONE aging pass (backup + replace + one distillation
    /// call). Generous — this is a watchdog for a wedged pass, not a latency
    /// budget; a background pass that has taken this long is not coming back.
    static let agingPassDeadlineSeconds: Double = 300

    /// EVENT-DRIVEN entry: called on the turn's append, right after the
    /// synchronous backstop. Cheap enough to sit on the critical path (one
    /// stat(2) against the aging boundary) and returns immediately; the work
    /// itself is a detached background task the turn never awaits and that can
    /// never fail the turn.
    public func scheduleTranscriptAgingIfNeeded(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?
    ) {
        let config = autocompactionConfig
        guard config.agingEnabled else { return }
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return
        }
        let providerID = LLMCallContext.providerId
        let boundaryTokens = config.effectiveAgingThresholdTokens(
            forModel: model,
            providerID: providerID,
            dataRoot: dataRoot
        )
        let messagesPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        // The crossing test — the same file-size prefilter the backstop uses,
        // at the aging boundary. Below it, this append changed nothing that
        // matters and the turn moves on without spawning anything.
        guard Self.transcriptBytes(messagesPath)
            >= Int64(Double(boundaryTokens) * Self.agingTokenDivisor(forModel: model))
        else { return }

        let dataRoot = self.dataRoot
        let clock = self.clock
        let llm = self.llm
        Task.detached(priority: .background) {
            guard await ChatTranscriptAgingCoordinator.shared.claim(safeSessionId) else { return }
            var exceededDeadline = false
            do {
                try await TurnDeadline.withThrowingDeadline(seconds: Self.agingPassDeadlineSeconds) {
                    await Self.runTranscriptAging(
                        sessionId: safeSessionId,
                        model: model,
                        surface: surface,
                        runId: runId,
                        providerID: providerID,
                        boundaryTokens: boundaryTokens,
                        dataRoot: dataRoot,
                        config: config,
                        llm: llm,
                        now: clock
                    )
                }
            } catch {
                exceededDeadline = error is TurnDeadline.DeadlineExceeded
            }
            await ChatTranscriptAgingCoordinator.shared.release(safeSessionId)
            if exceededDeadline {
                FileHandle.standardError.write(Data(
                    "ChatSessionAging: pass exceeded \(Int(Self.agingPassDeadlineSeconds))s for \(safeSessionId); claim released\n".utf8
                ))
            }
        }
    }

    /// The background pass itself. Never throws: a consolidation failure is a
    /// loud receipt, never a dead turn.
    static func runTranscriptAging(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?,
        providerID: String?,
        boundaryTokens: Int,
        dataRoot: URL,
        config: ChatSessionAutocompactionConfig,
        llm: any LLMClient,
        now: @escaping @Sendable () -> Date
    ) async {
        let coordinator = ChatTranscriptAgingCoordinator.shared
        switch await BackgroundConsolidationGate.shared.evaluate(reason: agingGateReason) {
        case .deferred(let why):
            // Not a failure: the body is hot, asleep or conserving. The next
            // append past the boundary asks again.
            if await coordinator.shouldRecordDeferral(sessionId, reason: why) {
                await emitAgingTrace(
                    sessionId: sessionId,
                    surface: surface,
                    model: model,
                    runId: runId,
                    status: "deferred",
                    detail: why,
                    boundaryTokens: boundaryTokens,
                    dataRoot: dataRoot,
                    now: now
                )
            }
            return
        case .allowed:
            await coordinator.clearDeferral(sessionId)
        }

        let compactor = ChatSessionAutocompactor(dataRoot: dataRoot, config: config, now: now)
        let start: ChatSessionAutocompactor.AgingStart
        do {
            start = try await compactor.startAging(
                sessionId: sessionId,
                model: model,
                providerID: providerID,
                trigger: agingTrigger,
                thresholdTokens: boundaryTokens
            )
        } catch {
            // FAIL LOUD, off the critical path. The autocompactor refuses to
            // compact a corrupt transcript, and recovery may already have
            // settled an orphaned pending marker without changing its text.
            await reportAgingError(
                error, sessionId: sessionId, surface: surface, model: model, runId: runId,
                boundaryTokens: boundaryTokens, dataRoot: dataRoot, now: now
            )
            return
        }
        let distiller = makeAgingDistiller(dataRoot: dataRoot, llm: llm, now: now)
        switch start {
        case .nothing:
            return
        case .pending(let outcome):
            // A foreground compaction left this recollection owed; the turn
            // that needs it next would distill it anyway, so do it between
            // turns.
            guard let summaryRowId = outcome.summaryRowId,
                  let backupPath = outcome.backupPath
            else { return }
            await distiller.distill(
                sessionId: sessionId,
                summaryRowId: summaryRowId,
                backupPath: backupPath,
                messagesReplaced: outcome.messagesReplaced,
                turnModel: model,
                surface: surface,
                runId: runId
            )
        case .fold(let fold):
            // Distill FIRST, from the prefix as read, with the transcript
            // unlocked and unchanged: a turn arriving meanwhile reads its
            // history as it is and waits on nothing. Only the finished
            // recollection takes the lock, for a replacement that first
            // checks the prefix is still exactly what was distilled.
            let committed = await distiller.distillAhead(
                sessionId: sessionId,
                rows: fold.source,
                turnModel: model,
                surface: surface,
                runId: runId,
                stillCurrent: { try await compactor.agingFoldIsCurrent(fold) },
                commit: { text, distillModel in
                    try await compactor.commitAging(
                        fold,
                        recollection: text,
                        distillModel: distillModel,
                        model: model,
                        surface: surface,
                        runId: runId,
                        trigger: Self.agingTrigger
                    ).compacted
                }
            )
            if committed {
                await ChatCompactionDistiller.publishTranscriptChange(
                    sessionId: sessionId, dataRoot: dataRoot, persistence: compactor.persistence
                )
            }
        }
    }

    private static func reportAgingError(
        _ error: Error,
        sessionId: String,
        surface: String,
        model: String,
        runId: String?,
        boundaryTokens: Int,
        dataRoot: URL,
        now: @escaping @Sendable () -> Date
    ) async {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        await emitAgingTrace(
            sessionId: sessionId,
            surface: surface,
            model: model,
            runId: runId,
            status: "error",
            detail: detail,
            boundaryTokens: boundaryTokens,
            dataRoot: dataRoot,
            now: now
        )
        FileHandle.standardError.write(
            Data("ChatSessionAging: consolidation failed for \(sessionId): \(detail)\n".utf8)
        )
    }

    /// Shared distiller construction for background aging and foreground compaction.
    package static func makeAgingDistiller(
        dataRoot: URL,
        llm: any LLMClient,
        now: @escaping @Sendable () -> Date
    ) -> ChatCompactionDistiller {
        ChatCompactionDistiller(
            dataRoot: dataRoot,
            summaryModelResolver: { surface in
                try? await SwiftNativeProviderRouting(
                    dataRoot: dataRoot,
                    surfacesPathOverride: dataRoot
                        .appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("surfaces.json"),
                    activeProviderPathOverride: dataRoot
                        .appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("active.json")
                ).modelForSurface(surface).model
            },
            llmComplete: { model, prompt in
                try await llm.complete(
                    prompt: prompt,
                    system: ChatCompactionDistiller.distillSystem,
                    model: model,
                    surface: ChatCompactionDistiller.distillSurface, purpose: "compaction"
                )
            },
            now: now
        )
    }

    private static func transcriptBytes(_ path: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private static func agingTokenDivisor(forModel model: String) -> Double {
        model.lowercased().contains("claude") ? 3.5 : 4.0
    }

    /// Deferrals and failures of the background lane land on the SAME trace
    /// feed and schema as a compaction, so "what happened to consolidation"
    /// is one query. A successful pass emits its own `ok` row from inside the
    /// autocompactor; this only covers the outcomes that never get there.
    private static func emitAgingTrace(
        sessionId: String,
        surface: String,
        model: String,
        runId: String?,
        status: String,
        detail: String,
        boundaryTokens: Int,
        dataRoot: URL,
        now: @escaping @Sendable () -> Date
    ) async {
        let tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        var payload: [String: JSONValue] = [
            "schema": .string("context.compact.v1"),
            "sessionId": .string(sessionId),
            "surface": .string(surface),
            "trigger": .string(agingTrigger),
            "lane": .string("aging"),
            "reason": .string(detail),
            "model": .string(model),
            "thresholdTokens": .int(Int64(boundaryTokens)),
        ]
        if let runId, !runId.isEmpty {
            payload["runId"] = .string(runId)
        }
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("context.compact"),
            "title": .string(sessionId),
            "status": .string(status),
            "payload": .object(payload),
            "createdAt": .string(ISO8601DateFormatter().string(from: now())),
        ])
        do {
            try await appendPathOwnedJSONL(
                row,
                to: tracesPath,
                using: SwiftNativePersistenceCore(),
                logLabel: "ChatSessionAging"
            )
        } catch {
            FileHandle.standardError.write(
                Data("ChatSessionAging: trace append failed for \(sessionId): \(error)\n".utf8)
            )
        }
    }
}
