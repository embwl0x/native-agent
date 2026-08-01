import Foundation
import Testing
@testable import NativeAgentApp

// FIRSTRUN-1 + FIRSTRUN-2: first-run honesty for fresh public users.
//
// FIRSTRUN-1 — a resolvable `codex` binary with no auth on disk used to satisfy
// `hasAnyUsableProvider()`, so a stranger who happened to have the Codex CLI
// installed skipped provider-setup guidance and watched their first chat fail
// raw. Codex must count only when a real token is present.
//
// FIRSTRUN-2 — Save wrote the key and reported "Saved." with zero validation
// while downstream readiness is inferred from file presence. Save must land in
// a saved-but-unverified state that only Test Connection can clear.
@Suite("First-run provider readiness")
struct FirstRunProviderReadinessTests {

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("firstrun-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeCodexAuth(root: URL, json: String) throws {
        let dir = root.appendingPathComponent("codex_home", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("auth.json"))
    }

    /// An injected root must not inherit the machine's real credentials, so the
    /// environment is scrubbed of every source the readiness check honors.
    private let hermeticEnvironment: [String: String] = [:]

    // MARK: - FIRSTRUN-1

    @Test("(a) codex binary present, no auth on disk => not usable, guidance shown")
    func codexBinaryWithoutAuthIsNotUsable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let usable = AppModel.hasAnyUsableProvider(
            dataRoot: root,
            environment: hermeticEnvironment,
            homeDirectory: root.appendingPathComponent("fake-home", isDirectory: true),
            codexBinaryIsResolvable: { true }
        )

        #expect(usable == false, "A codex binary with no auth token must not count as a usable provider")
    }

    @Test("(b) codex binary present WITH OAuth tokens => usable")
    func codexBinaryWithOAuthTokensIsUsable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Fixture value deliberately NOT shaped like a real key — an sk-*
        // string here trips the gitleaks pre-commit guard.
        try writeCodexAuth(root: root, json: #"{"tokens":{"access_token":"fixture-oauth-token-for-test"}}"#)

        let usable = AppModel.hasAnyUsableProvider(
            dataRoot: root,
            environment: hermeticEnvironment,
            homeDirectory: root.appendingPathComponent("fake-home", isDirectory: true),
            codexBinaryIsResolvable: { true }
        )

        #expect(usable == true, "A signed-in Codex install must still count as usable")
    }

    @Test("(b') codex auth via API-key form also counts")
    func codexApiKeyAuthIsUsable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCodexAuth(root: root, json: #"{"OPENAI_API_KEY":"sk-proj-xyz"}"#)

        let usable = AppModel.hasAnyUsableProvider(
            dataRoot: root,
            environment: hermeticEnvironment,
            homeDirectory: root.appendingPathComponent("fake-home", isDirectory: true),
            codexBinaryIsResolvable: { false }
        )

        #expect(usable == true)
    }

    @Test("an auth.json stub with no token does not count")
    func emptyCodexAuthStubIsNotUsable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCodexAuth(root: root, json: #"{"tokens":{"access_token":""}}"#)

        let usable = AppModel.hasAnyUsableProvider(
            dataRoot: root,
            environment: hermeticEnvironment,
            homeDirectory: root.appendingPathComponent("fake-home", isDirectory: true),
            codexBinaryIsResolvable: { true }
        )

        #expect(usable == false, "A token-less auth.json cannot answer a chat and must not suppress guidance")
    }

    @Test("an established install with a provider credential file stays usable")
    func providerCredentialFileKeepsInstallUsable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try Data(#"{"api_key":"sk-ant-abc"}"#.utf8)
            .write(to: providers.appendingPathComponent("anthropic.json"))

        let usable = AppModel.hasAnyUsableProvider(
            dataRoot: root,
            environment: hermeticEnvironment,
            homeDirectory: root.appendingPathComponent("fake-home", isDirectory: true),
            codexBinaryIsResolvable: { false }
        )

        #expect(usable == true, "The guard must never false-block a machine that has a connected provider")
    }

    // MARK: - FIRSTRUN-2

    private func testResult(status: String, tested: Bool = true) -> ProviderTestResult {
        ProviderTestResult(
            provider_id: "anthropic",
            status: status,
            tested: tested,
            response: nil,
            model_used: nil,
            detail: nil,
            error: status == "ok" ? nil : "unauthorized"
        )
    }

    @Test("(c) Save marks saved-but-unverified and never claims the key works")
    func saveMarksUnverified() {
        let state = ProviderCredentialVerification.afterSave()

        #expect(state == .savedUnverified)
        let copy = state.statusText()
        #expect(copy.contains("Not checked yet"))
        #expect(copy.contains("Test Connection"))
        #expect(!copy.lowercased().contains("working"),
                "Save copy must not claim the provider works — it is only written to disk")
        #expect(state.badge?.status == "warn")
    }

    @Test("(c) a passing Test Connection clears the unverified state")
    func passingTestClearsUnverified() {
        var state = ProviderCredentialVerification.afterSave()
        #expect(state == .savedUnverified)

        state = .afterTest(testResult(status: "ok"))

        #expect(state == .verified)
        #expect(state.statusText().contains("tested"))
        #expect(state.badge?.status == "ok")
    }

    @Test("a failing or untested Test Connection does not promote to verified")
    func failingTestDoesNotVerify() {
        #expect(ProviderCredentialVerification.afterTest(testResult(status: "error")) == .verificationFailed)
        let failed = ProviderCredentialVerification.verificationFailed
        #expect(!failed.statusText().lowercased().contains("working"))
        #expect(failed.badge?.status == "error")
    }

    @Test("a provider with no live probe is not marked failed (gpt-5.5 BLOCKING)")
    func noProbeIsNotFailure() {
        // Anthropic's testProvider returns ok/tested:false ("probe skipped").
        // Mapping that to verificationFailed dead-ends a working key: it can
        // never reach verified, and the sheet claims "test failed" forever.
        let noProbe = ProviderCredentialVerification.afterTest(testResult(status: "ok", tested: false))
        #expect(noProbe == .savedNoProbe)
        #expect(noProbe != .verified, "untestable must not silently claim working either")
        #expect(!noProbe.statusText().lowercased().contains("failed"))
        #expect(noProbe.statusText().contains("no connection test"))
        #expect(noProbe.badge?.status == "ok")

        // "unknown" (no probe registered for this provider id) — same rule.
        #expect(ProviderCredentialVerification.afterTest(testResult(status: "unknown", tested: false)) == .savedNoProbe)

        // But an attempt that found something wrong BEFORE probing (no key on
        // disk) is a real failure even with tested:false.
        #expect(ProviderCredentialVerification.afterTest(testResult(status: "error", tested: false)) == .verificationFailed)
    }

    @Test("provider-specific save notes never claim the key is verified")
    func providerNoteStaysHonest() {
        let copy = ProviderCredentialVerification.afterSave()
            .statusText(providerNote: "Moonshot model choices are ready.")
        #expect(copy.contains("Not checked yet"))
        #expect(copy.contains("Moonshot model choices are ready."))
    }

    @Test("clearing credentials drops any verification claim")
    func clearResetsVerification() {
        #expect(ProviderCredentialVerification.afterClear() == .idle)
        #expect(ProviderCredentialVerification.idle.badge == nil,
                "With no local claim the header falls back to the provider's own auth status")
        #expect(ProviderCredentialVerification.idle.statusText().isEmpty)
    }
}
