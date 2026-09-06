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
// body under the same file lock, with the same verified pre-compaction backup,
// the same transcript validator, and the same durable replacement. What DOES
// change is where a failure goes — a background pass may never take a turn down
// with it, so failure is loud in the receipt and on stderr instead.

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

/// Decides which of {the pass finishing, the pass deadline} gets to release the
/// coordinator's claim. Exactly one of them wins, so a hung pass that finishes
/// long after its deadline can never release a LATER pass's claim.
actor ChatTranscriptAgingPassFinish {
    private var finished = false

    func claimFinish() -> Bool {
        guard !finished else { return false }
        finished = true
        return true
    }
}

extension SwiftNativeChatOrchestrationClient {
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
    func scheduleTranscriptAgingIfNeeded(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?
    ) {
        let config = autocompactionConfig
        guard config.enabled, config.agingEnabled else { return }
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
            // The claim MUST come back, whatever the body does. Previously a
            // throw, a cancellation, or an inline distiller that never returned
            // skipped the release and disabled aging for this session for the
            // life of the process. Two racers, exactly one release: whichever
            // of {completion, deadline} gets there first.
            let finish = ChatTranscriptAgingPassFinish()
            let pass = Task.detached(priority: .background) {
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
            // The deadline is DETACHED from the pass on purpose: cancelling a
            // task that ignores cancellation (an LLM call inside the distiller's
            // task group can) would otherwise hold the release hostage forever.
            // We cancel, release, and move on without waiting for it to notice.
            let deadline = Task.detached(priority: .background) {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.agingPassDeadlineSeconds * 1_000_000_000)
                    )
                } catch {
                    return  // the pass finished first
                }
                pass.cancel()
                if await finish.claimFinish() {
                    await ChatTranscriptAgingCoordinator.shared.release(safeSessionId)
                    FileHandle.standardError.write(Data(
                        "ChatSessionAging: pass exceeded \(Int(Self.agingPassDeadlineSeconds))s for \(safeSessionId); claim released\n".utf8
                    ))
                }
            }
            await pass.value
            deadline.cancel()
            if await finish.claimFinish() {
                await ChatTranscriptAgingCoordinator.shared.release(safeSessionId)
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
        now: @escaping @Sendable () -> Date,
        // Production passes the process-wide gate; a test passes its own so a
        // suite never has to mutate (or race on) the installed one.
        gate: BackgroundConsolidationGate = .shared,
        coordinator: ChatTranscriptAgingCoordinator = .shared
    ) async {
        switch await gate.evaluate(reason: agingGateReason) {
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
        let outcome: ChatSessionCompactionOutcome
        do {
            outcome = try await compactor.compactIfNeeded(
                sessionId: sessionId,
                model: model,
                surface: surface,
                runId: runId,
                providerID: providerID,
                trigger: agingTrigger,
                force: false,
                thresholdTokensOverride: boundaryTokens,
                keepTailFixed: true
            )
        } catch {
            // FAIL LOUD, off the critical path. The autocompactor refuses to
            // rewrite anything without a verified backup and refuses to compact
            // a corrupt transcript, so a throw here means NOTHING was replaced —
            // the transcript is exactly as the turn left it.
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
            return
        }
        guard outcome.compacted,
              config.distillEnabled,
              let summaryRowId = outcome.summaryRowId,
              let backupPath = outcome.backupPath
        else { return }

        // Distillation happens INSIDE this background pass rather than as a
        // second fire-and-forget hop off a turn: the recollection row is
        // finished before the pass reports done, which is what lets a test
        // await the effect and what keeps the mechanical text from being what
        // history renders in the meantime.
        await makeAgingDistiller(dataRoot: dataRoot, llm: llm, now: now).distill(
            sessionId: sessionId,
            summaryRowId: summaryRowId,
            backupPath: backupPath,
            messagesReplaced: outcome.messagesReplaced,
            turnModel: model,
            surface: surface,
            runId: runId
        )
    }

    /// SEAM (2026-09-01): the pre-turn backstop builds its own identical
    /// distiller inline in `ChatOrchestrationClient+MessagePersistence.swift`
    /// (`compactSession`), which is owned by another builder this wave. The two
    /// constructions must stay identical; when that file is next touched, both
    /// should call THIS one. Pinned by
    /// `ChatSessionAgingConsolidationTests.agingDistillerMatchesBackstopConstruction`.
    static func makeAgingDistiller(
        dataRoot: URL,
        llm: any LLMClient,
        now: @escaping @Sendable () -> Date
    ) -> ChatCompactionDistiller {
        ChatCompactionDistiller(
            dataRoot: dataRoot,
            pinnedModelResolver: { surface in
                await SwiftNativeProviderRouting(
                    dataRoot: dataRoot,
                    surfacesPathOverride: dataRoot
                        .appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("surfaces.json"),
                    activeProviderPathOverride: dataRoot
                        .appendingPathComponent("providers", isDirectory: true)
                        .appendingPathComponent("active.json")
                ).pinnedModelStringForSurface(surface)
            },
            llmComplete: { model, prompt in
                try await llm.complete(
                    prompt: prompt,
                    system: ChatCompactionDistiller.distillSystem,
                    model: model,
                    surface: ChatCompactionDistiller.distillSurface
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
