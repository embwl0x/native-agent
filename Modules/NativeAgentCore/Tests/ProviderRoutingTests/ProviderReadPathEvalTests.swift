import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - Ledger rows
//   providers.getProvider        (UNCOVERED — every prior occurrence in the
//                                 test tree was a protocol STUB, never the
//                                 real implementation)
//   providers.testProvider       (UNCOVERED — the honesty label and the
//                                 `tested:false` flag had zero assertions, so
//                                 a future "improvement" could relabel a
//                                 credential-PRESENCE check as a passed
//                                 connectivity test with nothing going red)
//   providers.store.registryJSON (REPORTS-ONLY — both prior tests used it as a
//                                 dataRoot marker and asserted nothing about
//                                 precedence or corruption)
//
// Every root here is a fresh temp dir. `providerReadiness` only consults the
// process environment when dataRoot == PersistenceCore.defaultDataRoot(), so a
// pinned temp root also isolates these from the machine's real API keys.

private struct ProviderReadPathRoot {
    let root: URL
    let providers: URL
}

private func makeProviderReadPathRoot() throws -> ProviderReadPathRoot {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProviderReadPathEval-\(UUID().uuidString)", isDirectory: true)
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    return ProviderReadPathRoot(root: root, providers: providers)
}

private func makeReadPathRouting(_ paths: ProviderReadPathRoot) -> SwiftNativeProviderRouting {
    SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.providers.appendingPathComponent("surfaces.json"),
        activeProviderPathOverride: paths.providers.appendingPathComponent("active.json")
    )
}

/// Detail strings that would be a LIE for a presence-only check. The point of
/// the row is that this control is the one a user reaches for to answer "is
/// this provider working" — it must never imply the wire was exercised.
private let connectivityClaimTokens = [
    "connected", "connectivity verified", "reachable", "responded",
    "test passed", "probe ok", "handshake", "round-trip", "roundtrip",
]

@Suite("Provider read path: getProvider / testProvider / registry.json")
struct ProviderReadPathEvalTests {

    // MARK: providers.getProvider

    /// Envelope: a provider whose credential file is on disk resolves, carries
    /// its own id back, and reports configured == true. An id that is on
    /// NEITHER disk nor the always-synthesized list THROWS rather than
    /// returning a synthesized shell that `testProvider` would then call "ok".
    @Test func getProvider_resolvesOnDiskCredential_andThrowsForAnUnknownID() async throws {
        let paths = try makeProviderReadPathRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try Data(#"{"api_key":"junk-but-present"}"#.utf8)
            .write(to: paths.providers.appendingPathComponent("openai.json"))
        let routing = makeReadPathRouting(paths)

        let openai = try await routing.getProvider(id: "openai")
        #expect(openai.id == "openai")
        #expect(openai.configured == true, "a present api_key must read as configured")

        let unknown = "not-a-provider-\(UUID().uuidString)"
        await #expect(throws: (any Error).self) {
            _ = try await routing.getProvider(id: unknown)
        }
    }

