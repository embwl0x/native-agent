import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ToolExecution
import Privacy
import ProviderRouting
import NativeAgentShared
import ChatTurnContracts
// Blueprint: | `SwarmExecutor.swift` | `SwiftNativeAgentSwarmExecutor`: admission, worker execution, provider/model/tool access, concurrency, deadlines, cancellation, character-safe retention and partial outcomes; progress, terminal receipts and removal delegate to the shared runs owner. The originating app door calls `Resources/abilities/crew-instructions.js` through L0 `Parts.call` for briefs, synthesis messages and digest policy; preparation failure is explicit and settlement uses the prepared digest without starting JS after Stop |

public struct SwiftNativeAgentSwarmExecutor: Sendable {
    public let llm: any LLMClient
    public let routing: TurnRouteAdmission
    public let runsPath: URL
    public let workerClient: any SwarmChatClient
    public let turnTraceBus: TurnTraceBus?
    public let now: @Sendable () -> Date
    /// RunLedger data root; when unset, infer only from a `swarms` parent of runsPath, otherwise omit its row.
    public let runLedgerDataRoot: URL?

    public init(
        llm: any LLMClient,
        routing: TurnRouteAdmission,
        runsPath: URL = SwiftNativeSwarmRunsReader.defaultPath(),
        workerClient: any SwarmChatClient,
        turnTraceBus: TurnTraceBus? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        runLedgerDataRoot: URL? = nil
    ) {
        self.llm = llm
        self.routing = routing
        self.runsPath = runsPath
        self.workerClient = workerClient
        self.turnTraceBus = turnTraceBus
        self.now = now
        if let runLedgerDataRoot {
            self.runLedgerDataRoot = runLedgerDataRoot
        } else if runsPath.deletingLastPathComponent().lastPathComponent == "swarms" {
            self.runLedgerDataRoot = runsPath
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        } else {
            self.runLedgerDataRoot = nil
        }
    }

    public func runTool(input: [String: JSONValue], policy: AgentSwarmPolicy) async throws -> JSONValue {
        // A request refused while parsing started nothing: say so, so the
        // receipt reads effects none instead of "may have taken effect".
        let request: AgentSwarmRunRequest
        do {
            request = try AgentSwarmRunRequest.parse(input: input, policy: policy)
        } catch let refused as AgentSwarmError {
            throw ToolFailureError(refused.localizedDescription, effects: .none)
        }
        if request.dryRun {
            return request.planJSON(createdAt: AgentSwarmClock.nowISO(now()))
        }
        return try await run(request: request, policy: policy).json
    }

