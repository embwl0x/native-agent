import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

private enum SlackFeedOutboundMode: Sendable {
    case rejected
    case transportFailure
    case accepted
}

private struct SlackFeedTransportFailure: Error {}

private actor SlackFeedOutboundProbe {
    private var mode: SlackFeedOutboundMode = .rejected

    func setMode(_ next: SlackFeedOutboundMode) { mode = next }

    func post(_ input: [String: JSONValue]) throws -> JSONValue {
        switch mode {
        case .rejected:
            .object(["ok": .bool(false), "error": .string("channel_not_found")])
        case .transportFailure:
            throw SlackFeedTransportFailure()
        case .accepted:
            .object(["ok": .bool(true), "ts": .string("10.000")])
        }
    }
}

private func slackFeedEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SlackReceiptErrorFeedEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func slackFeedConfig() -> SlackSocketModeConfig {
    SlackSocketModeConfig(
        botToken: "xoxb-test",
        appToken: "xapp-test",
        botUserId: "UBOT",
        teamId: "T1",
        enabled: true,
        historyPollEnabled: false,
        historyPollInterval: 60,
        historyConversationRefreshInterval: 600,
        allowedChannelIds: [],
        allowedUserIds: [],
        requireMention: true
    )
}

private func slackFeedInbound(_ suffix: Int) -> SlackInboundMessage {
    SlackInboundMessage(
        eventId: "T1:C1:\(suffix).000",
        teamId: "T1",
        channelId: "C1",
        userId: "U1",
        eventType: "message",
        text: "reply please",
        ts: "\(suffix).000",
        threadTs: nil,
        channelType: "channel",
        isDirectMessage: false
    )
}