    /// Envelope: the picker/infrastructure files that live in the same
    /// directory are never resolvable AS providers. `registry.json` heads the
    /// skip list precisely because it is the store, not a provider.
    @Test func getProvider_neverResolvesTheStoreFilesAsProviders() async throws {
        let paths = try makeProviderReadPathRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        for name in ["registry", "models", "active", "surfaces",
                     "openrouter-models-cache", "moonshot-models-cache"] {
            try Data("{}".utf8).write(
                to: paths.providers.appendingPathComponent("\(name).json"))
        }
        let routing = makeReadPathRouting(paths)

        let ids = Set(try await routing.listProviders().map { $0.id })
        for name in ["registry", "models", "active", "surfaces",
                     "openrouter-models-cache", "moonshot-models-cache"] {
            #expect(!ids.contains(name), "'\(name).json' is an infrastructure file, not a provider row")
            await #expect(throws: (any Error).self) {
                _ = try await routing.getProvider(id: name)
            }
        }
    }

    // MARK: providers.testProvider

    /// Envelope (the honesty contract): `tested` is FALSE on BOTH branches and
    /// no detail string on either branch claims the connection was exercised.
    /// A relabel to "connection ok" — or flipping `tested` to true without a
    /// real probe — fails here.
    @Test func testProvider_isHonestAboutNeverTouchingTheWire() async throws {
        let paths = try makeProviderReadPathRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        // (a) present-but-junk key, (b) nothing at all.
        try Data(#"{"api_key":"junk-but-present"}"#.utf8)
            .write(to: paths.providers.appendingPathComponent("openai.json"))
        let routing = makeReadPathRouting(paths)

        for (id, expectedStatus, expectedReady) in [
            ("openai", "ok", true),
            ("anthropic", "needs_credentials", false),
        ] {
            let result = try await routing.testProvider(id: id)
            guard case .object(let raw) = result.rawResponse else {
                Issue.record("testProvider(\(id)) must return an object envelope")
                continue
            }
            #expect(raw["provider_id"] == .string(id))
            #expect(raw["status"] == .string(expectedStatus))
            #expect(
                raw["tested"] == .bool(false),
                "testProvider is a credential-PRESENCE check — `tested` must stay false until a real probe ships"
            )
            guard case .string(let detail)? = raw["detail"] else {
                Issue.record("testProvider(\(id)) must carry a detail string")
                continue
            }
            let lowered = detail.lowercased()
            for claim in connectivityClaimTokens {
                #expect(
                    !lowered.contains(claim),
                    "detail for \(id) claims connectivity ('\(claim)') on a presence-only check: \(detail)"
                )
            }
            #expect((try await routing.getProvider(id: id)).configured == expectedReady)
        }
    }

    /// The literal honesty label lives on the branch a registry-supplied
    /// provider takes (no synthesized oauthStatus to borrow a detail from).
    /// Pin BOTH strings so the parenthetical cannot be quietly dropped.
    @Test func testProvider_registryProviderUsesTheExplicitHonestyLabel() async throws {
        let paths = try makeProviderReadPathRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let ready = Provider(id: "legacy-ready", displayName: "Legacy ready", kind: "api_key", configured: true)
        let notReady = Provider(id: "legacy-unready", displayName: "Legacy unready", kind: "api_key", configured: false)
        try JSONEncoder().encode([ready, notReady])
            .write(to: paths.providers.appendingPathComponent("registry.json"))
        let routing = makeReadPathRouting(paths)

        let okResult = try await routing.testProvider(id: "legacy-ready")
        guard case .object(let okRaw) = okResult.rawResponse,
              case .string(let okDetail)? = okRaw["detail"] else {
            Issue.record("expected an object envelope with a detail string"); return
        }
        #expect(okDetail == "Credentials present (connectivity not tested)")
        #expect(okRaw["tested"] == .bool(false))
        #expect(okRaw["status"] == .string("ok"))

        let badResult = try await routing.testProvider(id: "legacy-unready")
        guard case .object(let badRaw) = badResult.rawResponse,
              case .string(let badDetail)? = badRaw["detail"] else {
            Issue.record("expected an object envelope with a detail string"); return
        }
        #expect(badDetail == "No usable credentials found")
        #expect(badRaw["tested"] == .bool(false))
        #expect(badRaw["status"] == .string("needs_credentials"))
    }

    // MARK: providers.store.registryJSON

    /// Envelope: registry.json takes PRECEDENCE over synthesis, and the result
    /// is exactly ONE row for that id — never a duplicate, never a merge. This
    /// is the property the Providers panel depends on; it is currently
    /// unasserted anywhere, so a stale hand-edited registry row silently wins
    /// over the credential-file truth with nothing to say so.
    @Test func registryJSON_takesPrecedenceOverSynthesis_withExactlyOneRowPerID() async throws {
        let paths = try makeProviderReadPathRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        // Credential truth on disk says configured; the registry row disagrees.
        try Data(#"{"api_key":"junk-but-present"}"#.utf8)
            .write(to: paths.providers.appendingPathComponent("openai.json"))
        let stale = Provider(
            id: "openai",
            displayName: "STALE REGISTRY NAME",
            kind: "api_key",
            configured: false
        )
        try JSONEncoder().encode([stale])
            .write(to: paths.providers.appendingPathComponent("registry.json"))
        let routing = makeReadPathRouting(paths)

        let providers = try await routing.listProviders()
        let openaiRows = providers.filter { $0.id == "openai" }
        #expect(openaiRows.count == 1, "registry + credential file must collapse to ONE row, got \(openaiRows.count)")
        // Documented (and until now unpinned) precedence: the store wins.
        #expect(openaiRows.first?.displayName == "STALE REGISTRY NAME")
        #expect(openaiRows.first?.configured == false)
        // The same row is what getProvider/testProvider resolve through.
        #expect(try await routing.getProvider(id: "openai").displayName == "STALE REGISTRY NAME")
    }

    /// Envelope: a CORRUPT registry.json is swallowed by `try?` — it must not
    /// take the synthesized rows down with it. If the decode were ever changed
    /// to fail closed (or to short-circuit the directory scan) the Providers
    /// panel would go empty with no error; this is the tripwire.
    @Test func corruptRegistryJSON_doesNotSuppressSynthesizedProviders() async throws {
        let paths = try makeProviderReadPathRoot()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try Data("{not json at all".utf8)
            .write(to: paths.providers.appendingPathComponent("registry.json"))
        try Data(#"{"api_key":"junk-but-present"}"#.utf8)
            .write(to: paths.providers.appendingPathComponent("openai.json"))
        try Data(#"{"api_key":"junk-but-present"}"#.utf8)
            .write(to: paths.providers.appendingPathComponent("moonshot.json"))
        let routing = makeReadPathRouting(paths)

        let providers = try await routing.listProviders()
        let ids = Set(providers.map { $0.id })
        #expect(ids.contains("openai"))
        #expect(ids.contains("moonshot"))
        #expect(!ids.contains("registry"))
        #expect(providers.first(where: { $0.id == "openai" })?.configured == true)
        #expect(providers.first(where: { $0.id == "moonshot" })?.configured == true)
    }
}
