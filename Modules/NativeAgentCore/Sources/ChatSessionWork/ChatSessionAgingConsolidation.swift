import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace
// Blueprint: | `ChatSessionAgingConsolidation.swift` | Append-triggered aging at 85% keeps ~55% raw history and distills proportional consecutive chunks concurrently before one ordered commit; coordinator retains bodies and 300-second cancellation deadlines, releases claims only at body exit, closes admission and joins admitted bodies and deadlines at engine termination |

// Appends trigger background recollection at 85% of the threshold, keeping ~55%
// raw history through proportional concurrent distillation and one ordered commit.
// Foreground compaction waits on its own recollection; stale aging prefixes cannot
// replace it. Background failures are recorded without taking down a turn.

/// One aging pass per session at a time. Three lanes (text-compat, structured,
/// structured-stream) and rapid consecutive turns all reach the same transcript;
/// without this, two passes would queue on the file lock and the second would
/// re-consolidate what the first just wrote.
actor TranscriptConsolidationFlights {
    static let shared = TranscriptConsolidationFlights()

    private struct Flight {
        let body: Task<Void, Never>
        let deadline: Task<Void, Never>
    }
    private var inFlight: [String: Flight] = [:]
    private var stopped = false

    func stop() async {
        stopped = true
        let admitted = Array(inFlight.values)
        for flight in admitted {
            flight.body.cancel()
            flight.deadline.cancel()
        }
        await settle {
            for flight in admitted {
                await flight.body.value
                await flight.deadline.value
            }
        }
    }

    func start(_ sessionId: String, work: @escaping @Sendable () async -> Void) {
        guard !stopped, inFlight[sessionId] == nil else { return }
        let body = Task(priority: .background) {
            await work()
            self.release(sessionId)
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(ChatSessionAgingConsolidation.agingPassDeadlineSeconds)) }
            catch { return }
            guard !Task.isCancelled, !stopped, inFlight[sessionId] != nil else { return }
            body.cancel()
            FileHandle.standardError.write(Data(
                "ChatSessionAging: pass exceeded \(Int(ChatSessionAgingConsolidation.agingPassDeadlineSeconds))s for \(sessionId); cancellation requested, claim held until exit\n".utf8
            ))
        }
        inFlight[sessionId] = Flight(body: body, deadline: deadline)
    }

    private func release(_ sessionId: String) {
        inFlight.removeValue(forKey: sessionId)?.deadline.cancel()
    }
}

public struct ChatSessionAgingConsolidation: Sendable {
    public static func stop() async {
        await TranscriptConsolidationFlights.shared.stop()
    }
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
    /// Cancellation deadline for one aging pass. A non-cooperative body keeps
    /// its session claim until actual exit; expiry never admits a second pass.
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
            >= Int64(Double(boundaryTokens) * ContextBudgetPolicy.transcriptCharactersPerToken)
        else { return }

        let dataRoot = self.dataRoot
        let clock = self.clock
        let llm = self.llm
        Task.detached(priority: .background) {
            await TranscriptConsolidationFlights.shared.start(safeSessionId) {
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
        guard !Task.isCancelled else { return }

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
        guard !Task.isCancelled else { return }
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
                rows: outcome.recollectionSource,
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
            _ = await distiller.distillAhead(
                sessionId: sessionId,
                rows: fold.source,
                turnModel: model,
                surface: surface,
                runId: runId,
                stillCurrent: { try await compactor.agingFoldIsCurrent(fold) },
                commit: { blocks, distillModel in
                    let committed = try await compactor.commitAging(
                        fold,
                        recollection: blocks,
                        distillModel: distillModel,
                        model: model,
                        surface: surface,
                        runId: runId,
                        trigger: Self.agingTrigger
                    ).compacted
                    if committed {
                        await ChatCompactionDistiller.publishTranscriptChange(
                            sessionId: sessionId, dataRoot: dataRoot
                        )
                    }
                    return committed
                }
            )
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
            summaryRouteResolver: { surface in
                let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshot()
                let route = try snapshot.routeAdmission(for: surface, choice: nil, inheritChat: false)
                guard route.providerId?.isEmpty == false else {
                    throw ProviderRoutingError.configurationFailed(
                        snapshot.unusablePickNotice(for: surface) ?? "Choose a model and account for Memory and mind in Providers.")
                }
                return route
            },
            llm: llm,
            now: now
        )
    }

    private static func transcriptBytes(_ path: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
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
        await TurnTracePersistLane(dataRootOverride: dataRoot).append(
            TurnTraceEvent(kind: "context.compact", title: sessionId, status: status,
                payload: .object(payload), createdAt: ISO8601DateFormatter().string(from: now())))
    }
}
