import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// evals-total-coverage — fence `app.bridges`, row `slack.oauth.saveSlackToken`
// (NativeOAuthFlow+Slack.swift:9, validators at :119/:146, merges at
// :189/:195/:202) crossed with the reader that has to agree with it,
// `SlackSocketModeConfig.load` (SlackSocketModeLoop.swift:49).
//
// Silent-failure class: SILENT ZERO. The writer persists to TWO files
// (data/oauth_tokens/slack.json and data/connectors/slack/auth.json) and the
// loop's reader unions BOTH. If a save lands in only one of them, or the app
// token is merged under a key the reader does not alias, `load` returns nil,
// `makeSlackSocketModeLoopIfConfigured` returns no loop, and Slack is simply
// never connected — no error, no card, no row. The mirror failure is the
// validator drifting so a pasted user token (xoxp/short/whitespace) is saved
// and the loop then fails auth forever.
//
// Hermetic: every call takes an injected `dataRoot`, and `validateWithSlack:
// false` keeps the network out of it (the auth.test hop is a separate,
// live-only concern). Nothing under the repo's data/ is touched.
@Suite("Slack token save round-trip")
struct SlackTokenPersistenceRoundTripTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func legacyPath(_ root: URL) -> URL {
        root.appendingPathComponent("oauth_tokens", isDirectory: true).appendingPathComponent("slack.json")
    }

    private func connectorPath(_ root: URL) -> URL {
        root.appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private let botToken = "xoxb-1111111111-2222222222-abcdefghijklmnopqrst" // gitleaks:allow — deliberate fake token; this eval proves redaction/validation
    private let appToken = "xapp-1-A01234567-1234567890123-abcdefabcdefabcdef" // gitleaks:allow — deliberate fake token; this eval proves redaction/validation

    @Test("a saved token round-trips into a loadable Socket Mode config")
    func saveRoundTripsIntoLoadableConfig() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await NativeOAuthFlow.saveSlackToken(
            botToken,
            appToken: appToken,
            allowedChannelIds: ["C0LIVE"],
            allowedUserIds: ["U0USER"],
            requireMention: false,
            validateWithSlack: false,
            dataRoot: root
        )
        #expect(result.ok, "save failed: \(result.error ?? "-")")

        // BOTH files, with the same token. One-of-two is the silent-zero case.
        let legacy = try #require(json(legacyPath(root)), "legacy oauth_tokens/slack.json was never written")
        let connector = try #require(json(connectorPath(root)), "connectors/slack/auth.json was never written")
        #expect(legacy["access_token"] as? String == botToken)
        #expect(connector["access_token"] as? String == botToken)
        #expect(legacy["provider"] as? String == "slack")
        #expect(connector["provider"] as? String == "slack")

        // The app token must land under the alias the reader actually looks up.
        #expect(connector["socket_mode_app_token"] as? String == appToken)
        #expect(connector["socket_mode_enabled"] as? Bool == true)

        // The reader agrees — this is the assertion that binds writer to loop.
        let config = try #require(
            SlackSocketModeConfig.load(dataRoot: root),
            "the loop reader could not build a config from what the writer just saved"
        )
        #expect(config.botToken == botToken)
        #expect(config.appToken == appToken)
        #expect(config.enabled)
        #expect(config.requireMention == false)
        #expect(config.allowedChannelIds == ["C0LIVE"])
        #expect(config.allowedUserIds == ["U0USER"])

        // …and so does the ingress policy the transport gate consults.
        let policy = SlackSocketModeConfig.loadIngressPolicy(dataRoot: root)
        #expect(policy.isConfigured, "an allowlisted save that reads as unconfigured fails CLOSED — silent silence")
        #expect(policy.allowedChannelIds == ["C0LIVE"])
        #expect(policy.denial(channelId: "C0LIVE", userId: "U0USER", eventType: "message", channelType: "im", rawText: "hi") == nil)
        #expect(policy.denial(channelId: "C0OTHER", userId: "U0STRANGER", eventType: "message", channelType: "im", rawText: "hi") == .notAllowlisted)

        // The connector registry row is what the Connectors UI reads.
        let registry = try await NativeClient.readConnectorRegistryEntry(root: root, provider: "slack")
        let entry = try #require(registry, "no slack row in connectors/registry.json")
        #expect(entry["connected"] == .bool(true))
        #expect(entry["authState"] == .string("connected"))
    }

    @Test("an implausible token is refused and writes nothing at all")
    func implausibleTokensAreRefusedWithoutWriting() async throws {
        let cases: [(String, String?)] = [
            ("", nil),                                  // nothing saved, nothing on disk
            ("xoxb-short", nil),                        // too short
            ("slack-1111111111111111111111", nil),      // wrong prefix
            ("xoxb-1111111111 2222222222-abcdefghij", nil), // embedded whitespace
        ]
        for (token, app) in cases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let result = await NativeOAuthFlow.saveSlackToken(
                token,
                appToken: app,
                validateWithSlack: false,
                dataRoot: root
            )
            #expect(result.ok == false, "\(token.isEmpty ? "<empty>" : token) was accepted")
            #expect(result.error?.isEmpty == false, "a refusal must carry a reason")
            #expect(json(legacyPath(root)) == nil, "a refused save still wrote oauth_tokens/slack.json")
            #expect(json(connectorPath(root)) == nil, "a refused save still wrote connectors/slack/auth.json")
            #expect(SlackSocketModeConfig.load(dataRoot: root) == nil)
        }
    }

    @Test("a malformed app token is refused before the bot token is overwritten")
    func badAppTokenDoesNotClobberAGoodBotToken() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await NativeOAuthFlow.saveSlackToken(
            botToken,
            appToken: appToken,
            allowedChannelIds: ["C0LIVE"],
            validateWithSlack: false,
            dataRoot: root
        ).ok)

        let result = await NativeOAuthFlow.saveSlackToken(
            botToken,
            appToken: "yapp-not-a-slack-app-token-000000",
            validateWithSlack: false,
            dataRoot: root
        )
        #expect(result.ok == false)
        // The previously working config must survive a rejected edit.
        let config = try #require(SlackSocketModeConfig.load(dataRoot: root))
        #expect(config.appToken == appToken, "a rejected app token damaged the stored Socket Mode credentials")
    }

    @Test("an empty token re-uses the stored bot token so an allowlist edit cannot wipe it")
    func emptyTokenAdoptsTheStoredBotToken() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await NativeOAuthFlow.saveSlackToken(
            botToken,
            appToken: appToken,
            allowedChannelIds: ["C0FIRST"],
            requireMention: true,
            validateWithSlack: false,
            dataRoot: root
        ).ok)

        // The UI clears the token field after a successful save; the next
        // allowlist edit therefore arrives with an EMPTY token.
        let second = await NativeOAuthFlow.saveSlackToken(
            "",
            appToken: appToken,
            allowedChannelIds: ["C0SECOND"],
            requireMention: false,
            validateWithSlack: false,
            dataRoot: root
        )
        #expect(second.ok, "an allowlist-only edit was refused: \(second.error ?? "-")")

        let config = try #require(SlackSocketModeConfig.load(dataRoot: root))
        #expect(config.botToken == botToken, "the stored bot token was wiped by an allowlist-only save")
        #expect(config.requireMention == false)
        // The reader UNIONS both files by design (the transport gate must not be
        // stricter than the trust root), so the earlier channel stays admitted.
        #expect(config.allowedChannelIds.contains("C0SECOND"))
    }
}