    public func run(request: AgentSwarmRunRequest, policy: AgentSwarmPolicy) async throws -> AgentSwarmRunResult {
        let runId = UUID().uuidString
        let startedDate = now()
        let createdAt = AgentSwarmClock.nowISO(startedDate)
        let startNs = DispatchTime.now().uptimeNanoseconds
        let live = SwarmLiveBoard(store: SwiftNativeSwarmRunsReader(runsPath: runsPath), id: runId,
                                  objective: request.objective, createdAt: createdAt,
                                  synthesize: request.synthesize,
                                  pending: request.workers.enumerated().map { $0.element.pendingJSON(index: $0.offset) })
        try await live.put(settled: [:])
        let workerResults = await executeWorkers(request: request, runId: runId, live: live)
        let synthesis = await synthesizeIfNeeded(request: request, workerResults: workerResults, runId: runId)
        let completedAt = AgentSwarmClock.nowISO(now())
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        let summary = AgentSwarmSummary(
            completed: workerResults.filter { $0.status == "completed" }.count,
            failed: workerResults.filter { $0.status != "completed" && $0.status != "cancelled" }.count,
            cancelled: workerResults.filter { $0.status == "cancelled" }.count
        )
        // Complete requires all workers and applicable synthesis; cancellation wins, otherwise mixed success/failure is partial.
        let synthesisFailed = synthesis.map { $0.status != "completed" } ?? false
        let runStatus: String
        if Task.isCancelled || summary.cancelled > 0 || synthesis?.status == "cancelled" {
            runStatus = "cancelled"
        } else if summary.completed == 0 {
            runStatus = "failed"
        } else if summary.failed > 0 || synthesisFailed {
            runStatus = "partial"
        } else {
            runStatus = "completed"
        }
        let result = AgentSwarmRunResult(
            id: runId,
            status: runStatus,
            runtime: "swift-native",
            createdAt: createdAt,
            completedAt: completedAt,
            elapsedMs: elapsedMs,
            objective: request.objective,
            mode: request.mode,
            requestedBy: request.requestedBy,
            agentCount: request.workers.count,
            maxAgents: AgentSwarmPolicy.hardMaxAgents,
            maxParallel: request.maxParallel,
            readOnly: request.readOnly,
            providerMode: "surface_routed",
            surface: "swarms",
            model: request.requestedModel,
            models: Array(Set(request.workers.map(\.model))).sorted(),
            reasoningEffort: request.reasoningEffort,
            access: request.readOnly ? "read_only" : (
                request.workers.allSatisfy { $0.access == "inherit" } ? "inherit" : "mixed"
            ),
            timeoutSeconds: request.timeoutSeconds,
            maxOutputChars: request.maxOutputChars,
            summary: summary,
            workers: workerResults,
            synthesis: synthesis,
            runsPath: runsPath.path
        )
        if policy.storeReceipts {
            // All child work has settled. Persist its terminal evidence in an
            // owned, awaited unstructured task: cancellation must not abort a
            // contended receipt lock and discard completed worker findings.
            // Task (not detached) preserves the caller's trace/task-local
            // context. This shield contains only persistence, never more work.
            let terminalPersistence = Task {
                try live.store.updateLive(id: runId, record: result.json)
                try SwiftNativeSwarmRunsReader(runsPath: runsPath).persist(result.json)
                // The summary follows the full receipt under the same shield;
                // it remains best-effort per RunLedger's existing contract.
                if let ledgerRoot = runLedgerDataRoot {
                    let ledgerError: String? = {
                        switch runStatus {
                        case "cancelled":
                            return "swarm cancelled; completed worker output is retained, but interrupted effects are not verified"
                        case "failed":
                            return synthesis?.error ?? "all \(summary.failed) worker(s) failed"
                        case "partial":
                            if synthesisFailed {
                                return synthesis?.error ?? "swarm synthesis failed"
                            }
                            return "\(summary.failed) of \(workerResults.count) worker(s) failed"
                        default:
                            return nil
                        }
                    }()
                    await RunLedger.append(
                        id: runId,
                        kind: "swarm",
                        status: runStatus == "completed" ? "succeeded" : runStatus,
                        model: request.requestedModel,
                        reasoningEffort: request.reasoningEffort,
                        prompt: request.objective,
                        output: synthesis?.output.isEmpty == false
                            ? synthesis?.output
                            : "\(summary.completed) worker(s) completed, \(summary.failed) failed, \(summary.cancelled) cancelled",
                        error: ledgerError,
                        createdAt: startedDate,
                        durationSeconds: Double(elapsedMs) / 1000.0,
                        dataRoot: ledgerRoot
                    )
                }
            }
            do {
                try await terminalPersistence.value
            } catch {
                throw AgentSwarmReceiptPersistenceError(
                    runID: runId, runStatus: runStatus, summary: summary, underlyingError: error
                )
            }
        }
        // Off the board only once the receipt holds it, so a reader never sees it vanish.
        try await live.remove()
        return result
    }

