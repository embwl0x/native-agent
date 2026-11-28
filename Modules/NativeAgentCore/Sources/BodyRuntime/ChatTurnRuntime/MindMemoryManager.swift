import NativeAgentCore
import MindCore
import Foundation
import NativeAgentShared
import ProviderRouting
import SenseCore
import PersistenceCore
import DeskCore
// Blueprint: | `MindMemoryManager.swift` | One judgment per moment, evidence-backed intention outcomes, promise matching and recall |

public struct MindMemoryJudgment: MemoryManaging {
    private let makeLLMClient: @Sendable () -> any LLMClient
    private let relevanceCache = RecallJudgmentCache()

    private struct RecallRoute: Sendable, Equatable {
        let snapshot: ProviderRoutingSnapshot
        let surface: String
        let admission: TurnRouteAdmission
        var model: String { admission.modelId }
        let payloadByteCap: Int
    }

    private struct RecallCacheScope: Sendable, Equatable {
        let generation: String
        let route: RecallRoute
    }

    private struct RecallPage: Sendable {
        let key: String
        let id: String
        let encodedRow: String
    }

    private actor RecallJudgmentCache {
        private var scope: RecallCacheScope?
        private var judgments: [String: Bool] = [:]

        func read(scope: RecallCacheScope, keys: [String]) -> [String: Bool] {
            if self.scope != scope {
                self.scope = scope
                judgments.removeAll(keepingCapacity: true)
            }
            return Dictionary(keys.compactMap { key in
                judgments[key].map { (key, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }

        func store(scope: RecallCacheScope, judgments: [String: Bool]) {
            guard self.scope == scope else { return }
            if self.judgments.count + judgments.count > 4_096 {
                self.judgments.removeAll(keepingCapacity: true)
            }
            for (key, value) in judgments.prefix(4_096) { self.judgments[key] = value }
        }
    }

    public init(makeLLMClient: @escaping @Sendable () -> any LLMClient) {
        self.makeLLMClient = makeLLMClient
    }

    private static func reason(_ error: Error, cause: ProviderFailure?) -> AfterTurnMemoryFailure.Reason {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if (error as? ProviderFailure.Diagnostic)?.deadlineExpired == true { return .deadline }
        if let error = error as? URLError, error.code == .timedOut { return .deadline }
        switch cause {
        case .authExpired: return .authExpired
        case .codexCLISessionExpired: return .codexCLISessionExpired
        case .rateLimited: return .rateLimited
        case .quotaExceeded, .billingNotConfigured: return .provider
        case .overloaded: return .overloaded
        case .contextTooLong: return .contextTooLong
        case .network, .offline: return .network
        case .noReply: return .deadline
        case .outputLimit: return .outputLimit
        case .refused: return .refused
        case .requestRejected: return .requestRejected
        case .malformedResponse: return .invalidProviderResponse
        case .routingUnavailable: return .routingUnavailable
        case .modelUnavailable: return .modelUnavailable
        case nil: return .provider
        }
    }

    /// Recovery follows the failed judgment, not a diagnosis inferred from its prose.
    private static let recallEncodingRecovery = """
        The recall query and evidence could not be encoded as JSON: a NativeAgent defect in this turn's input, not your memories or the model. This \
        turn's recall judgment could not run; tell the person if it repeats. Changing the selected model cannot fix it.
        """

    private static func judgmentRecovery(_ reason: AfterTurnMemoryFailure.Reason, surface: String, detail: String? = nil) -> String {
        let group = (ProviderSurfaceGroups.group(for: surface) ?? ProviderSurfaceGroups.chat).id
        let model = "app {action:\"setting.get\",args:{setting:\"providers.\(group)_model\"}}"
        let account = "app {action:\"setting.get\",args:{setting:\"providers.\(group)_account\"}}"
        let fix: String
        switch reason {
        case .cancelled:
            fix = "The judgment was cancelled. Leave it stopped; no settings repair is indicated."
        case .invalidJSON, .missingSections, .invalidCaring, .invalidAffect, .invalidMemories, .invalidCares,
             .invalidProviderResponse:
            fix = """
                The judgment did not return its required JSON shape (\(reason.rawValue)); do not treat it as an empty judgment. Inspect the selected \
                model with \(model); repair its structured response before relying on another pass.
                """
        case .contextTooLong:
            fix = """
                The judgment input exceeds the selected model's window. Shorten the query or select a larger-window model through \(model); repeating \
                the same input will not fix it.
                """
        case .authExpired, .codexCLISessionExpired:
            fix = "The judgment account needs sign-in. Read \(account), then reconnect it in Providers → Accounts using Add key or Sign in."
        case .routingUnavailable:
            fix = "The saved judgment route is unavailable. Read \(account) and repair the reported routing error before another pass."
        case .modelUnavailable:
            fix = "The selected judgment model is unavailable. Read \(model) and select a model served by its account."
        case .trustUnavailable:
            fix = """
                The saved Trust policy could not be read or validated. Preserve its bytes and repair Trust before another judgment; a model change \
                cannot repair authority storage.
                """
        case .network:
            fix = "The judgment connection failed. Restore network access before requesting another pass; \(account) identifies its provider."
        case .rateLimited, .overloaded, .deadline:
            fix = """
                The provider could not complete this judgment (\(reason.rawValue)). Leave the result unresolved; \(model) shows the model choice if a \
                different supported route is needed.
                """
        case .refused:
            fix = """
                The provider refused this judgment. Leave it unresolved; offer an allowed alternative or stop, without rephrasing or splitting to \
                bypass refusal.
                """
        case .outputLimit:
            fix = """
                The judgment reached its output limit. Leave it unresolved; reduce the judgment input or use a model with a larger output allowance \
                before another pass.
                """
        case .requestRejected:
            fix = "The provider rejected this judgment request. Leave it unresolved; correct the reported request error before another pass."
        case .provider:
            fix = "The judgment provider failed. Read \(account), then resolve the reported provider cause before another pass."
        }
        return detail.map { $0 + " " + fix } ?? fix
    }

    public func relevantRecallIDs(query: String, candidates: [MemoryManagerExistingMemory], generation: String? = nil, topK: Int? = nil, turn: Turn?) async
        -> Result<Set<String>, AfterTurnMemoryFailure> {
        let started = ProcessInfo.processInfo.systemUptime
        // Judge the embedding's bounded ranking prefix; lower rows already lost relevance.
        let candidates = topK.map { requested in
            let limit = MemoryRecallScoring.relevanceCandidateLimit(topK: requested, count: candidates.count)
            return Array(candidates.prefix(limit))
        } ?? candidates
        let route: RecallRoute
        switch await recallJudgmentRoute() {
        case .failure(let failure): return .failure(failure)
        case .success(let selected): route = selected
        }
        let surface = route.surface
        let payloadByteCap = route.payloadByteCap
        let routeFinished = ProcessInfo.processInfo.systemUptime
        guard payloadByteCap > 0 else { return .failure(Self.recallJudgmentFailure(.contextTooLong, route: route)) }
        guard let encodedQuery = try? JSONSerialization.data(withJSONObject: query, options: [.fragmentsAllowed]) else {
            return .failure(Self.recallJudgmentFailure(.invalidJSON, route: route))
        }
        let queryJSON = String(decoding: encodedQuery, as: UTF8.self)
        let envelopeBytes = "{\"memories\":[],\"query\":\(queryJSON)}".utf8.count
        let progress = RecallJudgmentProgress()
        let scope = generation.map { RecallCacheScope(generation: $0, route: route) }
        let result = await collectRecallJudgments(query: query, queryJSON: queryJSON, candidates: candidates, topK: topK,
            envelopeBytes: envelopeBytes, route: route, scope: scope, turn: turn, progress: progress)
        reportRecallJudgment(progress.metrics, started: started, routeFinished: routeFinished, surface: surface, payloadByteCap: payloadByteCap)
        switch result {
        case .failure(let failure): return .failure(failure)
        case .success(let completed):
            guard !Task.isCancelled else { return .failure(Self.recallJudgmentFailure(.cancelled, route: route)) }
            if let scope { await relevanceCache.store(scope: scope, judgments: completed) }
            return .success(Set(completed.filter(\.value).compactMap { progress.recordIDs[$0.key] }))
        }
    }

    private struct RecallJudgmentMetrics {
        var preparedPages = 0
        var cachedPages = 0
        var pagingMilliseconds = 0.0
        var cacheMilliseconds = 0.0
        var batchingMilliseconds = 0.0
        var providerBatches = 0
        var providerStarted: Double?
        var providerFinished: Double?
        var providerTotalMilliseconds = 0.0
        var judgedPages = 0
    }

    private final class RecallJudgmentProgress {
        var metrics = RecallJudgmentMetrics()
        var recordIDs: [String: String] = [:]
        // Only a completely judged ranking prefix can settle the result. A
        // lower-ranked hit cannot hide unresolved evidence in a higher row.
        var rankingCursor = 0, admittedPrefixCount = 0
        var next = 0
        var pageStart: String.UnicodeScalarView.Index?
        var pendingPage: RecallPage?
        var inFlight: Set<String> = []
        var admitted: Set<String> = []
        var resolved: Set<String> = []
        var exhausted: Set<String> = []
        var uncheckedCounts: [String: Int] = [:]
        var completed: [String: Bool] = [:]

        func enough(topK: Int?, candidates: [MemoryManagerExistingMemory]) -> Bool {
            guard let topK, topK > 0 else { return false }
            while rankingCursor < candidates.count, admittedPrefixCount < topK {
                let id = candidates[rankingCursor].id
                guard admitted.contains(id) || resolved.contains(id) else { return false }
                if admitted.contains(id) { admittedPrefixCount += 1 }
                rankingCursor += 1
            }
            return admittedPrefixCount >= topK
        }
    }

    private func recallJudgmentRoute() async -> Result<RecallRoute, AfterTurnMemoryFailure> {
        let router = SwiftNativeProviderRouting()
        let snapshot: ProviderRoutingSnapshot
        do { snapshot = try await router.checkedRoutingSnapshot() }
        catch { return .failure(.init(reason: .routingUnavailable,
            recovery: Self.judgmentRecovery(.routingUnavailable, surface: "memory", detail: error.localizedDescription), model: nil, surface: "memory")) }
        let surface = snapshot.pinnedModels["memory"] != nil || snapshot.activeProviders["memory"] != nil ? "memory" : "chat"
        let admission: TurnRouteAdmission
        do { admission = try snapshot.routeAdmission(for: surface, choice: nil) }
        catch { return .failure(.init(reason: .modelUnavailable,
            recovery: Self.judgmentRecovery(.modelUnavailable, surface: surface), model: nil, surface: surface)) }
        let model = admission.modelId
        guard let provider = admission.providerId else {
            return .failure(.init(reason: .modelUnavailable,
                recovery: Self.judgmentRecovery(.modelUnavailable, surface: surface), model: model, surface: surface))
        }
        let catalog = await router.catalogContextLength(forModel: model, providerID: provider)
        guard let contextLength = catalog.contextLength else {
            return .failure(.init(reason: catalog.catalogFailure == nil ? .modelUnavailable : .provider,
                recovery: catalog.catalogFailure.map {
                    "The \(provider) catalog request failed: \($0). Refresh that provider's models in Settings, then retry this query."
                } ?? """
                    \(provider)'s model list has no context window for \(model). Refresh that provider's models in Settings or choose a listed model, \
                    then retry this query.
                    """,
                model: model, surface: surface))
        }
        // UTF-8 bytes conservatively bound tokens; reserve framing and instructions and leave half the window for reasoning and output.
        let payloadByteCap = contextLength / 2 - Self.relevanceEnvelopeByteReserve
        let route = RecallRoute(snapshot: snapshot, surface: surface,
            admission: admission, payloadByteCap: payloadByteCap)
        return .success(route)
    }

    private static func recallJudgmentFailure(_ reason: AfterTurnMemoryFailure.Reason, route: RecallRoute) -> AfterTurnMemoryFailure {
        let surface = route.surface
        return .init(reason: reason, recovery: reason == .invalidJSON ? Self.recallEncodingRecovery : Self.judgmentRecovery(reason, surface: surface),
              model: route.model, surface: surface)
    }

    private func collectRecallJudgments(query: String, queryJSON: String, candidates: [MemoryManagerExistingMemory], topK: Int?,
                                        envelopeBytes: Int, route: RecallRoute, scope: RecallCacheScope?, turn: Turn?,
                                        progress: RecallJudgmentProgress) async -> Result<[String: Bool], AfterTurnMemoryFailure> {
        // Parallelize independent records; wait for a record's judgment before
        // dispatching more of its pages, and stop once it is admitted.
        return await withTaskGroup(
            of: ([RecallPage], Result<Set<String>, AfterTurnMemoryFailure>, Double).self
        ) { group in
            var running = 0
            // Bound speculative work even for a very large context window.
            let pageLimit = max(1, min(topK ?? candidates.count, candidates.count)) * 8
            while true {
                guard !Task.isCancelled else { group.cancelAll(); return .failure(Self.recallJudgmentFailure(.cancelled, route: route)) }
                while running < 2, !progress.enough(topK: topK, candidates: candidates) {
                    var batch: [RecallPage]
                    switch await prepareRecallBatch(query: query, candidates: candidates, topK: topK, envelopeBytes: envelopeBytes,
                        pageLimit: pageLimit, route: route, scope: scope, progress: progress) {
                    case .failed(let reason): group.cancelAll(); return .failure(Self.recallJudgmentFailure(reason, route: route))
                    case .ready(let prepared): batch = prepared
                    }
                    if progress.enough(topK: topK, candidates: candidates) { break }
                    for page in batch where progress.admitted.contains(page.id) {
                        progress.uncheckedCounts[page.id, default: 0] -= 1
                    }
                    batch.removeAll { progress.admitted.contains($0.id) }
                    if batch.isEmpty { break }
                    let ids = Set(batch.map(\.id))
                    progress.inFlight.formUnion(ids)
                    running += 1
                    progress.metrics.providerBatches += 1
                    if progress.metrics.providerStarted == nil { progress.metrics.providerStarted = ProcessInfo.processInfo.systemUptime }
                    let rows = batch.enumerated().map { index, page in
                        page.encodedRow.replacingOccurrences(of: #""id":"0""#, with: "\"id\":\"\(index)\"")
                    }.joined(separator: ",")
                    let prompt = "{\"memories\":[\(rows)],\"query\":\(queryJSON)}"
                    let dispatched = batch
                    group.addTask {
                        let started = ProcessInfo.processInfo.systemUptime
                        let result = await relevantRecallBatch(prompt: prompt, candidates: dispatched, route: route, turn: turn)
                        return (dispatched, result, (ProcessInfo.processInfo.systemUptime - started) * 1_000)
                    }
                }
                if progress.enough(topK: topK, candidates: candidates) { group.cancelAll(); break }
                guard let (batch, result, duration) = await group.next() else { break }
                progress.metrics.providerFinished = ProcessInfo.processInfo.systemUptime
                progress.metrics.providerTotalMilliseconds += duration
                progress.metrics.judgedPages += batch.count
                nativeLog("Memory recall batch: duration_ms=\(Int(duration)) pages=\(batch.count)")
                running -= 1
                progress.inFlight.subtract(batch.map(\.id))
                switch result {
                case .success(let keys):
                    for page in batch {
                        progress.completed[page.key] = keys.contains(page.key)
                        if keys.contains(page.key) { progress.admitted.insert(page.id) }
                        progress.uncheckedCounts[page.id, default: 0] -= 1
                        if progress.exhausted.contains(page.id), progress.uncheckedCounts[page.id, default: 0] == 0 {
                            progress.resolved.insert(page.id)
                        }
                    }
                case .failure(let failure): group.cancelAll(); return .failure(failure)
                }
            }
            return .success(progress.completed)
        }
    }

    private enum RecallBatchPreparation {
        case ready([RecallPage])
        case failed(AfterTurnMemoryFailure.Reason)
    }

    private func prepareRecallBatch(query: String, candidates: [MemoryManagerExistingMemory], topK: Int?, envelopeBytes: Int,
                                    pageLimit: Int, route: RecallRoute, scope: RecallCacheScope?, progress: RecallJudgmentProgress) async
        -> RecallBatchPreparation {
        let payloadByteCap = route.payloadByteCap
        var batch: [RecallPage] = []
        var batchBytes = envelopeBytes
        while batch.count < pageLimit, !progress.enough(topK: topK, candidates: candidates) {
            if let page = progress.pendingPage {
                if progress.admitted.contains(page.id) {
                    progress.uncheckedCounts[page.id, default: 0] -= 1
                    progress.pendingPage = nil
                    continue
                }
                guard !progress.inFlight.contains(page.id) else { break }
                let packingStarted = ProcessInfo.processInfo.systemUptime
                let rowBytes = page.encodedRow.utf8.count + String(batch.count).utf8.count - 1 + (batch.isEmpty ? 0 : 1)
                progress.metrics.batchingMilliseconds += (ProcessInfo.processInfo.systemUptime - packingStarted) * 1_000
                if batchBytes + rowBytes > payloadByteCap { break }
                batchBytes += rowBytes
                batch.append(page)
                progress.pendingPage = nil
                continue
            }
            guard progress.next < candidates.count else { break }
            let candidate = candidates[progress.next]
            if progress.admitted.contains(candidate.id) || progress.resolved.contains(candidate.id) {
                progress.next += 1
                progress.pageStart = nil
                continue
            }
            guard !progress.inFlight.contains(candidate.id) else { break }
            let pagingStarted = ProcessInfo.processInfo.systemUptime
            let scalars = candidate.content.unicodeScalars
            let start = progress.pageStart ?? scalars.startIndex
            var length = scalars.distance(from: start,
                to: scalars.index(start, offsetBy: memoryRecallContentCap, limitedBy: scalars.endIndex) ?? scalars.endIndex)
            var end = scalars.index(start, offsetBy: length)
            var content = String(scalars[start..<end])
            var encodedRow = Data()
            // A single page must fit too, including escaped JSON and
            // the query. Shrink pages without dropping any evidence.
            while true {
                guard let data = try? JSONSerialization.data(withJSONObject:
                    ["id": "0", "memory_id": candidate.id, "content": content], options: [.sortedKeys]) else {
                    return .failed(.invalidJSON)
                }
                encodedRow = data
                if envelopeBytes + data.count <= payloadByteCap { break }
                guard length > 1 else {
                    return .failed(.contextTooLong)
                }
                length /= 2
                end = scalars.index(start, offsetBy: length)
                content = String(scalars[start..<end])
            }
            let identity = ["query": query, "id": candidate.id, "content": content, "kind": candidate.kind ?? ""]
            guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else {
                return .failed(.invalidJSON)
            }
            let key = SHA256Hex.of(data)
            let page = RecallPage(key: key, id: candidate.id, encodedRow: String(decoding: encodedRow, as: UTF8.self))
            progress.recordIDs[key] = candidate.id
            progress.metrics.preparedPages += 1
            if end == scalars.endIndex {
                progress.exhausted.insert(candidate.id)
                progress.next += 1
                progress.pageStart = nil
            } else {
                progress.pageStart = scalars.index(end, offsetBy: -min(200, length / 2))
            }
            progress.metrics.pagingMilliseconds += (ProcessInfo.processInfo.systemUptime - pagingStarted) * 1_000
            let cacheStarted = ProcessInfo.processInfo.systemUptime
            let cached = if let scope { await relevanceCache.read(scope: scope, keys: [key])[key] } else { nil as Bool? }
            progress.metrics.cacheMilliseconds += (ProcessInfo.processInfo.systemUptime - cacheStarted) * 1_000
            if let cached {
                progress.metrics.cachedPages += 1
                progress.completed[key] = cached
                if cached { progress.admitted.insert(candidate.id) }
                if progress.exhausted.contains(candidate.id), progress.uncheckedCounts[candidate.id, default: 0] == 0 {
                    progress.resolved.insert(candidate.id)
                }
            } else {
                progress.uncheckedCounts[candidate.id, default: 0] += 1
                progress.pendingPage = page
            }
            guard !Task.isCancelled else { break }
        }
        return .ready(batch)
    }

    private func reportRecallJudgment(_ metrics: RecallJudgmentMetrics, started: Double, routeFinished: Double,
                                      surface: String, payloadByteCap: Int) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let timings: [String: JSONValue] = [
            "duration_ms": .double(elapsed), "pages": .int(Int64(metrics.preparedPages)),
            "cached_pages": .int(Int64(metrics.cachedPages)), "provider_batches": .int(Int64(metrics.providerBatches)),
            "route_ms": .double((routeFinished - started) * 1_000),
            "paging_ms": .double(metrics.pagingMilliseconds),
            "cache_ms": .double(metrics.cacheMilliseconds),
            "batching_ms": .double(metrics.batchingMilliseconds),
            "provider_wall_ms": .double(metrics.providerStarted.flatMap { start in
                metrics.providerFinished.map { ($0 - start) * 1_000 }
            } ?? 0),
            "payload_byte_cap": .int(Int64(payloadByteCap)),
            "provider_total_ms": .double(metrics.providerTotalMilliseconds), "judged_pages": .int(Int64(metrics.judgedPages)),
        ]
        TurnTraceBus.fireFromContext(kind: "memory.recall.relevance", surface: surface, payload: .object(timings), turn: nil)
        let detail = timings.sorted { $0.key < $1.key }.map { key, value in
            switch value {
            case .double(let value): return "\(key)=\(Int(value))"
            case .int(let value): return "\(key)=\(value)"
            default: return key
            }
        }.joined(separator: " ")
        nativeLog("Memory recall relevance: \(detail)")
    }

    // Preserve the 819-byte instruction and 128-byte framing allowances independently of prompt wording.
    private static let relevanceEnvelopeByteReserve = 947

    private static var relevanceSystem: String {
        get throws { try completionPolicy("recall-selection", section: "system") }
    }

    private func relevantRecallBatch(prompt: String, candidates: [RecallPage], route: RecallRoute, turn: Turn?) async
        -> Result<Set<String>, AfterTurnMemoryFailure> {
        let surface = route.surface
        let model = route.model
        func failed(_ reason: AfterTurnMemoryFailure.Reason) -> Result<Set<String>, AfterTurnMemoryFailure> {
            .failure(.init(reason: reason, recovery: Self.judgmentRecovery(reason, surface: surface),
                           model: model, surface: surface))
        }
        guard !Task.isCancelled else { return failed(.cancelled) }
        guard prompt.utf8.count <= route.payloadByteCap else { return failed(.contextTooLong) }
        let response: String
        do {
            var call = LLMCall(turn: turn, surface: surface, purpose: "recall_judge")
            call.admission = try route.admission.modelAdmission
            let system = try Self.relevanceSystem
            call.systemSegments = SystemPromptSegments(stable: system, dynamic: "")
            call.memoryPolicyScope = .recallJudge
            response = try await makeLLMClient().complete(
                prompt: prompt, system: system, model: model, tools: nil,
                call: call)
        } catch {
            let failure = ProviderFailure.classify(error)
            return .failure(.init(reason: Self.reason(error, cause: failure),
                recovery: Self.judgmentRecovery(Self.reason(error, cause: failure), surface: surface, detail: ProviderFailure.diagnosticDescription(error)),
                model: model, surface: surface))
        }
        guard !Task.isCancelled else { return failed(.cancelled) }
        guard let object = try? JSONValue.decodeCompletion(response, as: [String: JSONValue].self),
              let ids = object["relevant_ids"]?.foundationObject as? [String],
              Set(ids).isSubset(of: Set(candidates.indices.map { String($0) }))
        else { return failed(.invalidJSON) }
        return .success(Set(ids.compactMap { Int($0).map { candidates[$0].key } }))
    }

    /// Use the Memory provider row for every after-turn judgment.
    private struct JudgmentRoute: Sendable {
        let surface: String
        let admission: TurnRouteAdmission
        var model: String { admission.modelId }

        func failed(_ reason: AfterTurnMemoryFailure.Reason, recovery: String? = nil) -> AfterTurnMemoryFailure {
            .init(reason: reason, recovery: MindMemoryJudgment.judgmentRecovery(reason, surface: surface, detail: recovery),
                  model: model, surface: surface)
        }
    }

    /// The account is the route's provider id, so switching accounts for the same model changes the key.
    public func judgmentRouteKey() async -> String? {
        guard let route = try? await Self.judgmentRoute() else { return nil }
        return MemoryManagerLane.fingerprint([route.surface, route.admission.providerId ?? "", route.model])
    }

    private static func judgmentRoute() async throws -> JudgmentRoute {
        let snapshot = try await SwiftNativeProviderRouting().checkedRoutingSnapshot()
        let surface = snapshot.pinnedModels["memory"] != nil || snapshot.activeProviders["memory"] != nil ? "memory" : "chat"
        // Use Memory's saved provider choice independently of the active chat turn.
        return try JudgmentRoute(surface: surface, admission: snapshot.routeAdmission(
            for: surface, choice: nil, inheritChat: surface == "chat"))
    }

    /// Stop interrupts unfinished provider work. A returned reply belongs to
    /// settlement, even when cancellation arrives with that reply.
    private func judgedText(prompt: String, system: SystemPromptSegments, purpose: String,
                            policyScope: LLMCall.MemoryPolicyScope, route: JudgmentRoute,
                            call heldCall: LLMCall? = nil) async throws -> String {
        let text: String
        do {
            try Task.checkCancellation()
            var call = heldCall ?? LLMCall(turn: nil, surface: route.surface, purpose: purpose)
            call.surface = route.surface
            call.purpose = purpose
            call.admission = try route.admission.modelAdmission
            call.systemSegments = system
            call.memoryPolicyScope = policyScope
            text = try await makeLLMClient().complete(
                prompt: prompt, system: system.combined, model: route.model, tools: nil,
                call: call)
        } catch {
            let cause = ProviderFailure.classify(error)
            throw route.failed(Self.reason(error, cause: cause), recovery: ProviderFailure.diagnosticDescription(error))
        }
        return text
    }

    /// A memory statement over the bound is sent back once to be said in one sentence; at most two per judgment. A reply that is not an object with a
    /// memories array is returned untouched for the ordinary checks to judge.
    private static func fittingLongMemories(in text: String, route: JudgmentRoute, call: LLMCall,
        shorter: @Sendable (String) async throws -> String) async -> String {
        func length(_ statement: String) -> Int {
            statement.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        guard var fields = try? JSONValue.decodeCompletion(text, as: [String: JSONValue].self),
              case .array(var memories)? = fields["memories"] else { return text }
        let long = memories.indices.filter { memories[$0].objectValue?["statement"]?.stringValue.map { length($0) > MemoryManagerLane.statementCap } == true }
        guard !long.isEmpty else { return text }
        var leftOut: [Int] = []
        var stopped = false
        for (asked, index) in long.enumerated() {
            guard !stopped, asked < 2, case .object(var candidate) = memories[index], let statement = candidate["statement"]?.stringValue else {
                leftOut.append(index); continue
            }
            // A retry that fails or is stopped costs only its own candidate: what the judgment already produced still lands.
            guard let said = try? await shorter(statement).trimmingCharacters(in: .whitespacesAndNewlines) else {
                stopped = Task.isCancelled
                leftOut.append(index); continue
            }
            if (MemoryManagerLane.statementFloor...MemoryManagerLane.statementCap).contains(length(said)) {
                candidate["statement"] = .string(said)
                memories[index] = .object(candidate)
            } else { leftOut.append(index) }
        }
        for index in leftOut.sorted(by: >) { memories.remove(at: index) }
        if !leftOut.isEmpty {
            TurnTraceBus.fire(TurnTraceEvent(turnId: call.turn?.id ?? TurnTraceContext.turnId ?? "unknown",
                kind: "memory.rejected", sessionId: call.session, surface: route.surface,
                payload: .object(["purpose": .string(call.purpose), "reason": .string("statement_over_bound"),
                    "left_out": .int(Int64(leftOut.count)),
                    "complaint": .string("memory candidates over \(MemoryManagerLane.statementCap) characters were left out of this judgment")]),
                turn: call.turn))
        }
        fields["memories"] = .array(memories)
        guard let data = try? JSONValue.object(fields).serializedData(pretty: false) else { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// Settlement parses JSON and returns the produced typed result, even after Stop.
    private static func settledObject<T: Sendable>(text: String, route: JudgmentRoute, call: LLMCall,
        parse: @escaping @Sendable ([String: JSONValue]) throws -> T) async throws -> T {
        let result: Result<T, AfterTurnMemoryFailure> = await settle {
            do {
                let fields = try JSONValue.decodeCompletion(text, as: [String: JSONValue].self)
                return .success(try parse(fields))
            } catch {
                let complaint = (error as? AfterTurnMemoryFailure)?.recovery ?? String(describing: error)
                let failure = (error as? AfterTurnMemoryFailure) ?? route.failed(.invalidJSON, recovery: complaint)
                TurnTraceBus.fire(TurnTraceEvent(turnId: call.turn?.id ?? TurnTraceContext.turnId ?? "unknown",
                    kind: "memory.rejected", sessionId: call.session, surface: route.surface,
                    payload: .object(["purpose": .string(call.purpose), "reason": .string(failure.reason.rawValue),
                        "complaint": .string(TurnTraceRedactor.redactText(complaint))]), turn: call.turn))
                return .failure(failure)
            }
        }
        return try result.get()
    }

    public func interpret(_ request: MemoryManagerRequest, context: AfterTurnContext?,
                          factsEnabled: Bool, call: LLMCall) async throws -> AfterTurnInterpretation? {
        // Whether a turn is judged is decided before this call; empty incoming words are judged like any other.
        let route = try await Self.judgmentRoute()
        guard var turn = call.turn else {
            throw PartCallError(code: "door_unavailable", message: "The turn digest needs its originating turn.")
        }
        // An after-turn moment can carry a turn rebuilt from its record, which has no part catalog of its own.
        if turn[AppActionBinding.Parts.self] == nil {
            let catalogRoot = turn.dataRoot
            turn[AppActionBinding.Parts.self] = { try NativeAgentEngine.forRoot(catalogRoot).partBinding($0, $1) }
        }
        let root = turn.dataRoot
        let parts = Parts(root: root)
        let program: OwnedProgram, version: String
        do {
            guard let selected = try parts.abilities.selectedPart(DigestPart.id), let file = selected.file,
                  let fingerprint = selected.row["codeFingerprint"]?.stringValue else {
                throw Parts.missing(DigestPart.id)
            }
            let candidate = try parts.store.selection(file).candidate
            guard candidate.digest == fingerprint else {
                throw Parts.revisionFailure("state_changed", "The selected digest contract changed.", id: DigestPart.id)
            }
            program = candidate.program
            version = fingerprint
        } catch {
            if error is CancellationError { throw error }
            throw PartCallError(code: (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "digest_selection",
                message: error.localizedDescription)
        }
        let legacy = if case .array(let required)? = program.schema.objectValue?["required"] {
            required.contains(.string("evidence"))
        } else { false }
        let acts = request.completedActs.map(\.digestEvidence)
        let personWords = TurnSecretRedactor.redactText(request.personWords)
        // A digest that declares open_moments as its own input is shown them apart, ahead of the exchange, where they can be read from
        // cache from one judgment to the next; any other digest receives them inside the settlement as before.
        let momentsApart = !legacy && program.schema.objectValue?["properties"]?.objectValue?["open_moments"] != nil
        let evidence = try Self.digestEvidence(request, context: context, turn: turn, surface: call.surface,
            factsEnabled: factsEnabled, acts: acts, personWords: personWords, legacy: legacy, momentsApart: momentsApart,
            limit: program.inputLimit)
        let system = try Self.digestSystem(request, context: context)
        let parse: @Sendable (JSONValue) throws -> AfterTurnInterpretation = { value in
            guard let object = value.objectValue else {
                throw route.failed(.missingSections, recovery: "The digest must return a judgment object.")
            }
            return try Self.parseInterpretation(object, request: request, context: context,
                evidence: evidence, personWords: personWords, acts: acts, factsEnabled: factsEnabled, route: route)
        }
        let digest = DigestPart(parse: parse) { prompt in
            let required = [evidence.incoming, evidence.reply, evidence.settlement, evidence.openMoments, evidence.beliefTarget ?? ""]
                + evidence.memoryLines
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  required.allSatisfy({ $0.isEmpty || prompt.range(of: $0, options: .literal) != nil }) else {
                throw PartCallError(code: "bad_digest_policy", message: "The digest prompt must show the supplied exchange, prior statement, memory rows and settlement evidence intact.")
            }
            let judged = try await judgedText(prompt: prompt, system: system,
                purpose: call.purpose == "memory_held" ? "memory_held" : "memory_interpret",
                policyScope: .interpretation, route: route, call: call)
            // One over-long memory does not fail the rest of the judgment: her model says it again in one sentence, and one that still does not fit
            // is left out and named. It is never clipped.
            let memoriesAllowed = factsEnabled && !request.careWake && !request.settlesOnly
            let text = !memoriesAllowed ? judged : await Self.fittingLongMemories(in: judged, route: route, call: call) { statement in
                try await self.judgedText(
                    prompt: statement,
                    system: SystemPromptSegments(stable: "You are given one statement. Say it as one plain sentence of at most "
                        + "\(MemoryManagerLane.statementCap) characters, keeping its meaning. Return only that sentence: no JSON, no quotes, no comment.",
                        dynamic: ""),
                    purpose: call.purpose == "memory_held" ? "memory_held" : "memory_interpret",
                    policyScope: .interpretation, route: route, call: call)
            }
            return try await Self.settledObject(text: text, route: route, call: call) { fields in
                let value = JSONValue.object(fields)
                _ = try parse(value)
                return value
            }
        }
        turn[DigestPart.Key.self] = digest
        // Her own pass over a finished exchange, model-only: it runs as her own work, never as an act the exchange's door asked for.
        // Under that door's envelope a remote exchange carded it for the person, and an approved card could not run it (it needs this turn).
        let result = try await NativeAgentEngine.forRoot(root).withPartDoor(
            envelope: TurnEnvelope.native("background:memory-digest"), fileAccess: turn.fileAccess ?? "auto", turn: turn
        ) { door in
            await parts.call(id: DigestPart.id, input: evidence.input, requiredFingerprint: version,
                within: .init(actions: [], capabilities: [.model]), invocation: door.invocation, as: JSONValue.self)
        }
        switch result {
        case .success:
            guard let judgment = await digest.judgment else {
                throw PartCallError(code: "bad_digest_policy", message: "The digest did not settle a verified judgment.")
            }
            return judgment
        case .failure(let error) where error.code == "cancelled":
            if let judgment = await digest.judgment { return judgment }
            throw CancellationError()
        case .failure(let error):
            if let failure = await digest.modelFailure { throw failure }
            throw error
        }
    }

    /// Match at filing time so deferred exchanges and refolds see work that earlier captures actually landed.
    public func capturePromises(_ promises: [MemoryManagerPromise], reply: String,
                                open: [DeskItem], call: LLMCall) async throws
        -> [MemoryManagerPromiseCapture] {
        guard !promises.isEmpty else { return [] }
        let route = try await Self.judgmentRoute()
        let candidates: [JSONValue] = promises.enumerated().map { index, promise in
            var row: [String: JSONValue] = ["id": .int(Int64(index)), "words": .string(promise.words),
                                            "when": .string(promise.when), "source": .string(promise.source)]
            if promise.prove == true { row["prove"] = .bool(true) }
            return .object(row)
        }
        let input = try JSONValue.object(["candidates": .array(candidates), "open": .array(Self.deskRows(open)),
            "reply": .string(reply)]).serialize(pretty: false)
        let text = try await judgedText(prompt: completionPolicy("turn-interpretation", section: "promise-capture", arguments: [input]),
            system: SystemPromptSegments(stable: completionPolicy("turn-interpretation", section: "promise-capture-system"), dynamic: ""),
            purpose: "memory_promise", policyScope: .promiseCapture, route: route, call: call)
        var captureCall = call
        captureCall.purpose = "memory_promise"
        return try await Self.settledObject(text: text, route: route, call: captureCall) { fields in
            func invalid(_ words: String) -> AfterTurnMemoryFailure {
                route.failed(.invalidMemories, recovery: "Invalid promise capture: " + words)
            }
            guard let groups = fields["captures"]?.foundationObject as? [[String: Any]] else { throw invalid("captures must be an array of groups.") }
            var covered: Set<Int> = [], targets: Set<String> = []
            var captures: [MemoryManagerPromiseCapture] = []
            for group in groups {
                guard let ids = group["candidates"] as? [Int], !ids.isEmpty,
                      Set(ids).count == ids.count, ids.allSatisfy({ promises.indices.contains($0) && !covered.contains($0) }),
                      let target = group["target"] as? String else { throw invalid("Each candidate must belong to exactly one named group.") }
                covered.formUnion(ids)
                if target == "ignore" { captures.append(.ignore); continue }
                let item = open.first { $0.handle == target }
                guard target == "new" || item != nil else { throw invalid("The target is not an open Desk id: " + target) }
                if target != "new", !targets.insert(target).inserted { throw invalid("A restatement must be grouped on its one target: " + target) }
                let members = ids.compactMap { id in promises.indices.contains(id) ? promises[id] : nil }
                guard let words = group["words"] as? String, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let source = group["source"] as? String, members.contains(where: { $0.source == source }), reply.contains(source),
                      let namedWhen = group["when"] as? String else { throw invalid("Kept groups need words, when and exact candidate evidence.") }
                let when: String
                if namedWhen == "keep" {
                    guard let step = item?.step else { throw invalid("Only an existing step has a condition to keep.") }
                    if step.when == "after_card" {
                        guard let card = step.card else { throw invalid("The target's approval condition has no card.") }
                        when = "after_card " + card
                    } else { when = step.when }
                } else {
                    guard members.contains(where: { $0.when == namedWhen }) else { throw invalid("The group invented a time its candidates never named.") }
                    when = namedWhen
                }
                let evidence = members.map(\.source).reduce(into: [String]()) { result, source in
                    if !result.contains(source) { result.append(source) }
                }.joined(separator: "\n")
                // A group is a proof owed only when every sentence in it is; mixed with a promise to the person it stays that promise.
                let prove = when == "own_turn" && members.allSatisfy { $0.prove == true }
                captures.append(.keep(MemoryManagerPromise(words: words.trimmingCharacters(in: .whitespacesAndNewlines), when: when, source: evidence,
                                                           prove: prove),
                                      target: target == "new" ? nil : target, candidates: ids))
            }
            guard covered == Set(promises.indices) else { throw invalid("The judgment left candidates unclassified.") }
            return captures
        }
    }

    /// Required sections form a complete interpretation or name their failure.
    /// Optional promises may be absent/empty; malformed present promises keep the turn owed.
    private static func parseInterpretation(_ fields: [String: JSONValue], request: MemoryManagerRequest,
                                            context: AfterTurnContext?, evidence: DigestEvidence, personWords: String,
                                            acts: [MemoryManagerAct], factsEnabled: Bool, route: JudgmentRoute) throws -> AfterTurnInterpretation {
        func failed(_ reason: AfterTurnMemoryFailure.Reason, _ complaint: String) -> AfterTurnMemoryFailure {
            route.failed(reason, recovery: complaint)
        }
        let allowed: Set<String> = ["memories", "affect", "caring", "cares", "promises", "settled",
            "appAuthored", "model", "surface", "careFaults", "redactedQuotes"]
        let authority: [String: JSONValue] = ["appAuthored": .bool(request.appAuthored),
            "model": .string(route.model), "surface": .string(route.surface), "redactedQuotes": .bool(true)]
        guard Set(fields.keys).isSubset(of: allowed),
              authority.allSatisfy({ fields[$0.key] == nil || fields[$0.key] == $0.value }) else {
            throw failed(.missingSections, "The digest returned unknown fields or contradicted Swift's provenance or route.")
        }
        let object = fields.mapValues(\.foundationObject)
        let reply = evidence.reply
        guard let memoriesValue = object["memories"] as? [Any],
              object.keys.contains("caring"), object.keys.contains("affect") else {
            throw failed(.missingSections, "memories must be an array; caring and affect must be present.")
        }
        guard let caringObject = object["caring"] as? [String: Any],
              let caring = CaringAppraisalLane.parse(caringObject) else { throw failed(.invalidCaring, "caring must be a valid caring appraisal.") }
        guard let affectObject = object["affect"] as? [String: Any] else { throw failed(.invalidAffect, "affect must be an object.") }
        var affect: CognitiveSubstrate.AffectAppraisal
        do {
            let affectData = try JSONSerialization.data(withJSONObject: affectObject)
            affect = try JSONDecoder().decode(CognitiveSubstrate.AffectAppraisal.self, from: affectData)
        } catch { throw route.failed(.invalidAffect, recovery: String(describing: error)) }
        if let choice = affect.chosenRegister {
            guard reply.contains(choice.source) else {
                throw failed(.invalidAffect, "affect.chosenRegister.source must quote the assistant reply.")
            }
        }
        if let feeling = affect.feeling {
            let quoted = MemoryManagerPromise.quoted(feeling.quote, in: reply)
                || (!request.appAuthored && MemoryManagerPromise.quoted(feeling.quote, in: evidence.incoming))
            if request.settlesOnly || request.careWake || !quoted { affect.feeling = nil }
        }
        if let reaction = affect.beliefReaction {
            guard let target = evidence.beliefTarget,
                  MemoryManagerPromise.quoted(reaction.statement, in: target),
                  MemoryManagerPromise.quoted(reaction.evidence, in: evidence.incoming) else {
                throw failed(.invalidAffect, "affect.beliefReaction must quote the shown prior statement and incoming words.")
            }
        }
        let allowsPromises = !request.settlesOnly && !request.careWake
        let allowsMemories = allowsPromises && factsEnabled
        guard allowsMemories || memoriesValue.isEmpty else {
            throw failed(.invalidMemories, "This digest must leave memories empty when facts are disabled.")
        }
        guard allowsPromises || fields["promises"] == nil || fields["promises"] == .array([]) else {
            throw failed(.invalidMemories, "A care wake or settlement-only digest must leave promises empty.")
        }
        var memories: [MemoryManagerDecision] = []
        var memoryFaults: [String] = []
        if allowsMemories {
            do { memories = try MemoryManagerLane.parse(memoriesValue) }
            catch { throw route.failed(.invalidMemories, recovery: String(describing: error)) }
            // One memory that fails its own check is left out and named; it is never admitted, and it no longer costs the rest of the judgment.
            memories = memories.filter { memory in
                guard memory.action != .skip else { return true }
                if memory.action == .update, memory.updatesId.map(evidence.shownMemoryIDs.contains) != true {
                    memoryFaults.append("a memory update named no shown memory and was left out")
                    return false
                }
                if let grounding = memory.grounding, grounding.eligible,
                   !MemoryManagerPromise.quoted(grounding.evidence, in: grounding.source == .incoming ? evidence.incoming : reply) {
                    memoryFaults.append("a memory did not quote its source in this exchange and was left out")
                    return false
                }
                return true
            }
        }
        var cares: [CognitiveCareJudgment] = []
        var careFaults: [String] = []
        if !request.settlesOnly, let shown = context?.cares, !shown.isEmpty {
            guard let parsed = CognitiveCareJudgment.parse(object["cares"], shown: shown, reply: reply,
                                                          personReplyAt: request.personReplyAt) else {
                throw failed(.invalidCares, "cares must be an array.")
            }
            careFaults = parsed.faults
            cares = request.careWake ? parsed.judgments.filter {
                guard $0.by == .her, case .existing = $0.target else { return false }
                return true
            } : parsed.judgments
        } else if fields["cares"] != nil, fields["cares"] != .array([]) {
            throw failed(.invalidCares, "A digest without shown cares must leave cares empty.")
        }
        if let faults = fields["careFaults"], faults != .array(careFaults.map(JSONValue.string)) {
            throw failed(.invalidCares, "The digest returned care faults that differ from Swift's validation.")
        }
        // Named in the same place her faulty care entries are, by what was wrong and never by its text.
        careFaults += memoryFaults
        var promises: [MemoryManagerPromise] = []
        if allowsPromises {
            do { promises = try MemoryManagerPromise.parse(object["promises"], reply: reply) }
            catch { throw route.failed(.invalidMemories, recovery: "Invalid promises section: \(error)") }
        }
        guard let rows = object["settled"] as? [[String: Any]] else {
            throw route.failed(.missingSections, recovery: "settled must be an array of evidence-backed outcomes.")
        }
        var settled: [MemoryManagerSettlement] = []
        var settledIDs: Set<String> = []
        for row in rows {
            guard let id = row["id"] as? String, let item = request.openMoments.first(where: { $0.handle == id }),
                  MyQueue.entry(item) != nil, settledIDs.insert(id).inserted,
                  let source = row["source"] as? String, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let outcomeText = row["outcome"] as? String,
                  let outcome = MemoryManagerSettlement.Outcome(rawValue: outcomeText),
                  let reason = row["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw route.failed(.invalidMemories,
                    recovery: "Settlement requires one shown open moment id, done or let_go, a reason and exact evidence from this turn.")
            }
            let evidence: MemoryManagerSettlement.Evidence
            switch row["basis"] as? String {
            case "person_words":
                guard personWords.contains(source), row["act_id"] == nil else {
                    throw route.failed(.invalidMemories, recovery: "Person settlement requires an exact person_words quote and no act_id.")
                }
                evidence = .personWords(source)
            case "act":
                guard outcome == .done, let actID = row["act_id"] as? String,
                      let act = acts.first(where: { $0.id == actID }), act.contains(source) else {
                    throw route.failed(.invalidMemories, recovery: "Act settlement requires done and exact evidence from a shown completed act_id.")
                }
                evidence = .act(id: actID, source: source)
            case "reply":
                // Saying it is the deed only for a moment that ends once; a rhythm or standing step outlives one saying.
                guard outcome == .done, request.replyDelivered, row["act_id"] == nil,
                      MemoryManagerPromise.quoted(source, in: reply),
                      let step = MyQueue.entry(item)?.step, step.rhythm == nil, MyQueue.Until(step.until) != .standing else {
                    throw route.failed(.invalidMemories,
                        recovery: "Reply settlement requires done, a delivered reply, its exact quote, no act_id and a moment that ends once.")
                }
                evidence = .reply(source)
            default:
                throw route.failed(.invalidMemories,
                    recovery: "Settlement basis must be person_words, act or reply; unknown evidence leaves work open.")
            }
            settled.append(MemoryManagerSettlement(id: id, updatedAt: item.updatedAt, outcome: outcome, evidence: evidence, reason: reason))
        }
        return AfterTurnInterpretation(memories: memories, affect: affect, caring: caring,
                                       cares: cares, careFaults: careFaults,
                                       promises: promises, settled: settled,
                                       appAuthored: request.appAuthored, model: route.model, surface: route.surface, redactedQuotes: true)
    }

    actor DigestPart {
        enum Key: NativeAgentCore.TurnPart { static let unset: DigestPart? = nil }
        static let id = "native-turn-digest"
        private let parse: @Sendable (JSONValue) throws -> AfterTurnInterpretation
        private let model: @Sendable (String) async throws -> JSONValue
        private var started = false
        private var answered = false
        private(set) var modelFailure: AfterTurnMemoryFailure?
        private(set) var judgment: AfterTurnInterpretation?

        init(parse: @escaping @Sendable (JSONValue) throws -> AfterTurnInterpretation,
             model: @escaping @Sendable (String) async throws -> JSONValue) {
            self.parse = parse
            self.model = model
        }

        static func helperUnavailable(_ code: String) -> Bool {
            ["busy", "spawn_busy", "spawn_failed", "helper_unavailable", "helper_missing", "helper_not_executable", "crashed"].contains(code)
        }

        func judge(_ arguments: [String: JSONValue]) async throws -> JSONValue {
            guard !started, arguments.count == 2, arguments["purpose"] == .string("turn_digest"),
                  let prompt = arguments["prompt"]?.stringValue else {
                throw PartCallError(code: "bad_digest_policy", message: "The digest may call the Memory route once with purpose turn_digest and a prompt.")
            }
            started = true
            do {
                let value = try await model(prompt)
                answered = true
                return value
            } catch {
                modelFailure = error as? AfterTurnMemoryFailure
                throw error
            }
        }

        func verify(_ value: JSONValue) throws -> AfterTurnInterpretation {
            guard answered, value.objectValue?["status"] != .string("refused") else {
                throw PartCallError(code: "bad_digest_policy", message: "The digest must return its proposed judgment after an accepted Memory answer.")
            }
            return try parse(value)
        }

        func keep(_ judgment: AfterTurnInterpretation) { self.judgment = judgment }
    }

    private static func digestSystem(_ request: MemoryManagerRequest, context: AfterTurnContext?) throws -> SystemPromptSegments {
        let caresShape = #","cares":[{"care":"c1","about":null,"between":false,"moved":0.0,"by":"them","felt":"...","note":"...","open":null,"closes":false,"stance":null,"shared":null}]"#
        let stable = try completionPolicy("turn-interpretation", section: "system", arguments: [
            completionPolicy("turn-interpretation", section: "rules"),
            MemoryKindStamp.writerKinds.joined(separator: "|"),
            caresShape,
        ])
        let dynamic = try request.settlesOnly ? completionPolicy("turn-interpretation", section: "settlement-alone")
            : request.careWake ? completionPolicy("turn-interpretation", section: "care-wake-cares")
            : context?.cares.isEmpty == false ? completionPolicy("turn-interpretation", section: "cares") : ""
        return SystemPromptSegments(stable: stable, dynamic: dynamic)
    }

    /// What the judgment is shown of a record: every text by its opening (five sixths of the allowance) and end, every list by its first rows. The judgment weighs what an
    /// act was, not the bulk it returned; a quote from what is shown is still a quote from the whole record, which is what it is checked against.
    private static func shown(_ value: JSONValue, text: Int, rows: Int) -> JSONValue {
        switch value {
        // A long text keeps its opening and its end, where an outcome is usually said.
        case .string(let words): words.count > text
            ? .string(String(words.prefix(text * 5 / 6)) + "\n[… \(words.count - text) characters not shown …]\n" + String(words.suffix(text - text * 5 / 6))) : value
        case .array(let items): .array(items.prefix(rows).map { shown($0, text: text, rows: rows) })
        case .object(let fields): .object(fields.mapValues { shown($0, text: text, rows: rows) })
        default: value
        }
    }

    /// What the judgment is shown of a turn's acts. The bound is set by what her judgments have quoted as proof: every act-based
    /// settlement on record quoted from the first 1,100 characters of a result, so a text keeps its first 1,500 and last 300; only when
    /// a turn's acts together pass 24 KB does it tighten, and never below the first 1,100. Every act is always present with its id.
    private static func shownActs(_ acts: [MemoryManagerAct]) -> JSONValue {
        let wide = JSONValue.array(acts.map { shown($0.record, text: 1_800, rows: 24) })
        if ((try? wide.serializedData(pretty: false).count) ?? .max) <= 24_000 { return wide }
        return .array(acts.map { shown($0.record, text: 1_320, rows: 12) })
    }

    private static func deskRows(_ open: [DeskItem]) -> [JSONValue] {
        open.map { item in
            var row: [String: JSONValue] = ["id": .string(item.handle), "label": .string("desk." + item.alias),
                "title": .string(item.title), "project": .string(item.project), "status": .string(item.status.rawValue)]
            if let summary = item.summary { row["summary"] = .string(summary) }
            if let step = item.step {
                row["words"] = .string(step.words)
                row["when"] = .string(step.when)
                if let card = step.card { row["card"] = .string(card) }
                if let until = step.until { row["until"] = .string(until) }
                if let source = step.source { row["source"] = .string(source) }
            }
            return .object(row)
        }
    }

    private struct DigestEvidence: Sendable {
        let input: JSONValue
        let incoming: String
        let reply: String
        let beliefTarget: String?
        let settlement: String
        /// The open moments as shown apart from the settlement; empty when they are inside it.
        let openMoments: String
        let memoryLines: [String]
        let shownMemoryIDs: Set<String>
    }

    private static func digestText(_ row: JSONValue, _ key: String) -> String { row.objectValue?[key]?.stringValue ?? "" }

    private static func digestMemoryLine(_ row: JSONValue) -> String {
        let subject = digestText(row, "subject")
        return "[\(digestText(row, "id"))] \(digestText(row, "text"))"
            + (digestText(row, "kind") == "correction" ? " (correction)" : "")
            + (subject.isEmpty ? "" : " (subject: \(subject))")
    }

    private static func digestHistoryLine(_ row: JSONValue) -> String { "\(digestText(row, "speaker")): \(digestText(row, "text"))" }

    private static func digestEncounterLine(_ row: JSONValue) -> String {
        "\(digestText(row, "at")) \(digestText(row, "kind")): \(digestText(row, "why"))"
    }

    private static func legacyDigestInput(_ packet: [String: JSONValue]) -> JSONValue {
        func rows(_ value: JSONValue?) -> [JSONValue] {
            if case .array(let rows)? = value { return rows }
            return []
        }
        let caring = packet["caring_context"]?.objectValue
        let mode = packet["mode"]?.stringValue
        let known = rows(packet["known_memories"]), cares = rows(packet["cares"])
        let evidence: [String: JSONValue] = [
            "standingMemories": .string(known.filter { $0.objectValue?["standing"] == .bool(true) }.map(digestMemoryLine).joined(separator: "\n")),
            "recalledMemories": .string(known.filter { $0.objectValue?["standing"] != .bool(true) }.map(digestMemoryLine).joined(separator: "\n")),
            "pendingMemories": .string(rows(packet["pending_memories"]).map(digestMemoryLine).joined(separator: "\n")),
            "cares": .string(cares.map { "[\(digestText($0, "key"))] \(digestText($0, "text"))" }.joined(separator: "\n")),
            "speaker": packet["speaker"] ?? .string(""), "factsEnabled": .string(String(packet["facts_enabled"] == .bool(true))),
            "localTime": packet["local_time"] ?? .string("[absent]"), "timeZone": packet["time_zone"] ?? .string(""),
            "relayed": .string(String(caring?["relayed"] == .bool(true))), "caringEligible": .string(String(caring != nil)),
            "history": .string(rows(caring?["history"]).map(digestHistoryLine).joined(separator: "\n")),
            "encounters": .string(rows(caring?["recent_encounters"]).map(digestEncounterLine).joined(separator: "\n")),
            "work": .string(packet["work"]?.stringValue.map { $0 + "\n" } ?? ""),
            "beliefTarget": packet["belief_target"] ?? .string("[absent]"), "incoming": packet["user_message"] ?? .string(""),
            "reply": packet["assistant_message"] ?? .string(""), "settlement": packet["settlement"] ?? .string(""),
        ]
        return .object(["settlesOnly": .bool(mode == "settlement"), "careWake": .bool(mode == "care_wake"),
            "hasCares": .bool(!cares.isEmpty), "appAuthored": packet["app_authored"] ?? .bool(false),
            "standingAgent": packet["standing_agent"] ?? .bool(false), "evidence": .object(evidence)])
    }

    private static func digestEvidence(_ request: MemoryManagerRequest, context: AfterTurnContext?, turn: Turn,
                                       surface: String, factsEnabled: Bool, acts: [MemoryManagerAct],
                                       personWords: String, legacy: Bool, momentsApart: Bool, limit: Int) throws -> DigestEvidence {
        func redacted(_ text: String) -> JSONValue { .string(TurnSecretRedactor.redactText(text)) }
        func identifier(_ id: String) throws -> JSONValue {
            guard !id.isEmpty, TurnSecretRedactor.redactText(id) == id else {
                throw PartCallError(code: "bad_digest_policy", message: "The digest needs intact, non-secret evidence IDs.")
            }
            return .string(id)
        }
        func memoryRow(_ memory: MemoryManagerExistingMemory, standing: Bool) throws -> JSONValue {
            var row: [String: JSONValue] = ["id": try identifier(memory.id), "text": redacted(memory.content),
                "standing": .bool(standing)]
            row["kind"] = memory.kind.map(redacted)
            row["subject"] = memory.correctionSubject.map(redacted)
            return .object(row)
        }
        let clock = ISO8601DateFormatter()
        clock.timeZone = .current
        let exchangeTime = request.occurredAt ?? context?.event.occurredAt
        let cares: [CognitiveCareLine] = request.settlesOnly ? [] : context?.cares ?? []
        let openMoments = Self.shown(MemoryManagerAct.redactDigestEvidence(.array(Self.deskRows(request.openMoments))), text: 160, rows: .max)
        let openMomentsText = momentsApart ? try openMoments.serialize(pretty: false) : ""
        var settlementFields: [String: JSONValue] = ["person_words": .string(personWords),
            "open_moments": momentsApart ? .string("shown above, under Open moments") : openMoments,
            "completed_acts": Self.shownActs(acts),
            "completed_acts_unavailable": request.completedActsUnavailable.map { .string(TurnSecretRedactor.redactText($0)) } ?? .null,
            "reply_delivered": .bool(request.replyDelivered),
            "person_reply_delivered": .bool(request.personReplyAt != nil)]
        let settlement = try JSONValue.object(settlementFields).serialize(pretty: false)
        let incoming = TurnSecretRedactor.redactText(request.userMessage)
        let reply = TurnSecretRedactor.redactText(request.assistantMessage)
        let beliefTarget = context?.beliefReactionTarget.map { TurnSecretRedactor.redactText($0) }
        let standingCount = max(0, request.standing)
        let standing = try request.existing.prefix(standingCount).map { try memoryRow($0, standing: true) }
        var packet: [String: JSONValue] = [
            "surface": redacted(surface),
            "mode": .string(request.settlesOnly ? "settlement" : request.careWake ? "care_wake" : "exchange"),
            "speaker": redacted(request.personName ?? "the person"), "app_authored": .bool(request.appAuthored),
            "standing_agent": .bool(request.standingAgent), "facts_enabled": .bool(factsEnabled),
            "user_message": .string(incoming), "assistant_message": .string(reply),
            "time_zone": .string(TimeZone.current.identifier), "settlement": .string(settlement),
            "cares": .array(cares.map { .object(["id": .string($0.id.uuidString), "key": .string($0.key), "text": redacted($0.text)]) }),
            "known_memories": .array(standing), "pending_memories": .array([]),
        ]
        if momentsApart { packet["open_moments"] = .string(openMomentsText) }
        if let turnId = request.turnId, !turnId.isEmpty { packet["turn_id"] = try identifier(turnId) }
        packet["session_id"] = try turn.session.map(identifier)
        packet["origin"] = request.origin.map { .string($0.rawValue) }
        packet["local_time"] = exchangeTime.map { .string(clock.string(from: $0)) }
        packet["belief_target"] = beliefTarget.map(JSONValue.string)
        if let caring = context?.caring {
            packet["caring_context"] = .object(["relayed": .bool(caring.relayed), "at": .string(caring.at.ISO8601Format()),
                "history": .array([]), "recent_encounters": .array([])])
        }
        func shape(_ fields: [String: JSONValue]) -> JSONValue { legacy ? legacyDigestInput(fields) : .object(fields) }
        func bytes(_ value: JSONValue) throws -> Int { try value.serializedData(pretty: false).count }
        var remaining = limit - (try bytes(shape(packet)))
        if remaining < 0 {
            // Does it fit without the open moments? Shown apart, they are the packet's own field; otherwise they sit in the settlement.
            if momentsApart { packet["open_moments"] = .string("[]") }
            else {
                settlementFields["open_moments"] = .array([])
                packet["settlement"] = .string(try JSONValue.object(settlementFields).serialize(pretty: false))
            }
            let refusal: (code: String, owner: String)
            if try bytes(shape(packet)) <= limit { refusal = ("digest_desk_limit", "open Desk evidence") }
            else {
                packet["known_memories"] = .array([])
                refusal = try bytes(shape(packet)) <= limit ? ("digest_memory_limit", "standing memories")
                    : ("digest_record_limit", "recorded exchange and its required evidence")
            }
            throw PartCallError(code: refusal.code, message: "The \(refusal.owner) exceeds the digest's \(limit)-byte input limit. The moment remains owed.")
        }
        func budget(_ rows: [JSONValue], line: (JSONValue) -> String, afterRows: Bool = false) throws -> [JSONValue] {
            var admitted: [JSONValue] = []
            for row in rows {
                let byteCount = try legacy ? bytes(.string(line(row))) - 2 : bytes(row)
                let separator = admitted.isEmpty && (legacy || !afterRows) ? 0 : 2
                guard byteCount + separator <= remaining else { continue }
                remaining -= byteCount + separator
                admitted.append(row)
            }
            return admitted
        }
        let pending = try budget(request.pendingTargets.map {
            .object(["id": try identifier($0.id), "text": redacted($0.content)])
        }, line: digestMemoryLine)
        let recalled = try budget(request.existing.dropFirst(standingCount).map { try memoryRow($0, standing: false) },
            line: digestMemoryLine, afterRows: !standing.isEmpty)
        packet["known_memories"] = .array(standing + recalled)
        packet["pending_memories"] = .array(pending)
        if let caring = context?.caring, var row = packet["caring_context"]?.objectValue {
            row["history"] = .array(try budget(caring.context.map {
                .object(["speaker": .string($0.speaker.rawValue), "text": redacted($0.text)])
            }, line: digestHistoryLine))
            row["recent_encounters"] = .array(try budget(caring.recentEncounters.map {
                .object(["at": .string($0.at.ISO8601Format()), "kind": .string($0.kind.rawValue), "why": redacted($0.why)])
            }, line: digestEncounterLine))
            packet["caring_context"] = .object(row)
        }
        if let work = request.took {
            packet["work"] = redacted(work)
            if try bytes(shape(packet)) > limit { packet["work"] = nil }
        }
        let memories = standing + recalled + pending
        // Where a judgment's input goes, in bytes and never in words: the measure any trimming of it is decided on.
        func size(_ value: JSONValue?) -> JSONValue { .int(Int64(value.flatMap { try? bytes($0) } ?? 0)) }
        let caringRow = packet["caring_context"]?.objectValue
        TurnTraceBus.fireFromContext(kind: "memory.judgment.evidence", surface: surface, payload: .object([
            "limitBytes": .int(Int64(limit)), "standingBytes": size(.array(standing)), "recalledBytes": size(.array(recalled)),
            "pendingBytes": size(.array(pending)), "historyBytes": size(caringRow?["history"]),
            "encounterBytes": size(caringRow?["recent_encounters"]), "careBytes": size(packet["cares"]),
            "incomingBytes": size(packet["user_message"]), "replyBytes": size(packet["assistant_message"]),
            "openMomentBytes": size(momentsApart ? packet["open_moments"] : settlementFields["open_moments"]), "completedActBytes": size(settlementFields["completed_acts"]),
            "settlementBytes": size(packet["settlement"]), "workBytes": size(packet["work"]),
        ]), turn: turn)
        return DigestEvidence(input: shape(packet), incoming: incoming, reply: reply, beliefTarget: beliefTarget, settlement: settlement,
            openMoments: openMomentsText, memoryLines: memories.map(digestMemoryLine), shownMemoryIDs: Set(memories.compactMap { $0.objectValue?["id"]?.stringValue }))
    }
}
