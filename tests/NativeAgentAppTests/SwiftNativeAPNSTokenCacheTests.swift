import Foundation
import Testing
@testable import NativeAgentApp

/// Provider-token caching guard (live incident 2026-07-17): a 4-push burst
/// tripped Apple's `TooManyProviderTokenUpdates` because the ES256 provider JWT
/// was re-minted on every send. These pins prove the JWT is signed once and
/// reused inside the 50-min window, re-minted on expiry, and never double-minted
/// under concurrency (the actor serializes access).
@Suite struct SwiftNativeAPNSTokenCacheTests {

    @Test func processedInboxArchivesAreNotAPNSTokenAuthority() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NativeAgentApp/SwiftNativeAPNS.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("loadICloudProcessedTokens"))
        #expect(!text.contains("icloud_processed_register_push_token"))
        #expect(text.contains("loadSwiftTokens(dataRoot: dataRoot)"))
        #expect(text.contains("loadLegacyTokens(dataRoot: dataRoot)"))
    }

    /// Mutable clock the tests advance to drive expiry deterministically.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { self.current = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }; current = current.addingTimeInterval(seconds)
        }
    }

    /// Thread-safe mint counter — the signer is invoked from actor-isolated code,
    /// but we count under a lock so the concurrency pin is honest.
    private final class MintCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func makeSender(clock: TestClock, counter: MintCounter) -> SwiftNativeAPNSSender {
        SwiftNativeAPNSSender(
            now: { clock.now() },
            sign: { keyId, teamId, _, iat in
                let n = counter.bump()
                // Unique per mint so the tests can tell a fresh token from a reuse.
                return "jwt-\(keyId)-\(teamId)-\(Int(iat.timeIntervalSince1970))-\(n)"
            }
        )
    }

    @Test func twoSendsWithinWindowReuseOneToken() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let counter = MintCounter()
        let sender = makeSender(clock: clock, counter: counter)

        let first = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
        // Advance well inside the 50-min TTL.
        clock.advance(by: 30 * 60)
        let second = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")

        #expect(counter.value == 1)
        #expect(first == second)
    }

    @Test func sendAfterExpiryReMints() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let counter = MintCounter()
        let sender = makeSender(clock: clock, counter: counter)

        let first = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
        // Push just past the TTL so the cache is considered stale.
        clock.advance(by: SwiftNativeAPNSSender.providerTokenTTL + 1)
        let second = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")

        #expect(counter.value == 2)
        #expect(first != second)
    }

    @Test func credentialChangeReMints() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let counter = MintCounter()
        let sender = makeSender(clock: clock, counter: counter)

        _ = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
        // Same instant, different key id → must not reuse the cached token.
        _ = try await sender.providerToken(keyId: "KID2", teamId: "TEAM", keyPath: "/dev/null")

        #expect(counter.value == 2)
    }

    @Test func concurrentSendsDoNotDoubleMint() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let counter = MintCounter()
        let sender = makeSender(clock: clock, counter: counter)

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
                }
            }
            var tokens: [String] = []
            for try await token in group { tokens.append(token) }
            #expect(Set(tokens).count == 1)
        }

        #expect(counter.value == 1)
    }

    @Test func signingErrorPropagatesAndLeavesNoCache() async throws {
        struct SignFailure: Error {}
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let sender = SwiftNativeAPNSSender(
            now: { clock.now() },
            sign: { _, _, _, _ in throw SignFailure() }
        )

        await #expect(throws: SignFailure.self) {
            _ = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
        }
    }

    /// gpt-5.5 review (LOW): a failed RE-mint must not destroy an existing good
    /// cache entry. Pins that the cache write happens only after a successful
    /// sign — a future refactor that clears `cachedProviderToken` before
    /// signing would lose the prior valid token on a transient signer failure,
    /// and only this test would notice.
    @Test func failedReMintKeepsPriorValidCacheEntry() async throws {
        struct SignFailure: Error {}
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let counter = MintCounter()
        let shouldFail = MintCounter()   // reused as a thread-safe flag: >0 = fail
        let sender = SwiftNativeAPNSSender(
            now: { clock.now() },
            sign: { keyId, teamId, _, iat in
                if shouldFail.value > 0 { throw SignFailure() }
                let n = counter.bump()
                return "jwt-\(keyId)-\(teamId)-\(Int(iat.timeIntervalSince1970))-\(n)"
            }
        )

        let first = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
        // Expire the cache, then make the re-mint fail.
        clock.advance(by: 51 * 60)
        _ = shouldFail.bump()
        await #expect(throws: SignFailure.self) {
            _ = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
        }
        // Roll the clock back inside the ORIGINAL token's window: the prior
        // valid entry must still be served — the failed re-mint didn't erase it.
        clock.advance(by: -50 * 60)
        let again = try await sender.providerToken(keyId: "KID", teamId: "TEAM", keyPath: "/dev/null")
        #expect(again == first, "the failed re-mint must not have destroyed the prior valid cache entry")
        #expect(counter.value == 1)
    }
}