    private func executeWorkers(
        request: AgentSwarmRunRequest,
        runId: String,
        live: SwarmLiveBoard
    ) async -> [AgentSwarmWorkerResult] {
        var results = Array<AgentSwarmWorkerResult?>(repeating: nil, count: request.workers.count)
        await withTaskGroup(of: (Int, AgentSwarmWorkerResult).self) { group in
            var nextIndex = 0
            let initial = min(request.maxParallel, request.workers.count)
            for _ in 0..<initial where !Task.isCancelled {
                let idx = nextIndex
                nextIndex += 1
                group.addTask {
                    let worker = request.workers[idx]
                    return (idx, await self.runWorker(index: idx, worker: worker, request: request, runId: runId))
                }
            }
            var settled: [Int: JSONValue] = [:]
            while let (idx, result) = await group.next() {
                results[idx] = result
                settled[idx] = result.json
                do { try await live.put(settled: settled) }
                catch { fputs("[SwarmLiveBoard] progress persistence failed for \(runId): \(error)\n", stderr) }
                if Task.isCancelled {
                    group.cancelAll()
                } else if nextIndex < request.workers.count {
                    let enqueueIndex = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let worker = request.workers[enqueueIndex]
                        return (
                            enqueueIndex,
                            await self.runWorker(index: enqueueIndex, worker: worker, request: request, runId: runId)
                        )
                    }
                }
            }
        }
        return results.enumerated().map { idx, result in
            result ?? AgentSwarmWorkerResult(
                id: "\(runId)-\(String(format: "%02d", idx + 1))",
                index: idx + 1,
                name: request.workers[idx].name,
                role: request.workers[idx].role,
                model: request.workers[idx].model,
                requestedModel: request.workers[idx].model,
                reasoningEffort: request.workers[idx].reasoningEffort,
                access: request.workers[idx].access,
                status: Task.isCancelled ? "cancelled" : "failed",
                output: "",
                outputTruncated: false,
                error: Task.isCancelled
                    ? "worker not started because the parent swarm was cancelled"
                    : "worker did not return a result",
                durationSeconds: 0,
                findingsCap: request.workers[idx].findingsCap,
                contextSlice: request.workers[idx].contextSlice
            )
        }
    }

    private func runWorker(
        index: Int,
        worker: AgentSwarmWorkerSpec,
        request: AgentSwarmRunRequest,
        runId: String
    ) async -> AgentSwarmWorkerResult {
        let started = Date()
        let workerId = SwiftNativeSwarmRunsReader.workerReportID(runID: runId, index: index)
        var result = AgentSwarmWorkerResult(
            id: workerId,
            index: index + 1,
            name: worker.name,
            role: worker.role,
            model: worker.model,
            requestedModel: worker.model,
            reasoningEffort: worker.reasoningEffort,
            access: worker.access,
            status: "",
            output: "",
            outputTruncated: false,
            error: nil,
            durationSeconds: 0,
            findingsCap: worker.findingsCap,
            contextSlice: worker.contextSlice
        )
        do {
            try Task.checkCancellation()
            let brief: PreparedMessage = try await craft(.object([
                "operation": .string("worker"), "objective": .string(request.objective),
                "mode": .string(request.mode), "worker": worker.planJSON(index: index),
                "findingsCap": worker.findingsCap.map { .string(String($0)) } ?? .null
            ]))
            let output = try await withTimeout(seconds: request.timeoutSeconds, reportID: workerId) {
                if worker.access == "inherit" {
                    return try await workerClient.runSwarmToolTurn(
                        message: brief.prompt,
                        model: worker.model,
                        reasoningEffort: worker.reasoningEffort,
                        providerID: routing.providerId,
                        serviceTier: routing.serviceTier ?? "default",
                        sessionID: request.originSessionId,
                        surface: request.requestedBy
                    )
                }
                return try await withPromptCallTrace(runId: runId, reportId: workerId, traceId: workerId, request: request) {
                    try await routing.withModelContext(model: worker.model, reasoningEffort: worker.reasoningEffort) {
                        try await llm.complete(
                            prompt: brief.prompt,
                            system: brief.system,
                            model: worker.model,
                            surface: "swarms", purpose: "swarm", tools: nil
                        )
                    }
                }
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentSwarmError.invalidRequest("swarm worker returned no usable output")
            }
            let bounded = Self.bound(output, maxChars: request.maxOutputChars)
            result.status = Task.isCancelled ? "cancelled" : "completed"
            result.output = bounded.text
            result.outputTruncated = bounded.truncated
            result.error = Task.isCancelled
                ? "worker returned after cancellation; output is retained as evidence, not verified completion"
                : nil
        } catch {
            let incomplete = error as? EphemeralToolTurnIncomplete
            let retained = Self.bound(incomplete?.output ?? "", maxChars: request.maxOutputChars)
            result.status = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            result.output = retained.text
            result.outputTruncated = retained.truncated
            result.error = Task.isCancelled || error is CancellationError
                ? "worker cancelled; any effects already attempted remain unverified"
                : incomplete?.reason ?? Self.errorMessage(error)
        }
        result.durationSeconds = Date().timeIntervalSince(started)
        return result
    }

    /// Prompt-only calls have no ephemeral chat turn to create trace identity.
    /// Workers use their exact receipt id; synthesis uses `<runId>-synthesis`.
    /// Link IDs only: never prompts, output, or paths. Tool workers own their trace.
    private func withPromptCallTrace<T: Sendable>(
        runId: String, reportId: String, traceId: String, request: AgentSwarmRunRequest,
        operation: () async throws -> T
    ) async rethrows -> T {
        let parentTurnId = TurnTraceContext.turnId
        let bus = TurnTraceContext.bus ?? turnTraceBus
        return try await TurnTraceContext.$bus.withValue(bus) {
            try await TurnTraceContext.$turnId.withValue(traceId) {
                if let bus {
                    var payload: [String: JSONValue] = ["swarmRunId": .string(runId), "reportId": .string(reportId)]
                    if let parentTurnId { payload["parentTurnId"] = .string(parentTurnId) }
                    TurnTraceBus.fireFromContext(kind: "swarm.report.started", sessionId: request.originSessionId,
                                                 surface: "swarms", payload: .object(payload), on: bus)
                }
                return try await operation()
            }
        }
    }

    private func synthesizeIfNeeded(
        request: AgentSwarmRunRequest,
        workerResults: [AgentSwarmWorkerResult],
        runId: String
    ) async -> AgentSwarmSynthesis? {
        guard request.synthesize, workerResults.count > 1 else { return nil }
        // An empty/failed fan-out contains no findings worth another provider
        // call. Cancellation must not start a new synthesis after Stop/steer.
        guard !Task.isCancelled,
              workerResults.contains(where: { $0.status == "completed" }) else {
            return AgentSwarmSynthesis(
                model: request.synthesisModel,
                status: "skipped",
                output: "",
                outputTruncated: false,
                error: Task.isCancelled
                    ? "synthesis skipped because the parent swarm was cancelled"
                    : "synthesis skipped because no worker returned usable findings",
                durationSeconds: 0
            )
        }
        let started = Date()
        do {
            let brief: PreparedMessage = try await craft(.object([
                "operation": .string("synthesis"), "objective": .string(request.objective),
                "workers": .array(workerResults.map(\.json)),
                "maxOutputChars": .int(Int64(request.maxOutputChars)),
                "digestBudgetTokens": request.digestBudgetTokens.map { .string(String($0)) } ?? .null
            ]))
            return await synthesize(brief: brief, request: request, runId: runId, started: started)
        } catch {
            return AgentSwarmSynthesis(model: request.synthesisModel,
                status: Task.isCancelled || error is CancellationError ? "cancelled" : "failed",
                output: "", outputTruncated: false, error: Self.errorMessage(error),
                durationSeconds: Date().timeIntervalSince(started))
        }
    }

    private func synthesize(brief: PreparedMessage, request: AgentSwarmRunRequest,
        runId: String, started: Date) async -> AgentSwarmSynthesis {
        do {
            let output = try await withTimeout(seconds: request.timeoutSeconds, reportID: "\(runId)-synthesis") {
                try await withPromptCallTrace(runId: runId, reportId: "synthesis", traceId: "\(runId)-synthesis", request: request) {
                    try await routing.withModelContext(model: request.synthesisModel, reasoningEffort: request.reasoningEffort) {
                        try await llm.complete(
                            prompt: brief.prompt,
                            system: brief.system,
                            model: request.synthesisModel,
                            surface: "swarms", purpose: "swarm", tools: nil
                        )
                    }
                }
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentSwarmError.invalidRequest("swarm synthesis returned no usable output")
            }
            let bounded = Self.bound(output, maxChars: request.maxOutputChars)
            let digested = brief.digest(bounded.text)
            return AgentSwarmSynthesis(
                model: request.synthesisModel,
                status: Task.isCancelled ? "cancelled" : "completed",
                output: digested.text,
                outputTruncated: bounded.truncated || digested.truncated,
                error: Task.isCancelled ? "synthesis returned after cancellation" : nil,
                durationSeconds: Date().timeIntervalSince(started)
            )
        } catch {
            let incomplete = error as? EphemeralToolTurnIncomplete
            let bounded = Self.bound(incomplete?.output ?? "", maxChars: request.maxOutputChars)
            let digested = brief.digest(bounded.text)
            return AgentSwarmSynthesis(
                model: request.synthesisModel,
                status: Task.isCancelled || error is CancellationError ? "cancelled" : "failed",
                output: digested.text,
                outputTruncated: bounded.truncated || digested.truncated,
                error: incomplete?.reason ?? Self.errorMessage(error),
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
    }

    private enum DeadlineEvent: Sendable {
        case result(Result<String, Error>)
        case expired
        case cancelled
    }

    // Cancellation is a request, not proof of settlement. Keep structured
    // ownership until the worker returns; preserve late evidence as incomplete.
    func withTimeout(
        seconds: Int,
        reportID: String,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: DeadlineEvent.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                do {
                    try Task.checkCancellation()
                    return .result(.success(try await operation()))
                } catch { return .result(.failure(error)) }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds)) * 1_000_000_000)
                    return .expired
                } catch { return .cancelled }
            }
            var expired = false
            while let event = try await group.next() {
                switch event {
                case .expired:
                    expired = true
                    group.cancelAll()
                    if let bus = TurnTraceContext.bus ?? turnTraceBus {
                        TurnTraceBus.fire(TurnTraceEvent(turnId: reportID,
                            kind: "swarm.report.deadline_exceeded", surface: "swarms",
                            payload: .object(["reportId": .string(reportID),
                                "timeoutSeconds": .int(Int64(seconds)),
                                "state": .string("cancellation_requested_awaiting_settlement")])), on: bus)
                    }
                case .cancelled:
                    group.cancelAll()
                case .result(let result):
                    if expired {
                        let output: String
                        switch result {
                        case .success(let text): output = text
                        case .failure(let error): output = (error as? EphemeralToolTurnIncomplete)?.output ?? ""
                        }
                        throw EphemeralToolTurnIncomplete(output: output,
                            reason: "deadline exceeded (\(seconds)s); cancellation requested and worker settlement awaited; late output is evidence, not verified completion")
                    }
                    return try result.get()
                }
            }
            throw CancellationError()
        }
    }

    /// Preparation uses the originating app door inherited from the swarm call.
    /// This part has no provider or tool reach; execution keeps its admitted route.
    private func craft(_ input: JSONValue) async throws -> PreparedMessage {
        let root: URL
        switch runLedgerDataRoot {
        case .some(let available): root = available
        case .none:
            throw PartCallError(code: "unavailable",
                message: "The swarm's data root is unavailable; crew-instructions was not run.")
        }
        switch await Parts(root: root).call(id: "crew-instructions",
            input: input.mapStrings(NativeAgentSecretRedactor.redactText), as: PreparedMessage.self) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private struct PreparedMessage: Codable, Sendable {
        let prompt: String
        let system: String
        let digestLimit: UInt
        let digestNotice: String

        // Character-safe retention and terminal evidence stay native, including
        // partial output after Stop. The part chooses the bound and its wording
        // before provider work starts; settlement never starts another part.
        func digest(_ text: String) -> (text: String, truncated: Bool) {
            let bounded = SwiftNativeAgentSwarmExecutor.bound(text, maxChars: Int(clamping: digestLimit))
            return (bounded.text + (bounded.truncated ? digestNotice : ""), bounded.truncated)
        }
    }

    private static func bound(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        if text.count <= maxChars {
            return (text, false)
        }
        return (String(text.prefix(maxChars)), true)
    }

    private static func errorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }
}
