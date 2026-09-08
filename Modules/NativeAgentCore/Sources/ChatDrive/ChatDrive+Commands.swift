import Foundation
import ApprovalInbox
import NativeAgentCore
import ChatOrchestration
import KnowledgeGraph
import MemoryV2
import PersistenceCore
import PersonaEngine
import ProviderRouting
import DoctorChecks
import TrustCenter

extension ChatDriveMain {
    /// Fixture-only provider transport for the executable's hermetic stream
    /// evaluation. It is deliberately local to ChatDrive: production routing
    /// never sees it, and callers must opt in through the guarded environment
    /// checked by `streamClientForCurrentProcess()`.
    private final class ChatDriveHermeticStreamingLLM: LLMClient, StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
        private let chunks: [String]

        init(chunks: [String]) {
            self.chunks = chunks
        }

        private var reply: String { chunks.joined() }

        func complete(prompt: String, system: String?, model: String?) async throws -> String {
            reply
        }

        func complete(
            prompt: String,
            system: String?,
            model: String?,
            surface: String
        ) async throws -> String {
            reply
        }

        func complete(
            prompt: String,
            system: String?,
            model: String?,
            tools: [LLMToolSchema]?
        ) async throws -> String {
            reply
        }

        func completeMessages(
            messages: [LLMMessage],
            system: String?,
            model: String?,
            surface: String,
            tools: [LLMToolSchema]?
        ) async throws -> String {
            reply
        }

