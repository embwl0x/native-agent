import Foundation
import Network
import Testing
@testable import NativeAgentApp

/// Unit coverage for the shared loopback-bridge server tissue extracted in C5.
/// These guard the auth + parse + read-deadline logic that ClaudeBridge and
/// MacControlBridge now both route through, so a future edit to one bridge can't
/// silently reintroduce the asymmetric-hardening drift the extraction closed.
@Suite("BridgeCore shared server tissue")
struct BridgeCoreTests {
    // MARK: - Constant-time bearer compare

    @Test("constant-time compare accepts an exact match and rejects mismatches")
    func constantTimeEqualsMatchesExactly() {
        #expect(BridgeCore.constantTimeEquals("Bearer abc123", "Bearer abc123"))
        #expect(!BridgeCore.constantTimeEquals("Bearer abc123", "Bearer abc124"))
        // Length mismatch must not short-circuit to a spurious match.
        #expect(!BridgeCore.constantTimeEquals("Bearer abc", "Bearer abc123"))
        #expect(!BridgeCore.constantTimeEquals("", "Bearer x"))
        // Two empty strings are equal (the empty-token guard lives in authorize,
        // not here).
        #expect(BridgeCore.constantTimeEquals("", ""))
    }

    // MARK: - Bearer auth decision (best-of-both: empty-token 503 + const-time)

    @Test("authorize returns serverStopping when the live token is empty")
    func authorizeEmptyTokenIsServerStopping() {
        // The listener was terminated between accept and route; even a peer that
        // sent "Authorization: Bearer " (string-equals an empty token) must be
        // rejected as 503, never leaked as authorized.
        #expect(BridgeCore.authorize(authorizationHeader: "Bearer ", liveToken: "") == .serverStopping)
        #expect(BridgeCore.authorize(authorizationHeader: nil, liveToken: "") == .serverStopping)
        #expect(BridgeCore.authorize(authorizationHeader: "", liveToken: "") == .serverStopping)
    }

    @Test("authorize accepts the matching bearer and rejects everything else")
    func authorizeMatchesLiveToken() {
        let token = "s3cr3t-token-value"
        #expect(BridgeCore.authorize(authorizationHeader: "Bearer \(token)", liveToken: token) == .authorized)
        #expect(BridgeCore.authorize(authorizationHeader: "Bearer wrong", liveToken: token) == .unauthorized)
        #expect(BridgeCore.authorize(authorizationHeader: token, liveToken: token) == .unauthorized) // missing "Bearer " prefix
        #expect(BridgeCore.authorize(authorizationHeader: nil, liveToken: token) == .unauthorized)
    }

    // MARK: - Content-Length parsing (shared cap + edge handling)

    @Test("parseContentLength defaults absent/empty to zero")
    func parseContentLengthDefaultsToZero() {
        #expect(BridgeCore.parseContentLength([:], maxBytes: 1024) == 0)
        #expect(BridgeCore.parseContentLength(["content-length": ""], maxBytes: 1024) == 0)
    }

    @Test("parseContentLength accepts in-range values and rejects invalid/oversized")
    func parseContentLengthBounds() {
        #expect(BridgeCore.parseContentLength(["content-length": "512"], maxBytes: 1024) == 512)
        #expect(BridgeCore.parseContentLength(["content-length": "1024"], maxBytes: 1024) == 1024)
        // Over the cap → nil (caller answers 413).
        #expect(BridgeCore.parseContentLength(["content-length": "1025"], maxBytes: 1024) == nil)
        // Negative and non-numeric → nil.
        #expect(BridgeCore.parseContentLength(["content-length": "-1"], maxBytes: 1024) == nil)
        #expect(BridgeCore.parseContentLength(["content-length": "abc"], maxBytes: 1024) == nil)
        // Surrounding whitespace is tolerated.
        #expect(BridgeCore.parseContentLength(["content-length": " 42 "], maxBytes: 1024) == 42)
    }

    // MARK: - Loopback endpoint classification

    @Test("endpointIsLoopback accepts loopback hosts and rejects a routable peer")
    func endpointIsLoopbackClassification() {
        func hostPort(_ host: String) -> NWEndpoint {
            .hostPort(host: NWEndpoint.Host(host), port: 8770)
        }
        #expect(BridgeCore.endpointIsLoopback(hostPort("127.0.0.1")))
        #expect(BridgeCore.endpointIsLoopback(hostPort("localhost")))
        #expect(BridgeCore.endpointIsLoopback(hostPort("::1")))
        #expect(!BridgeCore.endpointIsLoopback(hostPort("192.168.1.50")))
        #expect(!BridgeCore.endpointIsLoopback(hostPort("10.0.0.1")))
    }

    // MARK: - Token generation

    @Test("generateToken yields url-safe, padding-free, unique tokens")
    func generateTokenShape() throws {
        let a = try #require(BridgeCore.generateToken())
        let b = try #require(BridgeCore.generateToken())
        #expect(a != b)
        // 24 random bytes → 32 base64 chars, padding stripped, url-safe alphabet.
        for token in [a, b] {
            #expect(!token.isEmpty)
            #expect(!token.contains("+"))
            #expect(!token.contains("/"))
            #expect(!token.contains("="))
        }
    }

    // MARK: - Status reason phrases

    @Test("statusText covers the union of both bridges' emitted codes")
    func statusTextTable() {
        #expect(BridgeCore.statusText(for: 200) == "OK")
        // 503 is emitted by the empty-token guard; both bridges previously fell
        // through to "Internal Server Error" — now correct.
        #expect(BridgeCore.statusText(for: 503) == "Service Unavailable")
        #expect(BridgeCore.statusText(for: 401) == "Unauthorized")
        #expect(BridgeCore.statusText(for: 413) == "Payload Too Large")
        #expect(BridgeCore.statusText(for: 504) == "Gateway Timeout")
        #expect(BridgeCore.statusText(for: 999) == "Internal Server Error")
    }

    // MARK: - UUID-gated read deadline (both bridges now share this)

    @Test("read-deadline state cancels only its own unrouted connection")
    func readDeadlineIsIdentityGated() {
        let liveToken = UUID()
        let staleToken = UUID()
        let pending = BridgeReadDeadlineState(token: liveToken)
        #expect(pending.shouldCancel(firingToken: liveToken))
        #expect(!pending.shouldCancel(firingToken: staleToken))
    }

    @Test("a routed connection is exempt from its read deadline")
    func routedConnectionIsExempt() {
        let token = UUID()
        var state = BridgeReadDeadlineState(token: token)
        state.routed = true
        #expect(!state.shouldCancel(firingToken: token))
    }
}
