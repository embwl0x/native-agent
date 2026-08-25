import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import GitHubConnector

// Coverage-ledger completion for core.connectors:
//
//   github.credentialStore.reconcileAtLaunch
//   github.secretRedactor
//
// These are deliberately local-only. A launch probe must never wake Keychain
// UI or make an HTTP request, and a redaction assertion that only sees the
// top-level JSON object misses precisely the error-body nesting that leaks
// credentials in practice.

@Suite("eval: GitHub credential readiness and secret redaction")
struct GitHubCredentialReadinessAndRedactionEvalTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-github-eval-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("launch readiness is false only for an absent credential, true for a vault credential")
    func launchReadinessDistinguishesAbsentFromPresentCredential() async throws {
        let root = try temporaryRoot("launch")
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = TestGitHubCredentialVault()
        let store = GitHubCredentialStore(vault: vault)

        #expect(
            try await store.reconcileAtLaunch(dataRoot: root) == false,
            "an empty root must report not-ready rather than pretending the connector is authorized"
        )

        let token = "ghp_" + "launchreadinessfixtureabcdefghijklmno"
        vault.seed(token, dataRoot: root)
        #expect(
            try await store.reconcileAtLaunch(dataRoot: root) == true,
            "a credential held in the vault must be visible to the launch readiness check"
        )
    }

    @Test("launch readiness propagates vault failure instead of converting it to authorization")
    func launchReadinessFailsClosedOnVaultError() async throws {
        let root = try temporaryRoot("vault-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = TestGitHubCredentialVault()
        vault.failReads = true
        let store = GitHubCredentialStore(vault: vault)

        await #expect(throws: TestGitHubCredentialVaultError.readFailed) {
            _ = try await store.reconcileAtLaunch(dataRoot: root)
        }
    }

    @Test("GitHub token redaction reaches strings, arrays, and nested error envelopes")
    func redactionRecursesAtEveryJSONDepthWithoutBlanketingSafeText() throws {
        let classic = "ghp_" + "abcdefghijklmnopqrstuvwxyz1234567890"
        let fineGrained = "github_pat_" + "abcdefghijklmnopqrstuvwx1234567890"
        let payload: JSONValue = .object([
            "authorization": .string("Bearer \(classic)"),
            "items": .array([
                .string("fine token: \(fineGrained)"),
                .object(["retry_detail": .string("oauth failed with \(classic)")]),
            ]),
            "ordinary": .string("issue #42 remains readable"),
        ])

        let redacted = GitHubConnectorSecretRedactor.redactValue(payload)
        let rendered = try redacted.serialize(pretty: false)

        #expect(!rendered.contains(classic))
        #expect(!rendered.contains(fineGrained))
        #expect(rendered.contains("[REDACTED_GITHUB_TOKEN]"))
        #expect(
            rendered.contains("issue #42 remains readable"),
            "the redactor must not turn unrelated diagnostic text into an opaque blank"
        )
    }
}