        func stream(
            prompt: String,
            system: String?,
            model: String?
        ) -> AsyncThrowingStream<String, Error> {
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                Task {
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                }
            }
        }

        func streamMessages(
            messages: [LLMMessage],
            system: String?,
            model: String?,
            surface: String,
            tools: [LLMToolSchema]?
        ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                Task {
                    for chunk in chunks { continuation.yield(.textDelta(chunk)) }
                    continuation.finish()
                }
            }
        }
    }

    private struct ChatDriveHermeticNoTools: ToolDispatchClient {
        func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue { .null }
        func listAvailableTools() async throws -> [String] { [] }
    }

    static func runDispatch(tool: String, jsonInput: String, surface: String) async throws {
        FileHandle.standardError.write(Data("[dispatch] surface=\(surface) tool=\(tool) input=\(jsonInput)\n".utf8))
        // Parse input JSON
        guard let data = jsonInput.data(using: .utf8),
              let parsed = try? JSONValue.parse(data),
              case .object(let input) = parsed else {
            commandLineUsageError("dispatch input must be a JSON object")
        }
        // Input validation is deliberately before dispatcher construction.
        // `SwiftToolDispatcher` resolves the active data root and owner-backed
        // services; a malformed diagnostic argv must not even open that seam.
        let d = SwiftToolDispatcher(enforceLazyToolLoading: false)
        do {
            let result = try await d.dispatch(tool: tool, input: input, surface: surface)
            print("=== \(tool) returned ===")
            if let s = try? result.serialize(pretty: true) {
                print(s)
            } else {
                print(String(describing: result))
            }
        } catch {
            print("=== ERROR ===")
            print("\(error)")
            exit(1)
        }
    }

    static func runChat(
        prompt: String,
        surface: String,
        modelOverride: String?,
        effortOverride: String?
    ) async throws {
        let sessionId = chatDriveSessionID(fallbackPrefix: "drive")
        // Validate the guarded subprocess transport before asking the router
        // for defaults. `computeModelPreferences()` opens (and may create)
        // root-backed provider state, so an invalid fixture invocation must be
        // refused before any data-root byte can exist — mirroring runStream.
        let client = try chatClientForCurrentProcess()
        let prefs = try await SwiftNativeProviderRouting().computeModelPreferences()
        let pick = prefs[canonicalRoutingSurface(surface)] ?? prefs["chat"]
        guard let pick else { throw ProviderRoutingError.unavailable }
        let model = modelOverride ?? pick.model
        let effort = effortOverride ?? pick.reasoningEffort
        FileHandle.standardError.write(
            Data("[chat] sessionId=\(sessionId)\n[chat] surface=\(surface) model=\(model) effort=\(effort)\n[chat] prompt=\(prompt)\n".utf8)
        )
        let started = Date()
        do {
            let resp = try await client.chat(
                message: prompt,
                sessionId: sessionId,
                model: model,
                reasoningEffort: effort,
                fileAccess: "workspace",
                attachments: [],
                persona: nil,
                surface: surface,
                suppressUserAppend: false
            )
            guard !resp.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "ChatDrive",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "chat completed without assistant text"]
                )
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            // The app process outlives its detached trace writes; this CLI
            // exits right here. Await the trace lanes so the turn's durable
            // receipts (turn.terminal included) cannot lose the race with exit.
            await drainTurnTracePersistence()
            print("--- ASSISTANT REPLY ---")
            print(resp.output)
            print("--- META ---")
            print("model:", resp.model)
            print("runId:", resp.runId)
            print("session:", resp.sessionId ?? "(nil)")
            print("elapsed_ms:", elapsed)
        } catch {
            // Error turns emit traces too — drain before the failure exit so
            // a failed turn's receipts are as durable as a successful one's.
            await drainTurnTracePersistence()
            print("--- ERROR ---")
            print("\(error)")
            exit(1)
        }
    }

    /// The ordinary CLI builds the production client. This fixture seam is
    /// intentionally narrower than a provider setting: it replaces only the
    /// transport after an explicit hermetic opt-in, while retaining the real
    /// ChatDrive command, session persistence, routing admission, orchestration,
    /// and terminal-trace path used by the non-streaming CLI.
    static func chatClientForCurrentProcess() throws -> any ChatOrchestrationClient {
        let environment = ProcessInfo.processInfo.environment
        guard let reply = environment["NATIVE_AGENT_CHAT_DRIVE_REPLY"] else {
            return makeChatOrchestrationClient()
        }
        guard environment["NATIVE_AGENT_CHAT_DRIVE_HERMETIC"] == "1" else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_REPLY requires NATIVE_AGENT_CHAT_DRIVE_HERMETIC=1")
        }
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_REPLY must be non-empty")
        }
        return hermeticClient(chunks: [reply])
    }

    static func runStream(
        prompt: String,
        surface: String,
        modelOverride: String?,
        effortOverride: String?
    ) async throws {
        let sessionId = chatDriveSessionID(fallbackPrefix: "drive-stream")
        // Validate the guarded subprocess transport before asking the router
        // for defaults. Invalid fixture input must not open a root-backed
        // routing seam as a side effect of a command-line usage error.
        let client = try streamClientForCurrentProcess()
        let prefs = try await SwiftNativeProviderRouting().computeModelPreferences()
        let pick = prefs[canonicalRoutingSurface(surface)] ?? prefs["chat"]
        guard let pick else { throw ProviderRoutingError.unavailable }
        let model = modelOverride ?? pick.model
        let effort = effortOverride ?? pick.reasoningEffort
        FileHandle.standardError.write(
            Data("[stream] sessionId=\(sessionId)\n[stream] surface=\(surface) model=\(model) effort=\(effort)\n[stream] prompt=\(prompt)\n".utf8)
        )

        let started = Date()
        var accumulated = ""
        var finalReply: String?
        var deltaCount = 0
        do {
            for try await event in client.chatStream(
                message: prompt,
                sessionId: sessionId,
                model: model,
                reasoningEffort: effort,
                fileAccess: "workspace",
                attachments: [],
                persona: nil,
                surface: surface,
                suppressUserAppend: false
            ) {
                switch event {
                case .delta(let text):
                    accumulated += text
                    deltaCount += 1
                    print(text, terminator: "")
                    fflush(stdout)
                case .toolUse(let name, _):
                    FileHandle.standardError.write(Data("\n[stream] tool_use \(name)\n".utf8))
                case .toolResult(let name, _):
                    FileHandle.standardError.write(Data("[stream] tool_result \(name)\n".utf8))
                case .notice(let kind, let text):
                    FileHandle.standardError.write(Data("[stream] notice \(kind): \(text)\n".utf8))
                case .final(let result):
                    finalReply = result.reply
                case .error(let message):
                    throw NSError(
                        domain: "ChatDriveStream",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            }
            guard deltaCount > 0 else {
                throw NSError(
                    domain: "ChatDriveStream",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "stream ended without an assistant delta"]
                )
            }
            guard let finalReply else {
                throw NSError(
                    domain: "ChatDriveStream",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "stream ended without a terminal event"]
                )
            }
            guard finalReply == accumulated else {
                throw NSError(
                    domain: "ChatDriveStream",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "stream deltas did not equal terminal reply"]
                )
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            // Same process-exit drain as runChat: the stream's terminal trace
            // is fired before the event stream finishes, but its disk append
            // is detached and must be awaited before this short-lived process
            // exits.
            await drainTurnTracePersistence()
            print("\n--- STREAM META ---")
            print("reply:", finalReply)
            print("delta_count:", deltaCount)
            print("session:", sessionId)
            print("elapsed_ms:", elapsed)
        } catch {
            await drainTurnTracePersistence()
            print("\n--- STREAM ERROR ---")
            print("\(error)")
            exit(1)
        }
    }

    /// The CLI's new-conversation owner. A missing environment value creates
    /// one fresh owned session; a supplied value is normalized through the
    /// same path-safe identity owner persistence rechecks later. Invalid
    /// input must not turn into a fresh UUID, because that silently splits a
    /// headless multi-turn conversation into an orphan session.
    static func chatDriveSessionID(fallbackPrefix: String) -> String {
        if let raw = ProcessInfo.processInfo.environment["NA_CHAT_SESSION"] {
            guard let normalized = NativeAgentChatSessionID.normalizedPathComponent(raw) else {
                commandLineUsageError(
                    "NA_CHAT_SESSION must be a non-empty filesystem-safe chat session id"
                )
            }
            return normalized
        }
        return "\(fallbackPrefix)-\(UUID().uuidString.prefix(8))"
    }

    /// Turn-trace persistence is fire-and-forget off the turn path: the plan
    /// row rides `TurnPlanTraceWriter`'s chained writer and every bus event
    /// (terminal receipt included) rides the emission→deliver→persist pumps.
    /// The app stays alive so those detached writes always land; this CLI
    /// exits immediately after one turn, so it must await the same drains the
    /// app runs at termination. Event-driven waits only — no sleeps.
    static func drainTurnTracePersistence() async {
        await TurnPlanTraceWriter.shared.drain()
        await TurnTraceBus.shared.drainForProcessExit()
    }

    /// The ordinary CLI always builds the production client.  The environment
    /// fixture exists solely for a subprocess evaluation of this executable:
    /// it still exercises the real chat-stream façade, persistence, and trace
    /// writer, but replaces only the provider transport with declared chunks.
    /// An accidentally-present chunk variable is rejected unless the explicit
    /// hermetic opt-in accompanies it, so diagnostics cannot silently pretend
    /// to be a live provider turn.
    static func streamClientForCurrentProcess() throws -> any ChatOrchestrationClient {
        let environment = ProcessInfo.processInfo.environment
        guard let rawChunks = environment["NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS"] else {
            return makeChatOrchestrationClient()
        }
        guard environment["NATIVE_AGENT_CHAT_DRIVE_HERMETIC"] == "1" else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS requires NATIVE_AGENT_CHAT_DRIVE_HERMETIC=1")
        }
        guard let data = rawChunks.data(using: .utf8),
              let chunks = try? JSONDecoder().decode([String].self, from: data),
              !chunks.isEmpty,
              chunks.allSatisfy({ !$0.isEmpty }) else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS must be a non-empty JSON string array")
        }

        return hermeticClient(chunks: chunks)
    }

    /// Shared assembly for the two explicitly opt-in subprocess fixtures.
    /// The fixture only supplies deterministic provider output; all stateful
    /// chat owners are still bound to the caller's exact data root.
    private static func hermeticClient(chunks: [String]) -> any ChatOrchestrationClient {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let llm = ChatDriveHermeticStreamingLLM(chunks: chunks)
        let tools = ChatDriveHermeticNoTools()
        let engine = SwiftNativeTurnEngine(
            persona: SwiftNativePersonaEngine.isolated(dataRoot: dataRoot),
            memory: nil,
            router: SwiftNativeProviderRouting(dataRoot: dataRoot),
            trust: SwiftNativeTrustCenter(dataRoot: dataRoot),
            llm: llm,
            tools: tools,
            remPinsDataRoot: dataRoot,
            memoryPromoter: nil
        )
        return makeChatOrchestrationClient(
            engine: engine,
            llm: llm,
            tools: tools,
            dataRoot: dataRoot,
            streamingLLM: llm
        )
    }

    static func runProviderPrefs(surface: String?) async throws {
        let routing = SwiftNativeProviderRouting()
        // This is deliberately the no-recovery read: an operator's probe must
        // never repair a partial provider-selection transaction as a side
        // effect. Pending/corrupt authority is an explicit failed probe.
        let snapshot = try await routing.checkedRoutingSnapshotReadOnly()
        let prefs = snapshot.preferences
        func object(_ pref: SurfacePreference) -> JSONValue {
            let activeProvider = ProviderRoutingSurfaceLookup.value(
                snapshot.activeProviders,
                pref.surface
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let inferredProvider = routing.inferProviderForModel(pref.model)
            // This mirrors the LLM adapter's no-active-provider fallback: a
            // model family chooses its provider; an unknown but valid model
            // reaches the Codex adapter. Never emit an empty provider and
            // never hide which branch produced the receipt.
            let provider = (activeProvider?.isEmpty == false ? activeProvider : nil)
                ?? inferredProvider
                ?? "codex"
            let providerSource = activeProvider?.isEmpty == false
                ? "active_provider"
                : inferredProvider == nil ? "codex_fallback" : "model_family"
            return .object([
                "surface": .string(pref.surface),
                "provider": .string(provider),
                "providerSource": .string(providerSource),
                "model": .string(pref.model),
                "reasoningEffort": .string(pref.reasoningEffort),
                "serviceTier": .string(pref.serviceTier),
                "modelKnown": pref.modelKnown.map { .bool($0) } ?? .null,
            ])
        }
        let out: JSONValue
        if let surface, !surface.isEmpty {
            let canonicalSurface = canonicalRoutingSurface(surface)
            guard let pref = prefs[canonicalSurface] else {
                FileHandle.standardError.write(Data("unknown surface: \(surface)\n".utf8))
                exit(64)
            }
            out = object(pref)
        } else {
            let entries = prefs.keys.sorted().compactMap { prefs[$0].map(object) }
            out = .array(entries)
        }
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runDoctor(repair: Bool) async throws {
        FileHandle.standardError.write(Data("[doctor] repair=\(repair)\n".utf8))
        // checkLLM: false — the flag is dead everywhere (FIX-5b); this CLI no
        // longer offers a switch whose only effect was to print itself back.
        let results = try await makeDoctorChecks().runAll(repair: repair, checkLLM: false)
        let status: String = {
            if results.contains(where: { $0.status == "fail" }) { return "fail" }
            if results.contains(where: { $0.status == "warn" }) { return "warn" }
            return "ok"
        }()
        let checks = results.map { result -> JSONValue in
            var obj: [String: JSONValue] = [
                "id": .string(result.id),
                "title": .string(result.title),
                "status": .string(result.status),
                "detail": .string(result.detail),
            ]
            obj["repair"] = result.repair.map { .string($0) } ?? .null
            return .object(obj)
        }
        let payload: JSONValue = .object([
            "status": .string(status),
            "repair": .bool(repair),
            "checks": .array(checks),
        ])
        print((try? payload.serialize(pretty: true)) ?? "\(payload)")
    }

    static func runMemoryMigrate(dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let report = await MemoryV2Migrator(dataRoot: dataRoot).migrate()
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "memoriesImported": .int(Int64(report.memoriesImported)),
            "proposalsImported": .int(Int64(report.proposalsImported)),
            "tombstonesImported": .int(Int64(report.tombstonesImported)),
            "skippedAlreadyMigrated": .bool(report.skippedAlreadyMigrated),
            "errors": .array(report.errors.map { .string($0) }),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runMemoryRecall(dataRootPath: String, query: String, k: Int) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let bridge = MemoryStorageBridge(storage: storage)
        // Fail-closed: don't silently swap in random vectors when CoreML is
        // unavailable. Memory recall against a mock embedder returns noise
        // (random L2-normalized vectors), which looks like a working system
        // and quietly ships the wrong answer. `NATIVE_AGENT_EMBEDDING_MOCK=1`
        // is the explicit developer test opt-in.
        let embedder: any EmbeddingProvider = {
            if let coreML = try? CoreMLEmbeddingProvider.bundled(extrasRoot: dataRoot) { return coreML }
            if ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1" {
                return MockEmbeddingProvider(dimensions: 384)
            }
            return FailClosedEmbeddingProvider(dimensions: 384)
        }()
        let memory = SwiftNativeMemoryV2(embedder: embedder, storage: bridge)
        let response = try await memory.recall(
            MemoryV2RecallRequest(text: query, topK: max(1, k), persona: nil)
        )
        let hits: [JSONValue] = response.hits.map { hit in
            var obj: [String: JSONValue] = [
                "preview": .string(hit.preview),
                "score": .double(hit.score),
            ]
            if let source = hit.source { obj["source"] = .string(source) }
            if let ts = hit.ts { obj["ts"] = .string(ts) }
            return .object(obj)
        }
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "query": .string(query),
            "total": .int(Int64(response.total)),
            "hits": .array(hits),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runMemoryEmbeddingEpoch(action: String, dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let bridge = MemoryStorageBridge(storage: storage)
        let embedder = ManagedEmbeddingProvider(dataRoot: dataRoot)
        let memory = SwiftNativeMemoryV2(embedder: embedder, storage: bridge)

        var activation: MemoryEmbeddingEpochActivationReport?
        switch action {
        case "status":
            break
        case "activate":
            activation = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
        case "rollback":
            _ = try await memory.rollbackMemoryEmbeddingEpochActivation()
        default:
            throw NSError(domain: "ChatDriveMemoryEpoch", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "unknown memory-embedding-epoch action: \(action)"
            ])
        }
        let state = try await storage.embeddingEpochState()
        let providerEpoch = await memory.embeddingEpoch()?.rawValue
        let out: JSONValue = .object([
            "schema": .string("nativeagent.memory-embedding-epoch.v1"),
            "action": .string(action),
            "dataRoot": .string(dataRoot.path),
            "protected": .bool(state.protected),
            "activeEpoch": state.activeEpoch.map(JSONValue.string) ?? .null,
            "providerEpoch": providerEpoch.map(JSONValue.string) ?? .null,
            "providerMatchesActive": .bool(
                state.activeEpoch != nil && state.activeEpoch == providerEpoch
            ),
            "previousEpoch": state.previousEpoch.map(JSONValue.string) ?? .null,
            "rollbackAvailable": .bool(state.rollbackAvailable),
            "activatedAt": state.activatedAt.map(JSONValue.string) ?? .null,
            "activation": activation.map { report in
                .object([
                    "memories": .int(Int64(report.memories)),
                    "proposals": .int(Int64(report.proposals)),
                    "tombstones": .int(Int64(report.tombstones)),
                    "total": .int(Int64(report.total)),
                ])
            } ?? .null,
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runMemoryHygiene(dataRootPath: String, approveSwap: Bool, maxPasses: Int) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let consolidator = MemoryConsolidator(storage: storage)
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        var passValues: [JSONValue] = []
        var appliedSwap = false

        for pass in 1...maxPasses {
            let outcome = try await consolidator.consolidateGated()
            var passObject: [String: JSONValue] = [
                "pass": .int(Int64(pass)),
            ]
            let stagedApproval: String?
            switch outcome {
            case .alreadyStaged(let approvalId):
                stagedApproval = approvalId
                passObject["outcome"] = .string("already_staged")
                passObject["approval_id"] = .string(approvalId)
            case .noChanges(let plan):
                stagedApproval = nil
                passObject["outcome"] = .string("no_changes")
                passObject["plan"] = consolidationPlanJSON(plan)
            case .refusedRegression(let scores, let plan):
                stagedApproval = nil
                passObject["outcome"] = .string("refused_regression")
                passObject["plan"] = consolidationPlanJSON(plan)
                passObject["probe_live"] = .string(scores.live.summary)
                passObject["probe_candidate"] = .string(scores.candidate.summary)
                passObject["lost_probe_ids"] = .array(scores.lostProbeIds.map { .string($0) })
            case .staged(let approvalId, let scores, let diff, let plan):
                stagedApproval = approvalId
                passObject["outcome"] = .string("staged")
                passObject["approval_id"] = .string(approvalId)
                passObject["probe_live"] = .string(scores.live.summary)
                passObject["probe_candidate"] = .string(scores.candidate.summary)
                passObject["diff"] = .string(diff.summary)
                passObject["plan"] = consolidationPlanJSON(plan)
            }

            if approveSwap, let approvalId = stagedApproval {
                do {
                    _ = try await inbox.resolve(
                        approvalId,
                        decision: .approved,
                        decidedBy: "chat-drive-memory-hygiene"
                    )
                    passObject["approval_resolution"] = .string("approved")
                } catch let error as ApprovalInboxError {
                    switch error {
                    case .alreadyResolved:
                        passObject["approval_resolution"] = .string("already_resolved")
                    default:
                        throw error
                    }
                }
                let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: dataRoot)
                passObject["reconcile"] = .array(outcomes.map { .string(describeSwapOutcome($0)) })
                if outcomes.contains(where: isAppliedSwapOutcome) {
                    appliedSwap = true
                }
                passValues.append(.object(passObject))
                if outcomes.contains(where: isStaleSwapOutcome) {
                    continue
                }
                break
            } else {
                passValues.append(.object(passObject))
                break
            }
        }

        let activeFragments = try await storage.listMemories(persona: nil, status: "active", limit: nil)
            .filter { memory in
                memory.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "user likes app interfaces to feel"
            }
        let kgSweep: JSONValue? = approveSwap && !appliedSwap
            ? try await runExplicitKnowledgeGraphSweep(dataRoot: dataRoot)
            : nil
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "approveSwap": .bool(approveSwap),
            "passes": .array(passValues),
            "kgSweep": kgSweep ?? .null,
            "activeKnownBadFragments": .int(Int64(activeFragments.count)),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func consolidationPlanJSON(_ plan: ConsolidationReport) -> JSONValue {
        .object([
            "processed": .int(Int64(plan.processed)),
            "autoAccepted": .int(Int64(plan.autoAccepted)),
            "duplicatesMerged": .int(Int64(plan.duplicatesMerged)),
            "pendingForReview": .int(Int64(plan.pendingForReview)),
            "staleArchived": .int(Int64(plan.staleArchived)),
            "errors": .array(plan.errors.map { .string($0) }),
        ])
    }

    static func describeSwapOutcome(_ outcome: MemoryConsolidationSwapOutcome) -> String {
        switch outcome {
        case .applied(let runId, let backupPath):
            return "applied run=\(runId) backup=\(backupPath)"
        case .alreadyApplied(let runId):
            return "already_applied run=\(runId)"
        case .staleRefused(let runId):
            return "stale_refused run=\(runId)"
        case .cleanedUpDenied(let runId):
            return "cleaned_up_denied run=\(runId)"
        case .pendingApproval(let runId):
            return "pending_approval run=\(runId)"
        case .failed(let runId, let reason):
            return "failed run=\(runId) reason=\(reason)"
        }
    }

    static func isStaleSwapOutcome(_ outcome: MemoryConsolidationSwapOutcome) -> Bool {
        if case .staleRefused = outcome { return true }
        return false
    }

    static func isAppliedSwapOutcome(_ outcome: MemoryConsolidationSwapOutcome) -> Bool {
        if case .applied = outcome { return true }
        if case .alreadyApplied = outcome { return true }
        return false
    }

    static func runExplicitKnowledgeGraphSweep(dataRoot: URL) async throws -> JSONValue {
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let memories = try await storage.listMemories(persona: nil, status: nil, limit: nil)
        let facts = memories.map { memory in
            KnowledgeGraphMemoryFact(
                id: memory.id,
                content: memory.content,
                source: memory.source,
                status: memory.status,
                createdAt: memory.createdAt,
                updatedAt: memory.updatedAt,
                metadata: memory.metadata
            )
        }
        let sqlitePath = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
        let report = try await indexer.collectGarbage(
            liveFacts: facts,
            apply: true,
            approvedOverThreshold: true
        )
        return .object([
            "applied": .bool(report.applied),
            "requiresApproval": .bool(report.requiresApproval),
            "candidates": .int(Int64(report.candidates.count)),
            "entitiesDeleted": .int(Int64(report.entitiesDeleted)),
            "edgesDeleted": .int(Int64(report.edgesDeleted)),
            "staleIndexRowsDeleted": .int(Int64(report.staleIndexRowsDeleted)),
            "legacyUntrackedEntities": .int(Int64(report.legacyUntrackedEntities)),
        ])
    }
}
