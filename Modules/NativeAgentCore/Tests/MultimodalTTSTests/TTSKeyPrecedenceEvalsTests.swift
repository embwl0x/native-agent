import Testing
import Foundation
@testable import MultimodalTTS
import ProviderRouting
import PersistenceCore

// ============================================================================
// Coverage-ledger evals — fence core.toolexec (docs/evals/ledger.json).
//
// Row closed here:
//   • env.OPENAI_API_KEY
//
// PRECEDENCE SURPRISE: a stale env var shadows the providers/openai.json key
// the user just set in the UI, so the Settings change appears to do nothing.
// The two existing TTS key tests GUARD on the ambient OPENAI_API_KEY being
// absent — they document that the shadowing exists but never exercise it.
//
// This eval exercises the precedence chain directly, on a UUID-named env var,
// so it proves the shadow without touching the real OPENAI_API_KEY and without
// leaving process-global state behind for the parallel suite.
// ============================================================================

private func evalTTSRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TTSKeyPrecedenceEvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeProviderConfig(_ root: URL, file: String, apiKey: String) throws {
    let dir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"api_key\":\"\(apiKey)\"}".utf8).write(to: dir.appendingPathComponent(file))
}

@Test func evalEnvOpenAIKey_envShadowsTheProvidersFileTheSettingsUIWrites() throws {
    let root = try evalTTSRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // The key the user just set in Settings.
    try writeProviderConfig(root, file: "openai.json", apiKey: "sk-from-settings-ui")

    // A UUID-named var stands in for OPENAI_API_KEY: same code path (the
    // envVar name is a parameter), zero blast radius on the real one or on
    // sibling tests running in parallel.
    let envName = "NATIVE_AGENT_TTS_KEY_EVAL_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

    // (1) NO env var → the providers file wins. This is what the user expects
    //     after saving a key in Settings.
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json", dataRoot: root
        ) == "sk-from-settings-ui"
    )

    // (2) A STALE env var SHADOWS it. The Settings change silently does
    //     nothing, and every request still carries the old key.
    setenv(envName, "sk-stale-from-shell", 1)
    defer { unsetenv(envName) }
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json", dataRoot: root
        ) == "sk-stale-from-shell",
        "KNOWN PRECEDENCE: the environment outranks providers/<file>.json. If this inverted, a shell export would stop working — either way it is a deliberate change, not a silent one."
    )

    // (3) The escape hatch exists and works: `includeEnvironment: false`
    //     resolves the file even with the env var set. Pinned so a caller that
    //     needs the UI value has a proven way to get it.
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json",
            dataRoot: root, includeEnvironment: false
        ) == "sk-from-settings-ui",
        "includeEnvironment:false must bypass the shadow — this is the only seam a UI-first resolve has"
    )

    // (4) An EMPTY or whitespace-only env var must NOT shadow — otherwise
    //     `export OPENAI_API_KEY=` would look like "configured" while
    //     resolving to nothing, and the user would see auth failures with a
    //     key visibly present in Settings.
    setenv(envName, "   ", 1)
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json", dataRoot: root
        ) == "sk-from-settings-ui",
        "a blank env var must fall THROUGH to the file, not shadow it with nothing"
    )

    // (5) Whitespace is TRIMMED off whichever source wins. An untrimmed key
    //     flows into the Authorization header and produces a persistent 401
    //     misreported as not-configured.
    setenv(envName, "  sk-padded\n", 1)
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json", dataRoot: root
        ) == "sk-padded"
    )
    unsetenv(envName)
    try writeProviderConfig(root, file: "openai.json", apiKey: "  sk-padded-file\\n")
    let fromFile = LLMCredentialResolver.resolveAPIKey(
        envVar: envName, providerConfigFile: "openai.json", dataRoot: root
    )
    #expect(fromFile == "sk-padded-file", "the file branch must trim too; got \(fromFile ?? "nil")")
}

@Test func evalEnvOpenAIKey_dataRootIsTheResolutionBase_notTheProcessCWD() throws {
    // The row's second half: TTS resolves against `<dataRoot>/providers`, NOT
    // `<cwd>/data/providers`. An installed .app runs with CWD `/`, so a
    // CWD-relative resolve returns notConfigured with the key sitting on disk.
    let root = try evalTTSRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let envName = "NATIVE_AGENT_TTS_ROOT_EVAL_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

    // Nothing under the data root yet → nil, and specifically NOT a value
    // scavenged from the process CWD.
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json", dataRoot: root
        ) == nil
    )

    // The daemon-parity layout: <dataRoot>/providers/openai.json — no extra
    // "data" segment appended.
    try writeProviderConfig(root, file: "openai.json", apiKey: "sk-dataroot")
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json", dataRoot: root
        ) == "sk-dataroot"
    )
    // A key placed at the CWD-style `<dataRoot>/data/providers/...` must NOT be
    // found by the dataRoot overload — that would mean the two overloads had
    // silently converged.
    let shadowRoot = try evalTTSRoot()
    defer { try? FileManager.default.removeItem(at: shadowRoot) }
    try writeProviderConfig(
        shadowRoot.appendingPathComponent("data", isDirectory: true),
        file: "openai.json", apiKey: "sk-cwd-shaped"
    )
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: envName, providerConfigFile: "openai.json", dataRoot: shadowRoot
        ) == nil,
        "the dataRoot overload must not append a `data` segment — that is the REPO_PATH-parity bug this pins"
    )

    // The third source (codex_home/auth.json) is OPENAI-ONLY. A non-OpenAI
    // envVar must never pick up an OpenAI OAuth key and point it at the wrong
    // endpoint.
    let codexRoot = try evalTTSRoot()
    defer { try? FileManager.default.removeItem(at: codexRoot) }
    let codexDir = codexRoot.appendingPathComponent("codex_home", isDirectory: true)
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    try Data("{\"OPENAI_API_KEY\":\"sk-codex\"}".utf8)
        .write(to: codexDir.appendingPathComponent("auth.json"))
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENAI_API_KEY", providerConfigFile: "openai.json",
            dataRoot: codexRoot, includeEnvironment: false
        ) == "sk-codex",
        "the codex_home fallback is the documented third source for OpenAI"
    )
    #expect(
        LLMCredentialResolver.resolveAPIKey(
            envVar: "ANTHROPIC_API_KEY", providerConfigFile: "anthropic.json",
            dataRoot: codexRoot, includeEnvironment: false
        ) == nil,
        "a non-OpenAI provider must NOT read the codex OAuth key — a Bearer at the wrong endpoint 401s silently"
    )
}