// EVAL FENCE: app.bridges / slack.errors.feed
@Suite("Slack receipts and errors feed")
struct SlackReceiptErrorFeedEvalTests {
    @Test("ratio and stale-receipt leads are ranked from the same read model")
    func reportRanksGrowingErrorsAgainstFrozenReceipts() {
        let receipts: [JSONValue] = [
            .object(["at": .string("2026-08-20T00:00:00.000Z")])
        ]
        let errors: [JSONValue] = (0..<4).map { index in
            .object([
                "at": .string("2026-08-24T00:00:0\(index).000Z"),
                "context": .string(index == 3 ? "post_reply" : "socket_mode"),
                "errorClass": .string(index == 3 ? "runtime_error" : "slack_api"),
            ])
        }
        let retention = SlackReceiptErrorFeed.Retention(maxLines: 4, maxBytes: 512, trimToBytes: 384)
        let report = SlackReceiptErrorFeed.report(
            receiptRows: receipts,
            errorRows: errors,
            receiptBytes: 120,
            errorBytes: 480,
            now: ISO8601DateFormatter().date(from: "2026-08-24T00:01:00Z")!,
            window: 24 * 60 * 60,
            retention: retention
        )

        #expect(report.errorToReceiptRatio == 4.0)
        #expect(report.receiptRowsInWindow == 0)
        #expect(report.errorRowsInWindow == 4)
        #expect(report.contextRates == [
            .init(context: "socket_mode", rows: 3, ratePerDay: 3),
            .init(context: "post_reply", rows: 1, ratePerDay: 1),
        ])
        #expect(report.rankedErrorLeads.first == .init(
            context: "socket_mode", errorClass: "slack_api", rows: 3
        ))
        #expect(report.errorsAreAtRetentionCap)
        #expect(report.rankedLeads.contains("errors_feed_at_retention_cap_ring"))
        #expect(report.rankedLeads.contains("errors_to_receipts_ratio_exceeds_envelope"))
        #expect(report.rankedLeads.contains("receipts_frozen_while_errors_grow"))
    }

    @Test("rejected and failed sends remain visible, bounded, and recover with a receipt")
    func recordsErrorsWithoutLosingTheFrozenReceiptLead() async throws {
        let root = try slackFeedEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SlackFeedOutboundProbe()
        let retention = SlackReceiptErrorFeed.Retention(maxLines: 20, maxBytes: 512, trimToBytes: 384)
        let loop = SlackSocketModeLoop(
            config: slackFeedConfig(),
            dataRoot: root,
            outbound: SlackSocketModeOutbound(
                postMessage: { input in try await probe.post(input) },
                uploadFile: { input in try await probe.post(input) }
            ),
            feedRetention: retention,
            chatHandler: { _ in SlackSocketModeReply(text: "A reply") }
        )

        #expect(await loop.handleInbound(slackFeedInbound(1)) == false)
        await probe.setMode(.transportFailure)
        #expect(await loop.handleInbound(slackFeedInbound(2)) == false)

        guard case .measured(let failed) = await SlackReceiptErrorFeed.read(dataRoot: root, retention: retention) else {
            Issue.record("expected the Slack error feed after failed delivery")
            return
        }
        #expect(failed.receiptCount == 0)
        #expect(failed.errorCount > 0)
        #expect(failed.errorRowsInWindow > 0)
        #expect(failed.errorBytes <= retention.maxBytes)
        #expect(failed.rankedErrorLeads.contains {
            $0.context == "post_reply" && $0.errorClass == "slack_api"
        })
        #expect(failed.rankedLeads.contains("receipts_frozen_while_errors_grow"))

        await probe.setMode(.accepted)
        #expect(await loop.handleInbound(slackFeedInbound(3)))
        guard case .measured(let recovered) = await SlackReceiptErrorFeed.read(dataRoot: root, retention: retention) else {
            Issue.record("expected the Slack receipt feed after a successful delivery")
            return
        }
        #expect(recovered.receiptCount == 1)
        #expect(recovered.receiptRowsInWindow == 1)
        #expect(recovered.errorBytes <= retention.maxBytes)
        #expect(recovered.newestReceiptAt != nil)
        #expect(recovered.newestErrorAt != nil)
    }

    @Test("accepted replies become observable receipts through the real loop and bounded store")
    func acceptedReplyIsObservableAndReceiptRetentionStaysBounded() async throws {
        let root = try slackFeedEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SlackFeedOutboundProbe()
        await probe.setMode(.accepted)
        let retention = SlackReceiptErrorFeed.Retention(maxLines: 30, maxBytes: 350, trimToBytes: 220)
        let loop = SlackSocketModeLoop(
            config: slackFeedConfig(),
            dataRoot: root,
            outbound: SlackSocketModeOutbound(
                postMessage: { input in try await probe.post(input) },
                uploadFile: { input in try await probe.post(input) }
            ),
            feedRetention: retention,
            chatHandler: { _ in SlackSocketModeReply(text: "A reply") }
        )

        #expect(await loop.handleInbound(slackFeedInbound(1)))
        guard case .measured(let firstReceipt) = await SlackReceiptErrorFeed.read(dataRoot: root) else {
            Issue.record("accepted Slack reply must produce an observable receipt")
            return
        }
        #expect(firstReceipt.receiptCount == 1)
        #expect(firstReceipt.errorCount == 0)
        #expect(firstReceipt.newestReceiptAt != nil)

        let receiptsPath = root
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        for index in 2...6 {
            try await SlackReceiptErrorFeed.append(
                .object([
                    "at": .string("2026-08-24T12:00:0\(index)Z"),
                    "kind": .string("reply"),
                    "payload": .string(String(repeating: "x", count: 120)),
                ]),
                to: receiptsPath,
                using: SwiftNativePersistenceCore(),
                retention: retention,
                label: "SlackReceiptErrorFeedEvalTests"
            )
        }
        guard case .measured(let bounded) = await SlackReceiptErrorFeed.read(dataRoot: root) else {
            Issue.record("bounded receipt feed must remain observable")
            return
        }
        #expect(bounded.receiptBytes <= retention.maxBytes)
        #expect(bounded.receiptCount < 6)
    }

    @Test("partial and structurally unavailable receipt feeds do not claim an empty healthy measurement")
    func malformedAndUnavailableFeedsAreHonest() async throws {
        let partialRoot = try slackFeedEvalRoot()
        defer { try? FileManager.default.removeItem(at: partialRoot) }
        let partialPath = partialRoot
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        try FileManager.default.createDirectory(at: partialPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"at\":\"2026-08-24T12:00:00Z\"}\nnot-json\n{\"at\":\"2026-08-24T12:00:01Z\"}\n".utf8)
            .write(to: partialPath, options: .atomic)

        guard case .partial(let partial) = await SlackReceiptErrorFeed.read(dataRoot: partialRoot) else {
            Issue.record("malformed physical receipt rows must remain observable as partial evidence")
            return
        }
        #expect(partial.receiptCount == 2)
        #expect(partial.receiptMalformedLineCount == 1)
        #expect(partial.rankedLeads.contains("receipts_feed_incomplete"))

        let blockedRoot = try slackFeedEvalRoot()
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        let blockedSlackRoot = blockedRoot.appendingPathComponent("slack")
        try Data("not a directory".utf8).write(to: blockedSlackRoot, options: .atomic)
        guard case .unavailable = await SlackReceiptErrorFeed.read(dataRoot: blockedRoot) else {
            Issue.record("a blocked Slack feed root must not masquerade as an absent, healthy feed")
            return
        }
    }
}
