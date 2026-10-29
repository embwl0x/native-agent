import NativeAgentCore
import CognitiveSubstrate
import Foundation
import NativeAgentShared
import CryptoKit
import MemoryV2
import ProviderRouting
import TurnTrace
import PersistenceCore
import DreamREMCycle
// Blueprint: | `MindMemoryManager.swift` | `MindMemoryJudgment` struct; `predictionModelKey` (the record's key for the model the judgment runs on, read without changing the request; the interpretation reports the same model), `interpret` (with the cares section when cares are shown), `interpretBatch` (owed turns in one call, the rules once, one section per turn; a missing section stays owed), `appraiseCares`, `relevantRecallIDs`; incremental ranked evidence and catalog-budgeted relevance batches; `AfterTurnMemoryFailure` preserves output limits, request rejections and refusals with distinct recovery |

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
        case .overloaded: return .overloaded
        case .contextTooLong: return .contextTooLong
        case .network: return .network
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
    private static let recallEncodingRecovery = "The recall query and evidence could not be encoded as JSON: a NativeAgent defect in this turn's input, not your memories or the model. This turn's recall judgment could not run; tell the person if it repeats. Changing the selected model cannot fix it."

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
            fix = "The judgment did not return its required JSON shape (\(reason.rawValue)); do not treat it as an empty judgment. Inspect the selected model with \(model); repair its structured response before relying on another pass."
        case .contextTooLong:
            fix = "The judgment input exceeds the selected model's window. Shorten the query or select a larger-window model through \(model); repeating the same input will not fix it."
        case .authExpired, .codexCLISessionExpired:
            fix = "The judgment account needs sign-in. Read \(account) to identify the account, then reconnect it in Providers → Accounts & API keys."
        case .routingUnavailable:
            fix = "The saved judgment route is unavailable. Read \(account) and repair the reported routing error before another pass."
        case .modelUnavailable:
            fix = "The selected judgment model is unavailable. Read \(model) and select a model served by its account."
        case .network:
            fix = "The judgment connection failed. Restore network access before requesting another pass; \(account) identifies its provider."
        case .rateLimited, .overloaded, .deadline:
            fix = "The provider could not complete this judgment (\(reason.rawValue)). Leave the result unresolved; \(model) shows the model choice if a different supported route is needed."
        case .refused:
            fix = "The provider refused this judgment. Leave it unresolved; offer an allowed alternative or stop, without rephrasing or splitting to bypass refusal."
        case .outputLimit:
            fix = "The judgment reached its output limit. Leave it unresolved; reduce the judgment input or use a model with a larger output allowance before another pass."
        case .requestRejected:
            fix = "The provider rejected this judgment request. Leave it unresolved; correct the reported request error before another pass."
        case .provider:
            fix = "The judgment provider failed. Read \(account), then resolve the reported provider cause before another pass."
        }
        return detail.map { $0 + " " + fix } ?? fix
    }

    public func relevantRecallIDs(query: String, candidates: [MemoryManagerExistingMemory], generation: String? = nil, topK: Int? = nil) async
        -> Result<Set<String>, AfterTurnMemoryFailure> {
        let started = ProcessInfo.processInfo.systemUptime
        // Judge the embedding's bounded ranking prefix; lower rows already lost relevance.
        let candidates = topK.map { requested in
            let limit = MemoryRecallScoring.relevanceCandidateLimit(topK: requested, count: candidates.count)
            return Array(candidates.prefix(limit))
        } ?? candidates
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
                } ?? "\(provider)'s model list has no context window for \(model). Refresh that provider's models in Settings or choose a listed model, then retry this query.",
                model: model, surface: surface))
        }
        // UTF-8 bytes conservatively bound tokens without assuming a tokenizer.
        // Leave half the context for reasoning/output and reserve instructions
        // and message framing before packing serialized evidence.
        let payloadByteCap = contextLength / 2 - Self.relevanceEnvelopeByteReserve
        let route = RecallRoute(snapshot: snapshot, surface: surface,
            admission: admission, payloadByteCap: payloadByteCap)
        let routeFinished = ProcessInfo.processInfo.systemUptime
        func failure(_ reason: AfterTurnMemoryFailure.Reason) -> AfterTurnMemoryFailure {
            .init(reason: reason, recovery: reason == .invalidJSON ? Self.recallEncodingRecovery : Self.judgmentRecovery(reason, surface: surface),
                  model: route.model, surface: surface)
        }
        guard payloadByteCap > 0 else { return .failure(failure(.contextTooLong)) }
        guard let encodedQuery = try? JSONSerialization.data(withJSONObject: query, options: [.fragmentsAllowed]) else {
            return .failure(failure(.invalidJSON))
        }
        let queryJSON = String(decoding: encodedQuery, as: UTF8.self)
        let envelopeBytes = "{\"memories\":[],\"query\":\(queryJSON)}".utf8.count
        var recordIDs: [String: String] = [:]
        let scope = generation.map { RecallCacheScope(generation: $0, route: route) }
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
        // Only a completely judged ranking prefix can settle the result. A
        // lower-ranked hit cannot hide unresolved evidence in a higher row.
        var rankingCursor = 0, admittedPrefixCount = 0
        func enough(_ resolved: Set<String>, _ admitted: Set<String>) -> Bool {
            guard let topK, topK > 0 else { return false }
            while rankingCursor < candidates.count, admittedPrefixCount < topK {
                let id = candidates[rankingCursor].id
                guard admitted.contains(id) || resolved.contains(id) else { return false }
                if admitted.contains(id) { admittedPrefixCount += 1 }
                rankingCursor += 1
            }
            return admittedPrefixCount >= topK
        }
        // Parallelize independent records; wait for a record's judgment before
        // dispatching more of its pages, and stop once it is admitted.
        let result: Result<[String: Bool], AfterTurnMemoryFailure> = await withTaskGroup(
            of: ([RecallPage], Result<Set<String>, AfterTurnMemoryFailure>, Double).self
        ) { group in
            var next = 0
            var pageStart: String.UnicodeScalarView.Index?
            var pendingPage: RecallPage?
            var running = 0
            var inFlight: Set<String> = []
            var admitted: Set<String> = []
            var resolved: Set<String> = []
            var exhausted: Set<String> = []
            var uncheckedCounts: [String: Int] = [:]
            var completed: [String: Bool] = [:]
            // Bound speculative work even for a very large context window.
            let pageLimit = max(1, min(topK ?? candidates.count, candidates.count)) * 8
            while true {
                guard !Task.isCancelled else { group.cancelAll(); return .failure(failure(.cancelled)) }
                while running < 2, !enough(resolved, admitted) {
                    var batch: [RecallPage] = []
                    var batchBytes = envelopeBytes
                    while batch.count < pageLimit, !enough(resolved, admitted) {
                        if let page = pendingPage {
                            if admitted.contains(page.id) {
                                uncheckedCounts[page.id, default: 0] -= 1
                                pendingPage = nil
                                continue
                            }
                            guard !inFlight.contains(page.id) else { break }
                            let packingStarted = ProcessInfo.processInfo.systemUptime
                            let rowBytes = page.encodedRow.utf8.count + String(batch.count).utf8.count - 1 + (batch.isEmpty ? 0 : 1)
                            batchingMilliseconds += (ProcessInfo.processInfo.systemUptime - packingStarted) * 1_000
                            if batchBytes + rowBytes > payloadByteCap { break }
                            batchBytes += rowBytes
                            batch.append(page)
                            pendingPage = nil
                            continue
                        }
                        guard next < candidates.count else { break }
                        let candidate = candidates[next]
                        if admitted.contains(candidate.id) || resolved.contains(candidate.id) {
                            next += 1
                            pageStart = nil
                            continue
                        }
                        guard !inFlight.contains(candidate.id) else { break }
                        let pagingStarted = ProcessInfo.processInfo.systemUptime
                        let scalars = candidate.content.unicodeScalars
                        let start = pageStart ?? scalars.startIndex
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
                                group.cancelAll(); return .failure(failure(.invalidJSON))
                            }
                            encodedRow = data
                            if envelopeBytes + data.count <= payloadByteCap { break }
                            guard length > 1 else {
                                group.cancelAll(); return .failure(failure(.contextTooLong))
                            }
                            length /= 2
                            end = scalars.index(start, offsetBy: length)
                            content = String(scalars[start..<end])
                        }
                        let identity = ["query": query, "id": candidate.id, "content": content, "kind": candidate.kind ?? ""]
                        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else {
                            group.cancelAll(); return .failure(failure(.invalidJSON))
                        }
                        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        let page = RecallPage(key: key, id: candidate.id, encodedRow: String(decoding: encodedRow, as: UTF8.self))
                        recordIDs[key] = candidate.id
                        preparedPages += 1
                        if end == scalars.endIndex {
                            exhausted.insert(candidate.id)
                            next += 1
                            pageStart = nil
                        } else {
                            pageStart = scalars.index(end, offsetBy: -min(200, length / 2))
                        }
                        pagingMilliseconds += (ProcessInfo.processInfo.systemUptime - pagingStarted) * 1_000
                        let cacheStarted = ProcessInfo.processInfo.systemUptime
                        let cached = if let scope { await relevanceCache.read(scope: scope, keys: [key])[key] } else { nil as Bool? }
                        cacheMilliseconds += (ProcessInfo.processInfo.systemUptime - cacheStarted) * 1_000
                        if let cached {
                            cachedPages += 1
                            completed[key] = cached
                            if cached { admitted.insert(candidate.id) }
                            if exhausted.contains(candidate.id), uncheckedCounts[candidate.id, default: 0] == 0 {
                                resolved.insert(candidate.id)
                            }
                        } else {
                            uncheckedCounts[candidate.id, default: 0] += 1
                            pendingPage = page
                        }
                        guard !Task.isCancelled else { break }
                    }
                    if enough(resolved, admitted) { break }
                    for page in batch where admitted.contains(page.id) {
                        uncheckedCounts[page.id, default: 0] -= 1
                    }
                    batch.removeAll { admitted.contains($0.id) }
                    if batch.isEmpty { break }
                    let ids = Set(batch.map(\.id))
                    inFlight.formUnion(ids)
                    running += 1
                    providerBatches += 1
                    if providerStarted == nil { providerStarted = ProcessInfo.processInfo.systemUptime }
                    let rows = batch.enumerated().map { index, page in
                        page.encodedRow.replacingOccurrences(of: #""id":"0""#, with: "\"id\":\"\(index)\"")
                    }.joined(separator: ",")
                    let prompt = "{\"memories\":[\(rows)],\"query\":\(queryJSON)}"
                    let dispatched = batch
                    group.addTask {
                        let started = ProcessInfo.processInfo.systemUptime
                        let result = await relevantRecallBatch(prompt: prompt, candidates: dispatched, route: route)
                        return (dispatched, result, (ProcessInfo.processInfo.systemUptime - started) * 1_000)
                    }
                }
                guard let (batch, result, duration) = await group.next() else { break }
                providerFinished = ProcessInfo.processInfo.systemUptime
                providerTotalMilliseconds += duration
                judgedPages += batch.count
                nativeLog("Memory recall batch: duration_ms=\(Int(duration)) pages=\(batch.count)")
                running -= 1
                inFlight.subtract(batch.map(\.id))
                switch result {
                case .success(let keys):
                    for page in batch {
                        completed[page.key] = keys.contains(page.key)
                        if keys.contains(page.key) { admitted.insert(page.id) }
                        uncheckedCounts[page.id, default: 0] -= 1
                        if exhausted.contains(page.id), uncheckedCounts[page.id, default: 0] == 0 {
                            resolved.insert(page.id)
                        }
                    }
                case .failure(let failure): group.cancelAll(); return .failure(failure)
                }
            }
            return .success(completed)
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let timings: [String: JSONValue] = [
            "duration_ms": .double(elapsed), "pages": .int(Int64(preparedPages)),
            "cached_pages": .int(Int64(cachedPages)), "provider_batches": .int(Int64(providerBatches)),
            "route_ms": .double((routeFinished - started) * 1_000),
            "paging_ms": .double(pagingMilliseconds),
            "cache_ms": .double(cacheMilliseconds),
            "batching_ms": .double(batchingMilliseconds),
            "provider_wall_ms": .double(providerStarted.flatMap { start in
                providerFinished.map { ($0 - start) * 1_000 }
            } ?? 0),
            "payload_byte_cap": .int(Int64(payloadByteCap)),
            "provider_total_ms": .double(providerTotalMilliseconds), "judged_pages": .int(Int64(judgedPages)),
        ]
        TurnTraceBus.fireFromContext(kind: "memory.recall.relevance", surface: surface, payload: .object(timings))
        let detail = timings.sorted { $0.key < $1.key }.map { key, value in
            switch value {
            case .double(let value): return "\(key)=\(Int(value))"
            case .int(let value): return "\(key)=\(value)"
            default: return key
            }
        }.joined(separator: " ")
        nativeLog("Memory recall relevance: \(detail)")
        switch result {
        case .failure(let failure): return .failure(failure)
        case .success(let completed):
            guard !Task.isCancelled else { return .failure(failure(.cancelled)) }
            if let scope { await relevanceCache.store(scope: scope, judgments: completed) }
            return .success(Set(completed.filter(\.value).compactMap { recordIDs[$0.key] }))
        }
    }

    // Keep evidence paging independent of prompt wording: preserve the established
    // 819-byte instruction plus 128-byte framing allowance when shortening copy.
    private static let relevanceEnvelopeByteReserve = 947

    private static var relevanceSystem: String {
        get throws { try completionPolicy("recall-selection", section: "system") }
    }

    private func relevantRecallBatch(prompt: String, candidates: [RecallPage], route: RecallRoute) async
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
            response = try await ConversationPrefixTelemetry.withUnmeasuredRequestShape {
                try await route.admission.withModelContext {
                    try await PrivateWorkContextAssembly.$current.withValue(.taskOnly) {
                        try await makeLLMClient().complete(prompt: prompt, system: Self.relevanceSystem, model: model, surface: surface, purpose: "recall_judge", tools: nil)
                    }
                }
            }
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

    /// The Memory provider row, as every after-turn judgment reaches it.
    private struct JudgmentRoute: Sendable {
        let surface: String
        let admission: TurnRouteAdmission
        var model: String { admission.modelId }

        func failed(_ reason: AfterTurnMemoryFailure.Reason, recovery: String? = nil) -> AfterTurnMemoryFailure {
            .init(reason: reason, recovery: MindMemoryJudgment.judgmentRecovery(reason, surface: surface, detail: recovery),
                  model: model, surface: surface)
        }
    }

    /// The record's key for the model this turn's judgment would run on (the
    /// same key its interpretation reports). nil: no model resolves, so no
    /// prediction stands on an unknown judge.
    public func predictionModelKey() async -> String? {
        guard let route = try? await Self.judgmentRoute() else { return nil }
        let judging = route.model
        return AfterTurnInterpretation.judgingKey(surface: route.surface, model: judging)
    }

    private static func judgmentRoute() async throws -> JudgmentRoute {
        let snapshot = try await SwiftNativeProviderRouting().checkedRoutingSnapshot()
        let surface = snapshot.pinnedModels["memory"] != nil || snapshot.activeProviders["memory"] != nil ? "memory" : "chat"
        return try JudgmentRoute(surface: surface, admission: snapshot.routeAdmission(
            for: surface, choice: nil, inheritingCall: true))
    }

    /// Stop interrupts unfinished provider work. A returned reply belongs to
    /// settlement, even when cancellation arrives with that reply.
    private func judgedText(prompt: String, system: String, purpose: String,
                            route: JudgmentRoute) async throws -> String {
        let text: String
        do {
            try Task.checkCancellation()
            text = try await ConversationPrefixTelemetry.withUnmeasuredRequestShape {
                try await route.admission.withModelContext {
                    try await PrivateWorkContextAssembly.$current.withValue(.taskOnly) {
                        try await makeLLMClient().complete(prompt: prompt, system: system, model: route.model,
                            surface: route.surface, purpose: purpose, tools: nil)
                    }
                }
            }
        } catch {
            let cause = ProviderFailure.classify(error)
            throw route.failed(Self.reason(error, cause: cause), recovery: ProviderFailure.diagnosticDescription(error))
        }
        return text
    }

    /// Settlement parses JSON and returns the produced typed result, even after Stop.
    private static func settledObject<T: Sendable>(text: String, route: JudgmentRoute,
        parse: @escaping @Sendable ([String: Any]) throws -> T) async throws -> T {
        let result: Result<T, AfterTurnMemoryFailure> = await settle {
            guard let fields = try? JSONValue.decodeCompletion(text, as: [String: JSONValue].self) else {
                return .failure(route.failed(.invalidJSON))
            }
            do { return .success(try parse(fields.mapValues(\.foundationObject))) }
            catch { return .failure((error as? AfterTurnMemoryFailure) ?? route.failed(.invalidJSON)) }
        }
        return try result.get()
    }

    public func interpret(_ request: MemoryManagerRequest, context: AfterTurnContext?,
                          factsEnabled: Bool) async throws -> AfterTurnInterpretation? {
        guard !request.userMessage.isEmpty else { return nil }
        let route = try await Self.judgmentRoute()
        let prompt = try Self.prompt(request, context: context, factsEnabled: factsEnabled)
        let system = try completionPolicy("turn-interpretation", section: "system")
        let text = try await judgedText(prompt: prompt, system: system,
            purpose: LLMCallContext.purpose == "memory_held" ? "memory_held" : "memory_interpret", route: route)
        return try await Self.settledObject(text: text, route: route) { object in
            try Self.parseInterpretation(object, request: request, context: context, route: route)
        }
    }

    /// One exchange's reply object as a complete interpretation, or the
    /// failure naming the section that is missing or malformed.
    private static func parseInterpretation(_ object: [String: Any], request: MemoryManagerRequest,
                                            context: AfterTurnContext?, route: JudgmentRoute) throws -> AfterTurnInterpretation {
        func failed(_ reason: AfterTurnMemoryFailure.Reason) -> AfterTurnMemoryFailure { route.failed(reason) }
        guard let memoriesValue = object["memories"] as? [Any],
              object.keys.contains("caring"), object.keys.contains("affect") else { throw failed(.missingSections) }
        guard let caringObject = object["caring"] as? [String: Any],
              let caring = CaringAppraisalLane.parse(caringObject) else { throw failed(.invalidCaring) }
        guard let affectObject = object["affect"] as? [String: Any],
              let affectData = try? JSONSerialization.data(withJSONObject: affectObject),
              let affect = try? JSONDecoder().decode(CognitiveSubstrate.AffectAppraisal.self, from: affectData) else { throw failed(.invalidAffect) }
        guard let memories = try? MemoryManagerLane.parse(memoriesValue) else { throw failed(.invalidMemories) }
        var cares: [CognitiveCareJudgment] = []
        if let shown = context?.cares, !shown.isEmpty {
            guard let parsed = CognitiveCareJudgment.parse(object["cares"], shown: shown) else { throw failed(.invalidCares) }
            cares = parsed
        }
        return AfterTurnInterpretation(memories: memories, affect: affect, caring: caring,
                                       cares: cares, appAuthored: request.appAuthored, model: route.model, surface: route.surface)
    }

    /// SEVERAL OWED EXCHANGES, ONE CALL (docs/COGNITION_WIRING.md, "Deferral").
    /// The rules once, then each exchange's own request under its id;
    /// the reply has one section per id. A section that is missing, malformed,
    /// or whose id appears twice is nil: that row stays owed (no guess).
    public func interpretBatch(_ inputs: [MemoryBatchInput]) async throws -> [AfterTurnInterpretation?] {
        guard !inputs.isEmpty, inputs.count <= MemoryManagerLane.batchLimit else { throw AfterTurnInterpretationFailure.envelope }
        let route = try await Self.judgmentRoute()
        let prompt = try Self.interpretationRules + "\n"
            + completionPolicy("held-turn-batch", section: "prompt")
            + inputs.enumerated().map { index, input in
                try "Exchange id=\(index)\n" + Self.prompt(input.request, context: input.context,
                                                       factsEnabled: input.factsEnabled, includeRules: false)
            }.joined(separator: "\n\n")
        let text = try await judgedText(prompt: prompt,
            system: try completionPolicy("held-turn-batch", section: "system"),
            purpose: "memory_held", route: route)
        return try await Self.settledObject(text: text, route: route) { object -> [AfterTurnInterpretation?] in
            guard let replies = object["turns"] as? [Any] else { throw route.failed(.missingSections) }
            // Every repeated id is ambiguous, even if one section is malformed.
            let sections = Dictionary(grouping: replies.compactMap { element -> (id: String, value: Any)? in
                guard let reply = element as? [String: Any], let id = reply["id"] as? String else { return nil }
                return (id, reply["interpretation"] ?? NSNull())
            }, by: \.id)
            return inputs.enumerated().map { index, input in
                guard let matches = sections[String(index)], matches.count == 1,
                      let value = matches.first?.value as? [String: Any] else { return nil }
                return try? Self.parseInterpretation(value, request: input.request, context: input.context, route: route)
            }
        }
    }

    /// The cares section alone, over one stretch of a conversation she lived:
    /// the once-only reading of her recent life. Same section, same parse.
    public func appraiseCares(conversation: String, speaker: String,
                              shown: [CognitiveCareLine]) async throws -> [CognitiveCareJudgment] {
        guard !shown.isEmpty else { return [] }
        let route = try await Self.judgmentRoute()
        let prompt = try completionPolicy("care-appraisal", section: "prompt", arguments: [
            speaker,
            conversation,
            Self.caresSection(shown),
            Self.caresShape
        ])
        let system = try completionPolicy("care-appraisal", section: "system")
        let text = try await judgedText(prompt: prompt, system: system, purpose: "memory_interpret", route: route)
        return try await Self.settledObject(text: text, route: route) { object in
            guard let cares = CognitiveCareJudgment.parse(object["cares"], shown: shown) else {
                throw route.failed(.invalidCares)
            }
            return cares
        }
    }

    /// Her cares as data, then what to say about them. Empty when no care is
    /// shown, which leaves every other section's prompt exactly as it was.
    static func caresSection(_ shown: [CognitiveCareLine]) throws -> String {
        guard !shown.isEmpty else { return "" }
        return try completionPolicy("turn-interpretation", section: "cares", arguments: [
            shown.map { "[\($0.key)] \($0.text)" }.joined(separator: "\n")
        ])
    }

    static let caresShape = #""cares":[{"care":"c2|new","about":null,"between":false,"moved":0.0,"by":"them|her|world","felt":"...","note":"...","open":null,"closes":false,"stance":null or {"text":"...","because":"...","wouldChangeMind":"..."}}]"#

    /// The interpretation rules, shared by the one-turn prompt (in place, so its
    /// bytes are unchanged) and once per batch.
    static var interpretationRules: String {
        get throws { try completionPolicy("turn-interpretation", section: "rules") }
    }

    static func prompt(_ request: MemoryManagerRequest, context: AfterTurnContext?,
                       factsEnabled: Bool, includeRules: Bool = true) throws -> String {
        let existing = request.existing.map {
            "[\($0.id)] \($0.content)" + ($0.kind == "correction" ? " (correction)" : "")
                + ($0.correctionSubject.map { " (subject: \($0))" } ?? "")
        }.joined(separator: "\n")
        let history = context?.caring?.context.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n") ?? ""
        let encounters = context?.caring?.recentEncounters.map {
            "\($0.at.ISO8601Format()) \($0.kind.rawValue): \($0.why)"
        }.joined(separator: "\n") ?? ""
        let shown = context?.cares ?? []
        let clock = ISO8601DateFormatter()
        clock.timeZone = .current
        let exchangeTime = request.occurredAt ?? context?.event.occurredAt ?? Date()
        return try completionPolicy("turn-interpretation", section: "prompt", arguments: [
            request.personName ?? "the person",
            request.appAuthored ? completionPolicy("turn-interpretation", section: "app-authored") : request.standingAgent ? completionPolicy("turn-interpretation", section: "standing-agent") : ".",
            String(factsEnabled),
            clock.string(from: exchangeTime),
            TimeZone.current.identifier,
            includeRules ? Self.interpretationRules : "",
            String(context?.caring?.relayed ?? false),
            String(context?.caring != nil),
            existing,
            request.pendingTargets.map { "[\($0.id)] \($0.content)" }.joined(separator: "\n"),
            request.forgotten.joined(separator: "\n"),
            history,
            encounters,
            request.userMessage,
            request.assistantMessage,
            request.took.map { $0 + "\n" } ?? "",
            Self.caresSection(shown),
            MemoryKindStamp.writerKinds.joined(separator: "|"),
            shown.isEmpty ? "" : "," + Self.caresShape
        ])
    }
}
