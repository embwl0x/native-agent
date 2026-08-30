import Foundation
import Testing
@testable import DoctorChecks
@testable import PersistenceCore

/// C9-3 (upgrade sweep 2026-08-28). Two credentials in the live data root had
/// been expired for weeks — `oauth_tokens/x.json` (epoch-seconds-as-STRING,
/// expired 2026-06-20) and `providers/xai_oauth_direct.json` (ISO-8601,
/// expired 2026-07-10) — with no surface reporting it. These tests use both
/// real on-disk shapes, because a check that only understands one spelling is
/// the same silence with a green light on it.
@Suite(.serialized)
struct OAuthTokenExpiryCheckTests {
    private func makeRoot(_ tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-oauth-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("oauth_tokens", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("providers", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ json: String, to url: URL) throws {
        try json.data(using: .utf8)!.write(to: url)
    }

    @Test("both live expiry spellings parse: epoch-seconds string and ISO-8601")
    func parsesBothLiveStampShapes() {
        // The exact literal in oauth_tokens/x.json.
        let epoch = OAuthTokenExpiryCheck.parseExpiry(.string("1781971620.402659"))
        #expect(epoch != nil)
        #expect(abs((epoch?.timeIntervalSince1970 ?? 0) - 1_781_971_620.402659) < 0.001)

        // The exact literal in providers/xai_oauth_direct.json.
        let iso = OAuthTokenExpiryCheck.parseExpiry(.string("2026-07-10T16:05:22Z"))
        #expect(iso != nil)

        #expect(OAuthTokenExpiryCheck.parseExpiry(.int(1_781_971_620)) != nil)
        #expect(OAuthTokenExpiryCheck.parseExpiry(.double(1_781_971_620.5)) != nil)
        #expect(OAuthTokenExpiryCheck.parseExpiry(.string("")) == nil)
        #expect(OAuthTokenExpiryCheck.parseExpiry(.string("not-a-date")) == nil)
        #expect(OAuthTokenExpiryCheck.parseExpiry(nil) == nil)
        // A millisecond stamp must not resolve to the year 58000.
        let millis = OAuthTokenExpiryCheck.parseExpiry(.string("1781971620402"))
        #expect(abs((millis?.timeIntervalSince1970 ?? 0) - 1_781_971_620.402) < 1)
    }

    @Test("expired access tokens with refresh credentials remain healthy")
    func acceptsRefreshableExpiredCredentials() async throws {
        let root = try makeRoot("expired")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_000_000)  // 2026-08-13-ish

        try write(
            #"{"provider":"x","access_token":"SECRET-MUST-NOT-APPEAR","refresh_token":"REFRESH-MUST-NOT-APPEAR","expires_at":"1781971620.402659"}"#,
            to: root.appendingPathComponent("oauth_tokens/x.json")
        )
        try write(
            #"{"provider_id":"xai_oauth_direct","access_token":"SECRET-MUST-NOT-APPEAR","refresh_token":"REFRESH-MUST-NOT-APPEAR","expires_at":"2026-07-10T16:05:22Z"}"#,
            to: root.appendingPathComponent("providers/xai_oauth_direct.json")
        )
        // No expiry at all (the live github PAT / slack shapes): silent, not a finding.
        try write(
            #"{"provider":"github","auth_mode":"personal_access_token"}"#,
            to: root.appendingPathComponent("oauth_tokens/github.json")
        )
        // A providers/ file that is NOT an *_oauth_direct credential must be ignored.
        try write(
            #"{"expires_at":"2000-01-01T00:00:00Z"}"#,
            to: root.appendingPathComponent("providers/openrouter-models-cache.json")
        )

        let result = await OAuthTokenExpiryCheck(root: root, now: now).run()
        #expect(result.id == "oauth_token_expiry")
        #expect(result.status == "ok")
        #expect(result.detail.contains("x access expired"))
        #expect(result.detail.contains("xai_oauth_direct access expired"))
        #expect(result.detail.contains("refresh is available"))
        #expect(!result.detail.contains("github"))
        #expect(!result.detail.contains("openrouter"))
        // The check must never carry credential material into a report.
        #expect(!result.detail.contains("SECRET"))
        #expect(!result.detail.contains("REFRESH"))
        #expect(!(result.repair ?? "").contains("SECRET"))
    }

    @Test("an expired credential without a refresh token still warns")
    func reportsExpiredCredentialThatCannotRefresh() async throws {
        let root = try makeRoot("expired-no-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        try write(
            #"{"provider":"x","expires_at":"1781971620.402659"}"#,
            to: root.appendingPathComponent("oauth_tokens/x.json")
        )

        let result = await OAuthTokenExpiryCheck(root: root, now: now).run()
        #expect(result.status == "warn")
        #expect(result.detail.contains("x expired"))
    }

    @Test("a healthy store is ok, and the 7-day window warns before the failure")
    func healthyAndExpiringSoon() async throws {
        let root = try makeRoot("healthy")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_000_000)

        // Negative control: far-future expiry must NOT warn, so a green result
        // means "read and judged", not "found nothing to read".
        try write(
            #"{"provider":"x","expires_at":\#(now.timeIntervalSince1970 + 90 * 86_400)}"#,
            to: root.appendingPathComponent("oauth_tokens/x.json")
        )
        let ok = await OAuthTokenExpiryCheck(root: root, now: now).run()
        #expect(ok.status == "ok")
        #expect(ok.detail.contains("1 OAuth credential"))

        // Inside the window: warned BEFORE the first failed call.
        try write(
            #"{"provider":"x","expires_at":\#(now.timeIntervalSince1970 + 2 * 86_400)}"#,
            to: root.appendingPathComponent("oauth_tokens/x.json")
        )
        let soon = await OAuthTokenExpiryCheck(root: root, now: now).run()
        #expect(soon.status == "warn")
        #expect(soon.detail.contains("expiring within 7 days"))
    }

