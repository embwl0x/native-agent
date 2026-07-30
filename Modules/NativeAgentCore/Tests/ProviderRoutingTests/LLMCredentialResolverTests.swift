import Foundation
import Testing
@testable import ProviderRouting

// MARK: - Test scaffolding

/// Per-test isolated temp cwd + clean env. All four sources the resolver looks
/// at (env vars + two files under data/) are scoped here so tests can't bleed
/// into each other.
private final class TempCWD {
    let url: URL

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmcredres-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("data/providers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("data/codex_home", isDirectory: true),
            withIntermediateDirectories: true
        )
        self.url = base
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func writeProvider(_ name: String, _ json: String) {
        let p = url.appendingPathComponent("data/providers/\(name)")
        try? json.data(using: .utf8)?.write(to: p)
    }

    func writeCodexAuth(_ json: String) {
        let p = url.appendingPathComponent("data/codex_home/auth.json")
        try? json.data(using: .utf8)?.write(to: p)
    }
}

private func clearEnv() {
    unsetenv("OPENAI_API_KEY")
    unsetenv("ANTHROPIC_API_KEY")
}

// Serialized because env-var tests still mutate process-global state. CWD
// resolution itself is exercised through LLMCredentialResolver's explicit
// currentDirectory seam so the full package's parallel run cannot chdir-race
// this suite.
@Suite("LLMCredentialResolver", .serialized)
struct LLMCredentialResolverTests {

