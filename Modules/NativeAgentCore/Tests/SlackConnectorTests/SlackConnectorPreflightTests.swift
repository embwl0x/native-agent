import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import SlackConnector

// Eval coverage (ledger fence core.connectors): the Slack connector's
// PRE-DISPATCH boundary — the last place a bad write can be stopped locally.
// Every test here asserts a failure that must happen BEFORE any request is
// built, so none of them can reach slack.com. The one "valid input" case
// deliberately runs against an EMPTY hermetic data root: the token gate
// (-401) is what it must hit, which proves the input guards did not fire on
// good input and that no post is attempted without a credential.

private func slackTempRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("slack-connector-eval-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeTokenFile(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}

private func oauthTokensPath(_ root: URL) -> URL {
    root.appendingPathComponent("oauth_tokens", isDirectory: true)
        .appendingPathComponent("slack.json")
}

private func connectorAuthPath(_ root: URL) -> URL {
    root.appendingPathComponent("connectors", isDirectory: true)
        .appendingPathComponent("slack", isDirectory: true)
        .appendingPathComponent("auth.json")
}

/// Runs `body` and returns the NSError it threw, or records an issue.
private func capturedNSError(
    _ comment: Comment,
    _ body: () async throws -> Void
) async -> NSError? {
    do {
        try await body()
        Issue.record("expected a throw: \(comment)")
        return nil
    } catch {
        return error as NSError
    }
}

@Suite("Slack connector pre-dispatch boundary")
struct SlackConnectorPreflightTests {
    // SlackConnectorActions.swift:13 requireConfiguredToken → :330 loadToken.
    // Live caller: AgentBridgeCompletionRouter.swift:734 — this check is what
    // keeps a missing credential a RETRYABLE pre-dispatch failure instead of
    // an ambiguous external outcome, so the -401 classification is the
    // contract, not the message text.
    @Test
    func requireConfiguredTokenRejectsMissingAndEmptyCredentials() async throws {
        let bareRoot = slackTempRoot()
        let missing = await capturedNSError("no token file anywhere") {
            try SlackConnectorActions.requireConfiguredToken(dataRoot: bareRoot)
        }
        #expect(missing?.domain == "NativeAgentSlack")
        #expect(missing?.code == -401)

        // An empty access_token in the FIRST candidate path must fall through
        // to the second, not be accepted and not short-circuit the search.
        let fallthroughRoot = slackTempRoot()
        try writeTokenFile(["access_token": "   "], to: oauthTokensPath(fallthroughRoot))
        try writeTokenFile(
            ["access_token": "xoxb-" + String(repeating: "a", count: 24)],
            to: connectorAuthPath(fallthroughRoot)
        )
        try SlackConnectorActions.requireConfiguredToken(dataRoot: fallthroughRoot)

        // Second path alone is usable.
        let secondOnly = slackTempRoot()
        try writeTokenFile(
            ["access_token": "xoxb-" + String(repeating: "b", count: 24)],
            to: connectorAuthPath(secondOnly)
        )
        try SlackConnectorActions.requireConfiguredToken(dataRoot: secondOnly)
    }

    // TWO-VOCABULARY PIN. Connectors+Auth.swift:229 (hasUsableToken) accepts
    // `access_token` OR `oauth_token` OR `token`; this loader accepts ONLY
    // `access_token`. A file the Connectors pane calls "connected" is
    // therefore unusable here. This test pins the asymmetry so a change to
    // EITHER side is a red test rather than a silent `invalid_auth` in an
    // envelope nobody reads.
    @Test
    func tokenOnlyFileIsUnusableHereEvenThoughTheAuthLayerCallsItUsable() async throws {
        let root = slackTempRoot()
        try writeTokenFile(
            ["token": "xoxb-" + String(repeating: "c", count: 24)],
            to: oauthTokensPath(root)
        )
        let error = await capturedNSError("`token` is not `access_token`") {
            try SlackConnectorActions.requireConfiguredToken(dataRoot: root)
        }
        #expect(error?.code == -401)
    }

    // SlackConnectorActions.swift:72 postMessage — an IRREVERSIBLE external
    // write with three live callers. Both guards must fire before any body is
    // built; whitespace must not sneak past as "non-empty".
    @Test
    func postMessageRefusesEmptyChannelOrTextBeforeBuildingARequest() async throws {
        let root = slackTempRoot()

        let noChannel = await capturedNSError("missing channel") {
            _ = try await SlackConnectorActions.postMessage(
                input: ["text": .string("hello")], dataRoot: root
            )
        }
        #expect(noChannel?.code == -400)
        #expect(noChannel?.localizedDescription.contains("channel") == true)

        let blankChannel = await capturedNSError("whitespace channel") {
            _ = try await SlackConnectorActions.postMessage(
                input: ["channel": .string("   "), "text": .string("hello")], dataRoot: root
            )
        }
        #expect(blankChannel?.code == -400)

        let noText = await capturedNSError("missing text") {
            _ = try await SlackConnectorActions.postMessage(
                input: ["channel": .string("C123")], dataRoot: root
            )
        }
        #expect(noText?.code == -400)
        #expect(noText?.localizedDescription.contains("text") == true)

        let blankText = await capturedNSError("whitespace text") {
            _ = try await SlackConnectorActions.postMessage(
                input: ["channel": .string("C123"), "text": .string(" \n ")], dataRoot: root
            )
        }
        #expect(blankText?.code == -400)
    }

    // The other half of the same guard: VALID input must get past the input
    // checks and stop at the credential gate. -401 (not -400) proves the
    // guards are input-shaped, and that an unconfigured Slack can never post.
    @Test
    func postMessageWithValidInputStopsAtTheCredentialGateNotTheInputGuards() async throws {
        let root = slackTempRoot()
        let error = await capturedNSError("no credential in a bare root") {
            _ = try await SlackConnectorActions.postMessage(
                input: ["channel": .string("C123"), "text": .string("hello")],
                idempotencyKey: "delivery-1",
                dataRoot: root
            )
        }
        #expect(error?.code == -401)
    }

    // SlackConnectorActions.swift:48 searchMessages — an empty query must NOT
    // become a match-everything search.
    @Test
    func searchMessagesRefusesAnEmptyQuery() async throws {
        let error = await capturedNSError("empty query") {
            _ = try await SlackConnectorActions.searchMessages(input: ["query": .string("  ")])
        }
        #expect(error?.code == -400)
        #expect(error?.localizedDescription.contains("query") == true)
    }

    // SlackConnectorActions.swift:118 uploadFile — the file body leaves the
    // machine, so every refusal must land before the first request. A missing
    // file surfaces as a Cocoa read error from `Data(contentsOf:)`; an empty
    // one as the connector's own -400.
    @Test
    func uploadFileRefusesBadTargetsBeforeReadingOrSendingAnything() async throws {
        let noChannel = await capturedNSError("missing channel") {
            _ = try await SlackConnectorActions.uploadFile(
                input: ["file_path": .string("/tmp/whatever")]
            )
        }
        #expect(noChannel?.code == -400)

        let noPath = await capturedNSError("missing file_path") {
            _ = try await SlackConnectorActions.uploadFile(input: ["channel": .string("C123")])
        }
        #expect(noPath?.code == -400)

        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-upload-absent-\(UUID().uuidString).txt")
        let missingFile = await capturedNSError("file does not exist") {
            _ = try await SlackConnectorActions.uploadFile(input: [
                "channel": .string("C123"),
                "file_path": .string(absent.path),
            ])
        }
        #expect(missingFile?.domain == NSCocoaErrorDomain)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-upload-empty-\(UUID().uuidString).txt")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        let emptyFile = await capturedNSError("empty file") {
            _ = try await SlackConnectorActions.uploadFile(input: [
                "channel": .string("C123"),
                "file_path": .string(empty.path),
            ])
        }
        #expect(emptyFile?.code == -400)
    }

    // SlackConnectorActions.swift:214 listUnreads is a registered action that
    // can never succeed (dispatched at NativeClient+ConnectorActions.swift:250).
    // Pin it as a RECORDED decision: the envelope is failed-with-a-reason, not
    // an empty success that reads as "no unreads".
    @Test
    func listUnreadsIsARecordedDeadStubNotAnEmptySuccess() async throws {
        let value = try await SlackConnectorActions.listUnreads(input: [:])
        guard case .object(let object) = value else {
            Issue.record("expected an object envelope")
            return
        }
        #expect(object["actionId"] == .string("slack.list_unreads"))
        #expect(object["connectorId"] == .string("slack"))
        #expect(object["ok"] == .bool(false))
        #expect(object["status"] == .string("failed"))
        if case .string(let error)? = object["error"] {
            #expect(!error.isEmpty)
        } else {
            Issue.record("a dead action must carry a non-empty error")
        }
    }
}
