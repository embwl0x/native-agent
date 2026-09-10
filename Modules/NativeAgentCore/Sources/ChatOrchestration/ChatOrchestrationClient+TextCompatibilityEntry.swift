import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension SwiftNativeChatOrchestrationClient {
    /// One per-turn snapshot of the three requirements for the text-compatible
    /// append-only messages transport. This deliberately evaluates all three
    /// checks (rather than returning at the first failure) so diagnostics can
    /// distinguish an intentional rollback from a missing capability and a
    /// credential-store failure. The OAuth file is reread for every new turn;
    /// no failed result is cached across a credential repair or reload.
    struct AppendOnlyMessagesEligibility: Sendable {
        let grownPromptCompatibilityEnabled: Bool
        let messagesStreamingSupported: Bool
        let usableAnthropicOAuthCredentials: Bool

        var isEligible: Bool {
            !grownPromptCompatibilityEnabled
                && messagesStreamingSupported
                && usableAnthropicOAuthCredentials
        }

        var blockers: [String] {
            var result: [String] = []
            if grownPromptCompatibilityEnabled { result.append("grown_prompt_compat") }
            if !messagesStreamingSupported { result.append("messages_streaming_unsupported") }
            if !usableAnthropicOAuthCredentials { result.append("anthropic_oauth_unavailable") }
            return result
        }
    }

    nonisolated static func appendOnlyMessagesEligibility(
        streamingLLM: any StreamingLLMClient,
        dataRoot: URL
    ) -> AppendOnlyMessagesEligibility {
        let authFile = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
        return AppendOnlyMessagesEligibility(
            grownPromptCompatibilityEnabled: AnthropicOAuthDirectAdapter.GrownPromptCompat.effective,
            messagesStreamingSupported: streamingLLM is any MessagesStreamingLLMClient,
            usableAnthropicOAuthCredentials: AnthropicOAuthDirectAdapter.hasUsableOAuthCredentials(at: authFile)
        )
    }

    /// Emits only booleans and stable reason codes: enough to account for a
    /// transport downgrade without disclosing credential contents, file paths,
    /// prompt text, or provider response data.
    ///
    /// The native-tools fields are what make a Claude turn's transport
    /// PROVABLE from the trace alone. Since the api-key opt-in (item 34) the
    /// same `claude-*` model reaches the provider two different ways, and the
    /// difference is invisible in the reply: `toolProtocol` says whether the
    /// turn shipped a `tools` array or asked the model for `<tool_use>` markers
    /// in prose, and `nativeToolProviderId` / `nativeToolLaneResolvedFrom` say
    /// which id decided it and which step of the ladder answered.
    nonisolated static func emitAppendOnlyMessagesEligibilityTrace(
        _ eligibility: AppendOnlyMessagesEligibility,
        effectiveTransport: String,
        nativeLane: NativeToolLaneDecision,
        nativeToolsEngaged: Bool,
        sessionId: String,
        surface: String
    ) {
        TurnTraceBus.fireFromContext(
            kind: "text_compat.append_only_messages_eligibility",
            sessionId: sessionId,
            surface: surface,
            payload: .object([
                "schema": .string("text_compat.append_only_messages_eligibility.v1"),
                "eligible": .bool(eligibility.isEligible),
                "effectiveTransport": .string(effectiveTransport),
                "grownPromptCompatibilityEnabled": .bool(eligibility.grownPromptCompatibilityEnabled),
                "messagesStreamingSupported": .bool(eligibility.messagesStreamingSupported),
                "usableAnthropicOAuthCredentials": .bool(eligibility.usableAnthropicOAuthCredentials),
                "blockers": .array(eligibility.blockers.map(JSONValue.string)),
                "nativeToolLaneAvailable": .bool(nativeLane.engaged),
                "nativeToolLaneEngaged": .bool(nativeToolsEngaged),
                "nativeToolProviderId": nativeLane.providerId.map(JSONValue.string) ?? .null,
                "nativeToolLaneResolvedFrom": .string(nativeLane.resolvedFrom),
                "toolProtocol": .string(nativeToolsEngaged ? "provider_native_tools" : "text_markers"),
            ])
        )
    }

    /// Why this turn is (or isn't) on the provider-native tools lane. Carried
    /// as a value rather than a bare Bool so the eligibility trace can name the
    /// PROVIDER and the RESOLUTION STEP that decided it: "this Claude turn
    /// parsed markers out of prose" and "this Claude turn shipped a tools
    /// array" are materially different wires, and after the api-key opt-in they
    /// are both reachable for `claude-*` models depending only on which
    /// provider id is bound.
    struct NativeToolLaneDecision: Sendable {
        let engaged: Bool
        /// The id the decision was made ON (nil when nothing resolved).
        let providerId: String?
        /// Which step in the ladder answered: "call_context", "model_backstop",
        /// "surface_active", or "unresolved".
        let resolvedFrom: String
    }

    /// Does THIS turn ride the provider-native tools lane?
    ///
    /// Resolution order mirrors the existing async text-compat gate: an already
    /// admitted provider id wins (it is the one the router actually bound),
    /// then the requested model's implied provider, then the surface's active
    /// provider. Every branch funnels through the single NativeToolCapability
    /// predicate, so the admitted set is enforced in exactly one place and the
    /// Claude OAUTH-direct adapter can never be reached by this lane — a
    /// `claude-*` model id alone is NOT enough (see
    /// modelImpliesNativeToolProvider), because the same id is served by both
    /// Claude transports and only the resolved provider id tells them apart.
    func usesNativeToolLane(model: String, surface: String) async -> NativeToolLaneDecision {
        if let admitted = LLMCallContext.providerId {
            return NativeToolLaneDecision(
                engaged: NativeToolCapability.providerSupportsNativeTools(admitted),
                providerId: admitted,
                resolvedFrom: "call_context"
            )
        }
        if NativeToolCapability.modelImpliesNativeToolProvider(model) {
            return NativeToolLaneDecision(
                engaged: true, providerId: "kimi-code", resolvedFrom: "model_backstop")
        }
        let active = try? await engine.checkedActiveProviderID(for: surface)
        let resolved = active ?? nil
        return NativeToolLaneDecision(
            engaged: NativeToolCapability.providerSupportsNativeTools(resolved),
            providerId: resolved,
            resolvedFrom: resolved == nil ? "unresolved" : "surface_active"
        )
    }

    /// Append user-role text to the native conversation without producing a
    /// shape the wire rejects — two consecutive user turns, or (since v2Prefix)
    /// a user turn directly after the trailing volatile system message. Both
    /// rules have one owner; see `ConversationPrefixSeeding.appendUserText`.
    nonisolated static func appendNativeUserText(
        _ text: String,
        to conversation: inout [LLMMessage]
    ) {
        ConversationPrefixSeeding.appendUserText(text, to: &conversation)
    }

    func executeTextStreamingCompatibilityChat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        progress: ChatOrchestrationProgressHandler?
    ) async throws -> StructuredChatExecution {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }
        guard let streamingLLM else {
            throw ChatOrchestrationError.underlying("no streaming LLM client wired")
        }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        // Suppressed-append turns adopt the enqueue-time runId (see
        // ChatPersistenceContext.pinnedTurnRunID) — same rule as the
        // structured path, so both routes exclude the pre-appended row.
        let runId = (suppressUserAppend ? ChatPersistenceContext.pinnedTurnRunID : nil)
            ?? UUID().uuidString

        // Turn Inspector W1: bind the per-turn trace id ONCE around the whole
        // tool loop (runTextStreamingCompatibility calls streamTurn once per
        // iteration; streamTurn inherits this id rather than minting a fresh
        // one each iteration, so all iterations of this turn share one story).
        // MEMORY-SAFETY (2026-07-04): bind the task-local INSIDE the Task with
        // the async withValue overload, never a sync withValue wrapping the
        // Task creation — see the matching note in StreamFacade.chatStream. The
        // old `withValue(turnId) { Task { … } }` shape freed task-local storage
        // on the parent while the child still referenced it → the
        // swift_task_dealloc_specific crash on first chat (G4-5).
        let turnId = TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
        let producerControl = ChatStreamProducerControl()
        let stream = AsyncThrowingStream<TurnStreamEvent, Error> { continuation in
            let task = Task { [self] in
                defer { producerControl.resolve() }
                await TurnTraceContext.$bus.withValue(turnTraceBus) {
                await TurnTraceContext.$turnId.withValue(turnId) {
                    await runTextStreamingCompatibility(
                        message: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        fileAccess: fileAccess,
                        attachments: attachments,
                        persona: persona,
                        surface: surface,
                        suppressUserAppend: suppressUserAppend,
                        streamingLLM: streamingLLM,
                        emitTextDeltas: false,
                        continuation: continuation
                    )
                }
                }
            }
            producerControl.install(task)
            continuation.onTermination = { termination in
                if case .cancelled = termination { producerControl.cancel() }
            }
        }

        var finalResult: TurnEngineResult?
        var lastError: String?
        var iterationError: Error?
        do {
            for try await event in stream {
                await observeCognitiveProgressEvent(
                    sessionId: resolvedSession,
                    runId: runId,
                    surface: surface,
                    event: event,
                    toolResultAlreadyPersisted: true
                )
                await progress?(event)
                switch event {
                case .final(let result):
                    finalResult = result
                case .error(let message):
                    lastError = message
                case .delta, .toolUse, .toolResult, .notice:
                    // .notice already forwarded via progress?(event) above.
                    break
                }
            }
        } catch {
            iterationError = error
            producerControl.cancel()
        }

        // The producer owns partial/cancellation persistence and may publish a
        // terminal event before that write settles. Joining is intentionally
        // cancellation-insensitive so regenerate cannot drain a replacement
        // turn ahead of the old producer's canonical receipt.
        if Task.isCancelled { producerControl.cancel() }
        await producerControl.wait()

        if Task.isCancelled || iterationError is CancellationError
            || Self.isCancellationStreamError(lastError) {
            throw CancellationError()
        }
        if let iterationError {
            let message = (iterationError as? LocalizedError)?.errorDescription
                ?? String(describing: iterationError)
            throw ChatOrchestrationError.underlying(message)
        }
        // The producer can report a persistence failure after generating its
        // final reply. A generated answer is not a successful saved turn when
        // that terminal write (including an explicit regenerate) was refused.
        if let lastError {
            throw ChatOrchestrationError.underlying(lastError)
        }

        guard let finalResult else {
            throw ChatOrchestrationError.underlying(
                lastError ?? "anthropic text compatibility stream ended without final reply"
            )
        }

        let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
            from: finalResult.toolDispatches,
            dataRoot: dataRoot
        )
        let response = ChatResponse(
            runId: runId,
            model: finalResult.modelUsed,
            requestedModel: model.isEmpty ? nil : model,
            reasoningEffort: finalResult.terminalObservation?.reasoningEffort
                ?? (reasoningEffort.isEmpty ? nil : reasoningEffort),
            output: finalResult.reply,
            sessionId: resolvedSession,
            personaFingerprint: Self.personaFingerprint(dataRoot: dataRoot),
            contextFingerprint: Self.contextFingerprint(recalledIds: finalResult.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: finalResult.providerCallCount
        )
        return StructuredChatExecution(response: response, turn: finalResult)
    }

    private nonisolated static func isCancellationStreamError(_ error: String?) -> Bool {
        guard let normalized = error?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return normalized == "cancelled"
            || normalized == "canceled"
            || normalized == "cancellationerror()"
    }

    nonisolated static func shouldUseAnthropicTextStreamingCompatibility(
        model: String,
        surface: String
    ) -> Bool {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isAnthropicTextCompatibilitySurface(normalizedSurface) else { return false }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedModel.isEmpty else { return false }
        if normalizedModel.hasPrefix("anthropic/") { return true }
        if normalizedModel.hasPrefix("claude-") { return true }
        // Kimi Code subscription models speak the Anthropic wire protocol and
        // MUST ride this text-compat path: the API-key AnthropicAdapter never
        // sends native tools[], so text-compat's system-block tool contract is
        // what makes them tool-capable (gpt-5.5 review HIGH, 2026-07-18).
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(normalizedModel) { return true }
        return normalizedModel.hasPrefix("opus")
            || normalizedModel.hasPrefix("sonnet")
            || normalizedModel.hasPrefix("haiku")
    }

    func shouldUseAnthropicTextStreamingCompatibility(
        model: String,
        surface: String
    ) async throws -> Bool {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isAnthropicTextCompatibilitySurface(normalizedSurface) else { return false }
        if let admittedProvider = LLMCallContext.providerId {
            return Self.isAnthropicProviderId(admittedProvider)
        }
        if Self.shouldUseAnthropicTextStreamingCompatibility(model: model, surface: surface) {
            return true
        }
        guard let activeProvider = try await engine.checkedActiveProviderID(for: normalizedSurface) else {
            return false
        }
        return Self.isAnthropicProviderId(activeProvider)
    }

    private nonisolated static func isAnthropicTextCompatibilitySurface(_ surface: String) -> Bool {
        let compatibleSurfaces: Set<String> = [
            "chat", "telegram", "slack", "ios", "icloud", "iphone", "ipad", "mobile",
            // A bot's turn is an ordinary chat turn on its own session (2026-09-09).
            "bot",
        ]
        return compatibleSurfaces.contains(surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private nonisolated static func isAnthropicProviderId(_ providerId: String) -> Bool {
        let normalized = providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        // kimi-code is an Anthropic-WIRE provider (Kimi Code subscription
        // endpoint) — its turns take the same text-compat contract.
        return normalized == "anthropic" || normalized.hasPrefix("anthropic_")
            || normalized == "kimi_code"
    }
}