    @Test("env var wins over providers/<file>.json and codex_home/auth.json")
    func envWinsOverFiles() {
        clearEnv()
        let tmp = TempCWD()
        _ = tmp
        setenv("OPENAI_API_KEY", "env-key", 1)
        defer { unsetenv("OPENAI_API_KEY") }
        tmp.writeProvider("openai.json", #"{"api_key":"file-key"}"#)
        tmp.writeCodexAuth(#"{"OPENAI_API_KEY":"oauth-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == "env-key")
    }

    @Test("providers/<file>.json is used when env var is missing")
    func providersFallback() {
        clearEnv()
        let tmp = TempCWD()
        tmp.writeProvider("openai.json", #"{"api_key":"file-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == "file-key")
    }

    @Test("codex_home/auth.json is used when env + providers are missing")
    func codexHomeFallback() {
        clearEnv()
        let tmp = TempCWD()
        tmp.writeCodexAuth(#"{"OPENAI_API_KEY":"oauth-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == "oauth-key")
    }

    @Test("returns nil when all three sources are absent")
    func allAbsent() {
        clearEnv()
        let tmp = TempCWD()
        _ = tmp

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == nil)
    }

    @Test("empty/whitespace api_key in providers/openai.json falls through to codex_home")
    func providerEmptyFallsThrough() {
        clearEnv()
        let tmp = TempCWD()
        tmp.writeProvider("openai.json", #"{"api_key":"   "}"#)
        tmp.writeCodexAuth(#"{"OPENAI_API_KEY":"oauth-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == "oauth-key")
    }

    @Test("malformed providers/openai.json falls through to codex_home without crashing")
    func providerMalformedFallsThrough() {
        clearEnv()
        let tmp = TempCWD()
        tmp.writeProvider("openai.json", "{ this is not json")
        tmp.writeCodexAuth(#"{"OPENAI_API_KEY":"oauth-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == "oauth-key")
    }

    @Test("null OPENAI_API_KEY in codex_home returns nil (OAuth-only state)")
    func codexHomeNullKey() {
        clearEnv()
        let tmp = TempCWD()
        tmp.writeCodexAuth(#"{"OPENAI_API_KEY":null,"tokens":{"access_token":"abc"}}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == nil)
    }

    @Test("env var with only whitespace falls through to providers/<file>.json")
    func envWhitespaceFallsThrough() {
        clearEnv()
        let tmp = TempCWD()
        setenv("OPENAI_API_KEY", "   ", 1)
        defer { unsetenv("OPENAI_API_KEY") }
        tmp.writeProvider("openai.json", #"{"api_key":"file-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", currentDirectory: tmp.url)
        #expect(got == "file-key")
    }

    @Test("anthropic provider does NOT pick up codex_home's OPENAI_API_KEY")
    func anthropicIgnoresCodexHome() {
        clearEnv()
        let tmp = TempCWD()
        tmp.writeCodexAuth(#"{"OPENAI_API_KEY":"oauth-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "ANTHROPIC_API_KEY", providerConfigFile: "anthropic.json", currentDirectory: tmp.url)
        #expect(got == nil)
    }

    // MARK: - dataRoot: overload (REPO_PATH parity for installed builds, W08)

    /// Builds an isolated data root laid out the way the daemon resolves it:
    /// `<root>/providers/...` and `<root>/codex_home/auth.json` — NO `data`
    /// segment (the data root ALREADY includes it). Independent of process CWD.
    private final class TempDataRoot {
        let url: URL
        init() {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("llmcredres-droot-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: base.appendingPathComponent("providers", isDirectory: true),
                withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: base.appendingPathComponent("codex_home", isDirectory: true),
                withIntermediateDirectories: true)
            self.url = base
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func writeProvider(_ name: String, _ json: String) {
            try? json.data(using: .utf8)?.write(
                to: url.appendingPathComponent("providers/\(name)"))
        }
        func writeCodexAuth(_ json: String) {
            try? json.data(using: .utf8)?.write(
                to: url.appendingPathComponent("codex_home/auth.json"))
        }
    }

    @Test("dataRoot overload reads <dataRoot>/providers/<file>.json (no data segment)")
    func dataRootProvidersResolution() {
        clearEnv()
        let root = TempDataRoot()
        root.writeProvider("openai.json", #"{"api_key":"droot-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", dataRoot: root.url)
        #expect(got == "droot-key")
    }

    @Test("dataRoot overload reads <dataRoot>/codex_home/auth.json when providers absent")
    func dataRootCodexHomeResolution() {
        clearEnv()
        let root = TempDataRoot()
        root.writeCodexAuth(#"{"OPENAI_API_KEY":"droot-oauth"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", dataRoot: root.url)
        #expect(got == "droot-oauth")
    }

    @Test("dataRoot overload env var still wins over the data-root files")
    func dataRootEnvWins() {
        clearEnv()
        let root = TempDataRoot()
        setenv("OPENAI_API_KEY", "env-key", 1)
        defer { unsetenv("OPENAI_API_KEY") }
        root.writeProvider("openai.json", #"{"api_key":"droot-key"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", dataRoot: root.url)
        #expect(got == "env-key")
    }

    @Test("hermetic dataRoot resolution can exclude process environment credentials")
    func hermeticDataRootExcludesEnvironment() {
        clearEnv()
        let root = TempDataRoot()
        setenv("OPENAI_API_KEY", "live-process-key", 1)
        defer { unsetenv("OPENAI_API_KEY") }

        let absent = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY",
            providerConfigFile: "openai.json",
            dataRoot: root.url,
            includeEnvironment: false
        )
        #expect(absent == nil)

        root.writeProvider("openai.json", #"{"api_key":"root-owned-key"}"#)
        let rooted = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY",
            providerConfigFile: "openai.json",
            dataRoot: root.url,
            includeEnvironment: false
        )
        #expect(rooted == "root-owned-key")
    }

    @Test("dataRoot overload IGNORES a CWD-relative key (the installed-build bug)")
    func dataRootIgnoresCWD() {
        clearEnv()
        // The legacy CWD path would see this trap.
        let cwdTrap = TempCWD()
        cwdTrap.writeProvider("openai.json", #"{"api_key":"cwd-trap"}"#)
        #expect(LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY",
            providerConfigFile: "openai.json",
            currentDirectory: cwdTrap.url
        ) == "cwd-trap")

        // The dataRoot overload must ignore that legacy trap.
        let root = TempDataRoot()

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json", dataRoot: root.url)
        #expect(got == nil) // NOT "cwd-trap"
    }

    @Test("dataRoot overload: anthropic does NOT read codex_home")
    func dataRootAnthropicIgnoresCodexHome() {
        clearEnv()
        let root = TempDataRoot()
        root.writeCodexAuth(#"{"OPENAI_API_KEY":"droot-oauth"}"#)

        let got = LLMCredentialResolver.resolveAPIKey(
            envVar: "ANTHROPIC_API_KEY", providerConfigFile: "anthropic.json", dataRoot: root.url)
        #expect(got == nil)
    }
}
