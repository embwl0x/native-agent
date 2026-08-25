import NativeAgentCore
import PersistenceCore
import Testing
@testable import SlackConnector

@Suite("Slack connector behavior wave 2")
struct SlackConnectorBehaviorWave2EvalTests {
    private func rendered(_ value: JSONValue) -> String {
        switch value {
        case .string(let value): return value
        case .array(let values): return values.map(rendered).joined(separator: " ")
        case .object(let object): return object.values.map(rendered).joined(separator: " ")
        default: return ""
        }
    }

    @Test("Slack receipt redaction removes bot, app, and exchange credentials at every nesting depth")
    func redactsEverySupportedTokenVocabulary() {
        let tokens = [
            "xoxb-" + String(repeating: "b", count: 24),
            "xapp-" + String(repeating: "a", count: 24),
            "xoxe.xoxp-" + String(repeating: "c", count: 24),
        ]
        let source: JSONValue = .object([
            "response": .array([.string(tokens.joined(separator: " "))]),
            "nested": .object(["token": .string(tokens[2])]),
        ])
        let result = rendered(SlackConnectorActions.redactReceipt(source))
        for token in tokens { #expect(!result.contains(token)) }
        #expect(result.components(separatedBy: "[REDACTED_SLACK_TOKEN]").count == 5)
    }

    @Test("Slack redaction leaves ordinary response content legible")
    func redactionDoesNotEraseOrdinaryFailureEvidence() {
        let result = SlackConnectorActions.redactReceipt(.object([
            "error": .string("invalid_auth"),
            "httpStatus": .int(401),
        ]))
        #expect(result == .object([
            "error": .string("invalid_auth"),
            "httpStatus": .int(401),
        ]))
    }

    @Test("Slack external-upload URLs are HTTPS Slack hosts, never arbitrary destinations")
    func externalUploadURLMustBeTrustedSlackHTTPS() {
        #expect(SlackConnectorActions.trustedExternalUploadURL(
            "https://files.slack.com/upload/v1/signed"
        ) != nil)
        for raw in [
            "http://files.slack.com/upload/v1/signed",
            "https://files.slack.com.evil.example/upload",
            "https://files.slack.com:8443/upload",
            "https://user:pass@files.slack.com/upload",
        ] {
            #expect(SlackConnectorActions.trustedExternalUploadURL(raw) == nil)
        }
    }

    @Test("Slack status envelopes make auth failure visibly failed")
    func statusEnvelopeDoesNotTurnOKFalseIntoSuccess() {
        let failed = SlackConnectorActions.envelope(
            action: "slack.status",
            response: ["ok": false, "error": "invalid_auth"],
            successStatus: "completed"
        )
        guard case .object(let fields) = failed else {
            Issue.record("expected Slack status envelope")
            return
        }
        #expect(fields["actionId"] == .string("slack.status"))
        #expect(fields["connectorId"] == .string("slack"))
        #expect(fields["ok"] == .bool(false))
        #expect(fields["status"] == .string("failed"))
        #expect(fields["error"] == .string("invalid_auth"))

        // Positive control: a valid response must retain the caller's terminal
        // success classification, so the failure assertion above cannot pass
        // because the envelope builder is inert.
        guard case .object(let success) = SlackConnectorActions.envelope(
            action: "slack.status", response: ["ok": true], successStatus: "completed"
        ) else {
            Issue.record("expected successful Slack status envelope")
            return
        }
        #expect(success["ok"] == .bool(true))
        #expect(success["status"] == .string("completed"))
    }

    @Test("Slack list-channels defaults retain direct messages and bound input")
    func listChannelsRequestRetainsDMsAndClampsLimit() {
        let defaults = SlackConnectorActions.listChannelsRequest(input: [:])
        #expect(defaults.limit == 100)
        #expect(defaults.types == "public_channel,private_channel,mpim,im")

        let custom = SlackConnectorActions.listChannelsRequest(input: [
            "limit": .int(9_999), "types": .string(" im,mpim "),
        ])
        #expect(custom.limit == 1_000)
        #expect(custom.types == "im,mpim")

        // Negative control: blank caller input must use the complete default,
        // not a silently empty types filter that hides every DM.
        let blank = SlackConnectorActions.listChannelsRequest(input: [
            "limit": .int(0), "types": .string("  "),
        ])
        #expect(blank.limit == 1)
        #expect(blank.types == defaults.types)
    }
}
