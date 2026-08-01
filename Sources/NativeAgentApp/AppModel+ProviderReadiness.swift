import Foundation
import PersistenceCore
import NativeAgentCore
import ProviderRouting

// MARK: - Fresh-install provider readiness (G4-6 honest chat, 2026-07-04)
//
// A stranger who skips onboarding's provider-connect step (or whose ChatGPT
// sign-in silently failed because the external Codex CLI is absent) used to
// send a first message and get a bare "No reply came back" — or, before the
// task-local crash fix, an outright crash. This surfaces an HONEST, actionable
// prompt instead: "connect a provider."
//
// Design constraint (must never false-block User's working machine): the guard
// fires ONLY on the true fresh-install signature — NO provider has any usable
// credentials on disk. Any single connected provider means the machine is set
// up and the guard stays silent, so an established install is never blocked.
//
// FIRSTRUN-1 (2026-08-01): a resolvable `codex` BINARY no longer counts on its
// own. A public user who happens to have the Codex CLI installed but has never
// signed in was silently waved past provider setup and then watched their first
// chat fail raw. Codex now counts only when a real auth token is on disk, using
// the same signal the OpenAI OAuth-direct adapter consumes at send time
// (`OpenAIOAuthDirectAdapter.authPathCandidates` + `hasUsableTokens`).

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
    /// inclusive on the credential SOURCES it accepts: it must never return
    /// false on an established machine, so it checks every credential source
    /// the runtime can actually consume — a false positive (returning true when
    /// nothing works) merely lets the send fail with its own error, but a false
    /// negative would wrongly block a working setup. gpt-5.5 review (2026-07-04)
    /// caught that the first cut missed codex_home OAuth tokens, env API keys,
    /// and Homebrew codex behind a Finder-launched app's minimal PATH.
    ///
    /// It is NOT over-inclusive about what counts as a credential: every branch
    /// requires an actual token/key, never mere tool presence (FIRSTRUN-1).
    func hasAnyUsableProvider() -> Bool {
        AppModel.hasAnyUsableProvider(dataRoot: PersistenceCore.defaultDataRoot())
    }

    /// Injectable core of `hasAnyUsableProvider()`.
    ///
    /// `codexBinaryIsResolvable` is passed in so tests can prove the FIRSTRUN-1
    /// contract directly: a resolvable binary with no auth on disk must NOT
    /// count as a usable provider.
    ///
    /// Process-global credential sources (`~/.codex/auth.json`, environment API
    /// keys) are consulted only when `dataRoot` is the installed app's real data
    /// root. A test or secondary runtime with an injected root must not inherit
    /// the developer's personal credentials and report a provider its root does
    /// not own — the same hermeticity rule the organism evidence path uses.
    nonisolated static func hasAnyUsableProvider(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexBinaryIsResolvable: () -> Bool = { SwiftCodexDeviceLoginManager.codexIsResolvable() }
    ) -> Bool {
        let fm = FileManager.default

        // A file with real content (not empty / "{}" / a lock stub).
        func hasContent(_ url: URL) -> Bool {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { return false }
            return size > 2
        }

        let isInstalledRoot = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL

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

        // 2. Codex / ChatGPT OAuth tokens live in CODEX_HOME/auth.json, not
        //    under providers/. Use the adapter's own candidate list so this
        //    matches what the send path will actually read, and require a real
        //    token — an auth.json stub with no tokens cannot answer a chat.
        let codexAuthPaths = OpenAIOAuthDirectAdapter.authPathCandidates(
            dataRoot: dataRoot,
            environment: environment,
            allowSharedFallbacks: isInstalledRoot
        )
        if codexAuthPaths.contains(where: { codexAuthFileIsUsable($0) }) { return true }

        guard isInstalledRoot else { return false }

        // 3. The global ~/.codex default, for installs whose CLI was signed in
        //    outside the app. Same token requirement.
        let homeCodexAuth = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        if codexAuthFileIsUsable(homeCodexAuth) { return true }

        // 4. Environment API keys the credential resolver honors.
        let keyVars = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "XAI_API_KEY"]
        if keyVars.contains(where: { environment[$0]?.isEmpty == false }) { return true }

        // FIRSTRUN-1: deliberately NO bare-binary branch here. `codex` being
        // installed says nothing about whether the user can send a message; an
        // unauthenticated CLI produced a raw first-chat failure instead of the
        // setup guidance. The parameter stays so callers/tests can state the
        // binary's presence explicitly and pin that it does not grant access.

        return false
    }

    /// A Codex `auth.json` counts only when it carries something the runtime can
    /// send with: OAuth tokens (`tokens.access_token`) or the API-key form the
    /// CLI writes for key-based sign-in (`OPENAI_API_KEY`).
    nonisolated static func codexAuthFileIsUsable(_ url: URL) -> Bool {
        if OpenAIOAuthDirectAdapter.hasUsableTokens(at: url) { return true }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        for key in ["OPENAI_API_KEY", "openai_api_key", "api_key"] {
            if let value = obj[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }
}