    @Test("the check never writes, and an absent or unreadable store degrades quietly")
    func readOnlyAndDegradesQuietly() async throws {
        let root = try makeRoot("readonly")
        defer { try? FileManager.default.removeItem(at: root) }

        try write("{ not json", to: root.appendingPathComponent("oauth_tokens/broken.json"))
        let tokensDir = root.appendingPathComponent("oauth_tokens", isDirectory: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: tokensDir.path).sorted()
        let brokenBytes = try Data(contentsOf: root.appendingPathComponent("oauth_tokens/broken.json"))

        let result = await OAuthTokenExpiryCheck(root: root).run()
        #expect(result.status == "ok")
        #expect(result.detail.contains("broken"))

        // Read-only proof: same file set, same bytes, after the check ran.
        let after = try FileManager.default.contentsOfDirectory(atPath: tokensDir.path).sorted()
        #expect(before == after)
        let brokenAfter = try Data(contentsOf: root.appendingPathComponent("oauth_tokens/broken.json"))
        #expect(brokenAfter == brokenBytes)

        // A data root with no credential directories at all is not a failure.
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-oauth-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        let empty = await OAuthTokenExpiryCheck(root: bare).run()
        #expect(empty.status == "ok")
        #expect(empty.detail.contains("0 OAuth credential"))
    }

    /// Registration is the whole point — an unregistered check reports nothing.
    /// Probed via `runCheck` rather than `runAll` on purpose: runAll includes
    /// StorageCheck, which WRITES into the default data root. This check is
    /// strictly read-only, so resolving it by id touches nothing.
    @Test("the check is registered in the default doctor check set")
    func registeredInDefaultCheckSet() async throws {
        let found = try await SwiftNativeDoctorChecks().runCheck(id: "oauth_token_expiry", repair: false)
        #expect(found?.id == "oauth_token_expiry")
        #expect(found?.title == "OAuth Token Expiry")
    }
}
