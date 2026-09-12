import ChatOrchestration
import Foundation
import MemoryV2
import ProviderRouting

/// The fact lane on the agent's real mind.
///
/// User, 2026-09-11: the proposals waiting on the Memories page were junk — "user
/// wants an ant", a bot's brief re-read as his values, verbatim quotes as
/// headlines — because a regex template extractor and a 250ms on-device pass were
/// guessing from one turn with nothing else in view. This asks the model the
/// agent actually thinks with, once, with the memories it already keeps in the
/// prompt, and it answers with add/update/skip.
///
/// Model and surface are resolved EXACTLY as `MindMomentExtractor` resolves them:
/// on the "Memory" row of Providers, so a pin there wins, a provider assigned
/// there without a pin decides the model, and a blank row follows the chat voice.
/// There is deliberately no fallback: a failed call means no facts this turn,
/// which is the safe direction.
struct MindMemoryManager: MemoryManaging {
    func review(_ request: MemoryManagerRequest) async -> [MemoryManagerDecision]? {
        let user = request.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = request.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty else { return [] }

        let router = SwiftNativeProviderRouting()
        let surface = await router.surfaceHasOwnRouting("memory") ? "memory" : "chat"
        let model = await router.modelStringForSurface(surface)
        let prompt = MemoryManagerLane.prompt(request)
        // The shared client prepends the compiled persona unless the system text
        // carries this heading; this pass's own prompt is the whole instruction,
        // so it goes verbatim (same contract as the moments lane).
        let system = "# Background Personality Context\nYou maintain one person's memory. Reply with JSON only: an array, possibly empty."
        // A hard twenty seconds, matching the moments lane: the deadline returns
        // the moment the ceiling passes even if the provider ignores
        // cancellation, and a Stop on the turn returns nothing.
        // This runs INSIDE the parent chat turn's task-local scope, so without
        // shedding the turn's prefix sink this bounded little request's `llm.call`
        // row describes the giant chat prompt — 42 history messages, the chat
        // head previews, the tools fingerprint — next to its own honest 475 input
        // tokens (Astra audit 2026-09-11 finding 7). The parent `turnId` still
        // rides along for correlation; only the borrowed shape goes.
        let raw = await ConversationPrefixTelemetry.withUnmeasuredRequestShape {
            await IntraTurnContextCompaction.withDeadline(seconds: 20) {
                try await BackgroundLoopsAssembly.makeSharedLLMClient().complete(
                    prompt: prompt, system: system, model: model, surface: surface
                )
            }
        }
        if Task.isCancelled { return nil }
        guard let raw else { return nil }
        return try? MemoryManagerLane.parse(raw)
    }
}
