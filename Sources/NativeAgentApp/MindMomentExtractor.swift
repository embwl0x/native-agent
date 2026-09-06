import ChatOrchestration
import Foundation
import MemoryV2
import ProviderRouting

/// The moments lane on the agent's real mind.
///
/// User, 2026-09-05: "get the memory extractor on her real mind." The on-device
/// model (AppleFoundationModelsMomentExtractor) was staging the person's own
/// sentences with an "I" in front as moments. This asks the same question of
/// the model the agent actually thinks with, resolved the way the kind
/// backfill resolves it: on the "Memory" row of Providers, so a pin there wins
/// (it can be pointed at something cheap), a provider assigned there without a
/// pin decides the model, and a blank row still follows the chat voice.
/// The prompt, the parse and every gate after it are unchanged; only the
/// reader changed. A failed call falls back to the on-device pass so a
/// provider blip never means a moment lane that stages nothing.
struct MindMomentExtractor: MomentExtracting {
    private let fallback = AppleFoundationModelsMomentExtractor()

    func extractMoment(userMessage: String, assistantMessage: String) async -> MomentCandidate? {
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty else { return nil }

        let router = SwiftNativeProviderRouting()
        // User, 2026-09-06: this used to demand a MODEL PIN on the Memory row
        // and otherwise switch both model and surface to Chat — so assigning a
        // provider to Memory (which is all onboarding writes: an active
        // provider, no pin) did nothing at all. The Memory row now takes its
        // own surface whenever it says anything (a pin OR an assigned
        // provider), and `modelStringForSurface` honours the pin first and
        // otherwise adapts the seed to that row's provider. A BLANK row still
        // routes on "chat": on "memory" it would carry no active-provider
        // entry, and dispatch would infer the transport from the model prefix
        // — sending Memory to ChatGPT OAuth while chat runs on the Codex CLI
        // or the OpenAI API. Blank follows chat exactly, model and provider.
        let surface = await router.surfaceHasOwnRouting("memory") ? "memory" : "chat"
        let model = await router.modelStringForSurface(surface)
        let prompt = MemoryMoments.extractionPrompt(userMessage: user, assistantMessage: assistant)
        // The shared client prepends the compiled persona unless the system
        // text carries this heading; the extractor's own prompt is the whole
        // instruction, so it goes verbatim (reviewer, 2026-09-05).
        let system = "# Background Personality Context\nYou describe what happened between two people. Reply with JSON only: [] or one object."
        // A hard twenty seconds: the gate returns the moment the ceiling passes
        // even if the provider ignores cancellation, and a Stop on the turn
        // returns nothing rather than running the fallback (Codex review
        // 2026-09-05).
        let raw = await IntraTurnContextCompaction.withDeadline(seconds: 20) {
            try await BackgroundLoopsAssembly.makeSharedLLMClient().complete(
                prompt: prompt, system: system, model: model, surface: surface
            )
        }
        if Task.isCancelled { return nil }
        if let raw {
            // A reply that parses is the answer, including "no moment" (nil);
            // only a malformed reply or a timeout reaches the fallback.
            do { return try MemoryMoments.parse(raw) } catch {}
        }
        return await fallback.extractMoment(userMessage: user, assistantMessage: assistant)
    }

}
