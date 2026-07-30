import Foundation
import Testing
@testable import NativeAgentApp
import NativeAgentCore
import PersistenceCore

/// End-to-end tests for the two provider config/clear bugs fixed 2026-07-04:
///   1. FALSE-READY on blank key — a provider file carrying only bookkeeping
///      fields (auth_mode / default_model) must NOT report "ready".
///   2. Remove-Key leaves the cred file — clearProvider must delete
///      providers/<id>.json, not just the registry row, so readiness flips.
///
/// These drive the REAL `NativeClient.listProviders()` / `clearProvider()`
/// against a throwaway data root. Opt-in: they no-op unless
/// `NATIVE_AGENT_PROVIDER_READINESS_TEST=1` AND `NATIVE_AGENT_DATA_ROOT` point
/// at a scratch directory, so a normal suite run never writes fixtures into or
/// deletes from Agent's live data root.
@Suite(.serialized)
struct ProviderReadinessTests {

    private func gatedProvidersDir() throws -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["NATIVE_AGENT_PROVIDER_READINESS_TEST"] == "1",
              let root = env["NATIVE_AGENT_DATA_ROOT"], !root.isEmpty
        else { return nil }
        // Resolves the same env var listProviders/clearProvider read.
        let providersDir = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providersDir, withIntermediateDirectories: true
        )
        return providersDir
    }

    private func state(_ providers: [ProviderInfo], _ id: String) -> String? {
        providers.first(where: { $0.provider_id == id })?.auth_status.state
    }

    @Test
    func blankKeySave_doesNotReadAsReady() async throws {
        guard let providersDir = try gatedProvidersDir() else { return }
        let orFile = providersDir.appendingPathComponent("openrouter.json")
        defer { try? FileManager.default.removeItem(at: orFile) }

        // The exact shape configureProvider writes when Save is pressed with an
        // empty api_key field: auth_mode + default_model, no api_key.
        let blank = #"{"auth_mode":"api_key","default_model":"anthropic/claude-opus-4-8"}"#
        try blank.write(to: orFile, atomically: true, encoding: .utf8)

        let providers = try await NativeClient(baseURL: "").listProviders()
        #expect(
            state(providers, "openrouter") != "ready",
            "blank-key openrouter must NOT report ready — got \(state(providers, "openrouter") ?? "nil")"
        )
    }

    @Test
    func realKey_readsReady_thenClearDeletesFileAndFlipsReadiness() async throws {
        guard let providersDir = try gatedProvidersDir() else { return }
        let orFile = providersDir.appendingPathComponent("openrouter.json")
        defer { try? FileManager.default.removeItem(at: orFile) }

        let keyed = #"{"auth_mode":"api_key","api_key":"sk-or-test-123","default_model":"anthropic/claude-opus-4-8"}"#
        try keyed.write(to: orFile, atomically: true, encoding: .utf8)

        var providers = try await NativeClient(baseURL: "").listProviders()
        #expect(
            state(providers, "openrouter") == "ready",
            "openrouter with a real api_key must report ready — got \(state(providers, "openrouter") ?? "nil")"
        )

        // Remove Key → must delete the on-disk credential, not just a registry row.
        _ = try await NativeClient(baseURL: "").clearProvider("openrouter")
        #expect(
            !FileManager.default.fileExists(atPath: orFile.path),
            "clearProvider must delete providers/openrouter.json"
        )

        providers = try await NativeClient(baseURL: "").listProviders()
        #expect(
            state(providers, "openrouter") != "ready",
            "after Remove Key, openrouter must NOT report ready — got \(state(providers, "openrouter") ?? "nil")"
        )
    }
}
