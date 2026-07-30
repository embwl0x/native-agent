import Foundation
import PersistenceCore
import NativeAgentCore

// MARK: - Fresh-install provider readiness (G4-6 honest chat, 2026-07-04)
//
// A stranger who skips onboarding's provider-connect step (or whose ChatGPT
// sign-in silently failed because the external Codex CLI is absent) used to
// send a first message and get a bare "No reply came back" — or, before the
// task-local crash fix, an outright crash. This surfaces an HONEST, actionable
// prompt instead: "connect a provider."
//
// Design constraint (must never false-block User's working machine): the guard
// fires ONLY on the true fresh-install signature — NO provider has any
// credentials on disk AND the Codex CLI isn't available. Any single connected
// provider (or a resolvable codex binary) means the machine is set up and the
// guard stays silent, so an established install is never blocked.

@MainActor
extension AppModel {
    /// Guidance text to show in chat when no AI provider is usable at all;
    /// `nil` when at least one provider looks connected (the common case).
    func missingProviderChatGuidance() -> String? {
        guard !hasAnyUsableProvider() else { return nil }
        return """
        No AI provider is connected yet, so I can't reply.

        Open Settings → Providers to connect one. The quickest is pasting an \
        Anthropic setup-token (no API key or command-line tools needed) — \
        you can get one at console.anthropic.com.
        """
    }

    /// True when at least one AI provider looks usable. Deliberately OVER-
    /// inclusive: it must never return false on an established machine, so it
    /// checks every credential source the runtime can actually consume — a
    /// false positive (returning true when nothing works) merely lets the send
    /// fail with its own error, but a false negative would wrongly block a
    /// working setup. gpt-5.5 review (2026-07-04) caught that the first cut
    /// missed codex_home OAuth tokens, env API keys, and Homebrew codex behind
    /// a Finder-launched app's minimal PATH — all handled here now.
    func hasAnyUsableProvider() -> Bool {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let fm = FileManager.default

        // A file with real content (not empty / "{}" / a lock stub).
        func hasContent(_ url: URL) -> Bool {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { return false }
            return size > 2
        }

        // 1. Direct provider credential files under providers/.
        let providers = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let credentialFiles = [
            "anthropic_oauth_direct.json",
            "anthropic.json",
            "openai_oauth_direct.json",
            "openai.json",
            "openrouter.json",
            "xai_oauth_direct.json",
        ]
        if credentialFiles.contains(where: { hasContent(providers.appendingPathComponent($0)) }) {
            return true
        }

        // 2. Codex OAuth tokens (ChatGPT sign-in) live in CODEX_HOME/auth.json,
        //    not under providers/. Check the app's codex_home and the global
        //    ~/.codex default.
        let home = fm.homeDirectoryForCurrentUser
        let codexAuthCandidates = [
            dataRoot.appendingPathComponent("codex_home", isDirectory: true).appendingPathComponent("auth.json"),
            home.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("auth.json"),
        ]
        if codexAuthCandidates.contains(where: hasContent) { return true }

        // 3. Environment API keys the credential resolver honors.
        let env = ProcessInfo.processInfo.environment
        let keyVars = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "XAI_API_KEY"]
        if keyVars.contains(where: { env[$0]?.isEmpty == false }) { return true }

        // 4. Codex CLI resolvable via the SAME augmented PATH the login uses
        //    (so a Homebrew install isn't missed behind a Finder-launched app's
        //    minimal PATH). Presence is enough to avoid a false block.
        if SwiftCodexDeviceLoginManager.codexIsResolvable() { return true }

        return false
    }
}
