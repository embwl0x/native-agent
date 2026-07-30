import Foundation
import Testing
import ApprovalInbox
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter
@testable import NativeAgentApp

private actor ExternalSendCapture {
    private(set) var slackCalls: [(input: [String: JSONValue], key: String)] = []
    private(set) var agentMailCalls: [(input: [String: JSONValue], key: String)] = []
    var slackResult: ExternalSendProviderOutcome = .providerAccepted("1700000000.1")
    var agentMailResult: ExternalSendProviderOutcome = .providerAccepted("mail-1")

    func sendSlack(_ input: [String: JSONValue], key: String) -> ExternalSendProviderOutcome {
        slackCalls.append((input, key))
        return slackResult
    }

    func sendAgentMail(_ input: [String: JSONValue], key: String) -> ExternalSendProviderOutcome {
        agentMailCalls.append((input, key))
        return agentMailResult
    }

    func setSlackResult(_ result: ExternalSendProviderOutcome) { slackResult = result }
    func setAgentMailResult(_ result: ExternalSendProviderOutcome) { agentMailResult = result }
}

private func externalSendRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExternalSendExecution-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func externalSendDependencies(_ capture: ExternalSendCapture) -> ExternalSendExecutionDependencies {
    ExternalSendExecutionDependencies(
        slackSend: { input, key, _ in await capture.sendSlack(input, key: key) },
        agentMailSend: { input, key, _ in await capture.sendAgentMail(input, key: key) }
    )
}

private func writeExternalSendAgentMailConfig(_ root: URL) throws {
    let path = root
        .appendingPathComponent("secrets", isDirectory: true)
        .appendingPathComponent("agentmail.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONValue.object([
        "api_key": .string("test-key-not-copied-to-approval"),
        "inbox_id": .string("agent@example.test"),
    ]).serializedData(pretty: true).write(to: path)
}

private func resolvedSlackApproval(
    root: URL,
    decision: ApprovalDecision
) async throws -> ApprovalRecord {
    let staged = try await ExternalSendApprovalLifecycle.stage(
        invokedAs: "slack_post_message",
        input: [
            "channel": .string("C123"),
            "text": .string("private execution body"),
        ],
        surface: "chat",
        dataRoot: root
    )
    return try await SwiftNativeApprovalInbox(root: root).resolve(
        staged.approval.id,
        decision: decision,
        decidedBy: "test"
    )
}

private func clearExternalSendExecutionAnnotation(root: URL, id: String) async throws {
    let path = root
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
        .appendingPathComponent("requests.json")
    let persistence = SwiftNativePersistenceCore()
    try await persistence.withFileLock(path) {
        let raw = await persistence.readJSON(path, defaultValue: .array([]))
        guard case .array(var rows) = raw else { return }
        for index in rows.indices {
            guard case .object(var object) = rows[index],
                  object["id"] == .string(id) else { continue }
            object["executedAction"] = nil
            object["detail"] = nil
            rows[index] = .object(object)
        }
        try await persistence.writeJSON(.array(rows), to: path)
    }
}

private func writeLegacyTerminalReceiptBeyondFormerTailWindow(
    record: ApprovalRecord,
    root: URL
) throws {
    let replay = try #require(ExternalSendApprovalRequest(record: record))
    let terminal: JSONValue = .object([
        "id": .string(UUID().uuidString.lowercased()),
        "kind": .string("external_send_execution"),
        "approvalId": .string(record.id),
        "connectorId": .string(replay.connectorID),
        "actionId": .string(replay.actionID),
        "idempotencyKey": .string(replay.idempotencyKey),
        "status": .string("succeeded"),
        "ok": .bool(true),
        "didDispatch": .bool(true),
        "output": .object(["status": .string("succeeded")]),
    ])
    var lines = [try terminal.serialize(pretty: false)]
    lines.reserveCapacity(1_002)
    for index in 0...1_000 {
        lines.append(try JSONValue.object([
            "id": .string("unrelated-\(index)"),
            "kind": .string("connector_action"),
            "status": .string("completed"),
        ]).serialize(pretty: false))
    }
    let path = NativeClient.externalSendReceiptsPath(dataRoot: root)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)
}

@Test func connectorDispatchStagesReplayableSlackApprovalBeforeAnyNetworkCall() async throws {
    let root = try externalSendRoot("connector-dispatch")
    defer { try? FileManager.default.removeItem(at: root) }
    let receipt = try await NativeClient(baseURL: "").runConnectorAction(
        id: "slack.post_message",
        dryRun: false,
        input: [
            "channel": .string("C123"),
            "text": .string("connector dispatch private body"),
        ],
        dataRoot: root
    )

    #expect(receipt.status == "pending_approval")
    let approvalID = try #require(receipt.approvalId)
    let record = try await SwiftNativeApprovalInbox(root: root).get(approvalID)
    let replay = try #require(ExternalSendApprovalRequest(record: record))
    #expect(replay.actionID == "slack.post_message")
    #expect(replay.surface == "connector_action")
    #expect(replay.input["text"] == .string("connector dispatch private body"))
}

@Test func externalSendRoutingIgnoresDriftedRequiresApprovalMetadata() async throws {
    let root = try externalSendRoot("descriptor-drift")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeExternalSendAgentMailConfig(root)

    for actionID in ["slack.post_message", "agentmail.send"] {
        var descriptor = try #require(
            connectorActionDescriptors().first(where: { $0.id == actionID })
        )
        descriptor.requiresApproval = false
        let input: [String: JSONValue]
        if actionID == "slack.post_message" {
            input = [
                "channel": .string("C123"),
                "text": .string("must remain approval staged"),
            ]
        } else {
            input = [
                "to": .string("recipient@example.test"),
                "subject": .string("Approval invariant"),
                "text": .string("must remain approval staged"),
            ]
        }

        let receipt = try await NativeClient(baseURL: "").runConnectorAction(
            descriptor: descriptor,
            dryRun: false,
            input: input,
            dataRoot: root
        )

        #expect(receipt.status == "pending_approval")
        let approvalID = try #require(receipt.approvalId)
        let record = try await SwiftNativeApprovalInbox(root: root).get(approvalID)
        let replay = try #require(ExternalSendApprovalRequest(record: record))
        #expect(replay.actionID == actionID)
    }
}

@Test func deniedExternalSendNeverDispatchesAndRecordsTerminalNoDispatchReceipt() async throws {
    let root = try externalSendRoot("deny")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .denied)
    let capture = ExternalSendCapture()

    let outcome = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: externalSendDependencies(capture)
    )

    #expect(outcome.status == "denied")
    #expect(!outcome.didDispatch)
    #expect(outcome.shouldArchiveVisibleCard)
    #expect(await capture.slackCalls.isEmpty)
    let annotated = try await SwiftNativeApprovalInbox(root: root).get(record.id)
    #expect(annotated.detail?.contains("no connector call ran") == true)
    let receipts = try await SwiftNativePersistenceCore().readJSONL(
        NativeClient.externalSendReceiptsPath(dataRoot: root)
    )
    #expect(receipts.count == 1)
    guard case .object(let receipt) = receipts[0] else {
        Issue.record("expected terminal receipt")
        return
    }
    #expect(receipt["status"] == .string("denied"))
    #expect(receipt["didDispatch"] == .bool(false))
}

@Test func approvedExternalSendDispatchesExactlyOnce() async throws {
    let root = try externalSendRoot("approve-once")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    let dependencies = externalSendDependencies(capture)

    let first = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    let second = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )

    #expect(first.status == "providerAccepted")
    #expect(first.didDispatch)
    #expect(first.shouldArchiveVisibleCard)
    #expect(second.status == "providerAccepted")
    #expect(!second.didDispatch)
    let calls = await capture.slackCalls
    #expect(calls.count == 1)
    let replay = try #require(ExternalSendApprovalRequest(record: record))
    #expect(calls[0].key == replay.idempotencyKey)
    #expect(calls[0].input == replay.input)
    let indexPath = try #require(
        NativeClient.externalSendReceiptIndexPath(approvalID: record.id, dataRoot: root)
    )
    #expect(FileManager.default.fileExists(atPath: indexPath.path))
}

@Test func approvedAgentMailAliasUsesTheSameExactlyOnceExecutor() async throws {
    let root = try externalSendRoot("agentmail-approve-once")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeExternalSendAgentMailConfig(root)
    let staged = try await ExternalSendApprovalLifecycle.stage(
        invokedAs: "agentmail_send",
        input: [
            "to": .string("recipient@example.test"),
            "subject": .string("Approved subject"),
            "body": .string("private AgentMail execution body"),
        ],
        surface: "chat",
        dataRoot: root
    )
    let record = try await SwiftNativeApprovalInbox(root: root).resolve(
        staged.approval.id,
        decision: .approved,
        decidedBy: "test"
    )
    let capture = ExternalSendCapture()
    let dependencies = externalSendDependencies(capture)

    _ = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    _ = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )

    let calls = await capture.agentMailCalls
    #expect(calls.count == 1)
    #expect(await capture.slackCalls.isEmpty)
    let replay = try #require(ExternalSendApprovalRequest(record: record))
    #expect(replay.actionID == "agentmail.send")
    #expect(replay.invokedAs == "agentmail_send")
    #expect(calls[0].key == replay.idempotencyKey)
    #expect(calls[0].input == replay.input)
}

@Test func relaunchReceiptHealsMissingAnnotationWithoutRedispatch() async throws {
    let root = try externalSendRoot("relaunch")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    let dependencies = externalSendDependencies(capture)

    _ = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    try await clearExternalSendExecutionAnnotation(root: root, id: record.id)
    let replayed = try await SwiftNativeApprovalInbox(root: root).get(record.id)
    #expect(replayed.executedAction == nil)

    await NativeClient.reconcileUnappliedApprovalExecutions(
        dataRoot: root,
        kinds: [NativeClient.ApprovalExecutionReconcileKind(
            action: ExternalSendApprovalRequest.approvalAction,
            shouldReconcile: { _ in true },
            execute: { record in
                _ = await NativeClient.applyResolvedExternalSend(
                    from: record,
                    dataRoot: root,
                    dependencies: dependencies
                )
            }
        )]
    )

    #expect(await capture.slackCalls.count == 1)
    let annotated = try await SwiftNativeApprovalInbox(root: root).get(record.id)
    #expect(annotated.detail?.contains("not repeated") == true)
}

@Test func legacyTerminalReceiptBeyondFormerTailWindowHealsWithoutRedispatch() async throws {
    let root = try externalSendRoot("legacy-receipt-full-scan")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    try writeLegacyTerminalReceiptBeyondFormerTailWindow(record: record, root: root)
    let capture = ExternalSendCapture()

    let outcome = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: externalSendDependencies(capture)
    )

    #expect(outcome.status == "succeeded")
    #expect(!outcome.didDispatch)
    #expect(outcome.shouldArchiveVisibleCard)
    #expect(await capture.slackCalls.isEmpty)
    let annotated = try await SwiftNativeApprovalInbox(root: root).get(record.id)
    #expect(annotated.detail?.contains("not repeated") == true)
    let indexPath = try #require(
        NativeClient.externalSendReceiptIndexPath(approvalID: record.id, dataRoot: root)
    )
    #expect(FileManager.default.fileExists(atPath: indexPath.path))
}

@Test func failedApprovedSendIsTerminalHonestRedactedAndNotArchivedAsSuccess() async throws {
    let root = try externalSendRoot("failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    await capture.setSlackResult(.remoteRejected(
        "private execution body xoxb-12345678901234567890-secret"
    ))
    let dependencies = externalSendDependencies(capture)

    let first = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    let second = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )

    #expect(first.status == "remoteRejected")
    #expect(first.didDispatch)
    #expect(!first.shouldArchiveVisibleCard)
    #expect(second.status == "remoteRejected")
    #expect(!second.didDispatch)
    #expect(await capture.slackCalls.count == 1)
    let annotated = try await SwiftNativeApprovalInbox(root: root).get(record.id)
    #expect(annotated.detail?.contains("rejected by the provider") == true)
    #expect(annotated.detail?.contains("xoxb-") == false)
    let receiptText = try String(
        contentsOf: NativeClient.externalSendReceiptsPath(dataRoot: root),
        encoding: .utf8
    )
    #expect(!receiptText.contains("private execution body"))
    #expect(!receiptText.contains("xoxb-"))
}

@Test func providerAcceptanceClassifiersRequireConnectorSpecificProof() throws {
    let slackAccepted = ExternalSendProviderOutcome.classifySlack(.object([
        "status": .string("completed"),
        "response": .object(["ok": .bool(true), "ts": .string("1700000000.2")]),
    ]))
    #expect(slackAccepted == .providerAccepted("1700000000.2"))

    let slackMissingTimestamp = ExternalSendProviderOutcome.classifySlack(.object([
        "status": .string("completed"),
        "response": .object(["ok": .bool(true)]),
    ]))
    #expect(slackMissingTimestamp.state == .outcomeUnknown)

    let slackRejected = ExternalSendProviderOutcome.classifySlack(.object([
        "status": .string("failed"),
        "response": .object(["ok": .bool(false), "error": .string("channel_not_found")]),
    ]))
    #expect(slackRejected == .remoteRejected("channel_not_found"))

    let agentMailAccepted = ExternalSendProviderOutcome.classifyAgentMail(.object([
        "status": .string("succeeded"),
        "messageId": .string("mail-accepted-1"),
    ]))
    #expect(agentMailAccepted == .providerAccepted("mail-accepted-1"))

    let agentMailMissingID = ExternalSendProviderOutcome.classifyAgentMail(.object([
        "status": .string("succeeded"),
        "messageId": .string(""),
    ]))
    #expect(agentMailMissingID.state == .outcomeUnknown)

    let agentMailRejected = ExternalSendProviderOutcome.classifyAgentMail(.object([
        "status": .string("failed"),
        "error": .string("http_422"),
    ]))
    #expect(agentMailRejected == .remoteRejected("http_422"))
}

@Test func slackTimeoutOutcomeNeverAutoReplays() async throws {
    // 2026-07-21 audit (HIGH): Slack's Web API accepts client_msg_id but
    // does NOT dedupe on it — auto-replaying an approved ambiguous send
    // double-posts. The executor must suppress the replay and preserve
    // ambiguity (mirroring the cancel-after-start branch).
    let root = try externalSendRoot("slack-timeout-no-replay")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    await capture.setSlackResult(.outcomeUnknown("timeout"))
    let dependencies = externalSendDependencies(capture)

    let timedOut = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    #expect(timedOut.status == "outcomeUnknown")
    #expect(timedOut.didDispatch)
    #expect(!timedOut.shouldArchiveVisibleCard)

    let readWhileUnknown = try await ExternalSendMotorActionReadModelProvider(dataRoot: root)
        .motorActionReadModel(actionId: record.id)
    #expect(readWhileUnknown?.phase == .waitingExternal)
    #expect(readWhileUnknown?.verification == .unknown)

    await capture.setSlackResult(.providerAccepted("1700000000.3"))
    let replayed = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    #expect(replayed.status == "outcomeUnknown")
    #expect(!replayed.didDispatch)
    #expect(!replayed.shouldArchiveVisibleCard)
    let calls = await capture.slackCalls
    #expect(calls.count == 1, "ambiguous Slack send must never auto-replay — that double-posts")
    let annotated = try await SwiftNativeApprovalInbox(root: root).get(record.id)
    #expect(annotated.detail?.contains("automatic replay suppressed") == true)
}

@Test func agentMailTimeoutOutcomeReplaysWithTheSameApprovedIdempotencyKey() async throws {
    // AgentMail is the exemption to the Slack no-replay rule: its real
    // Idempotency-Key header makes an approved replay safe, so the path
    // stays byte-identical to the pre-audit behavior.
    let root = try externalSendRoot("agentmail-timeout-replay")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeExternalSendAgentMailConfig(root)
    let staged = try await ExternalSendApprovalLifecycle.stage(
        invokedAs: "agentmail_send",
        input: [
            "to": .string("recipient@example.test"),
            "subject": .string("Approved subject"),
            "body": .string("private AgentMail execution body"),
        ],
        surface: "chat",
        dataRoot: root
    )
    let record = try await SwiftNativeApprovalInbox(root: root).resolve(
        staged.approval.id,
        decision: .approved,
        decidedBy: "test"
    )
    let capture = ExternalSendCapture()
    await capture.setAgentMailResult(.outcomeUnknown("timeout"))
    let dependencies = externalSendDependencies(capture)

    let timedOut = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    #expect(timedOut.status == "outcomeUnknown")
    #expect(timedOut.didDispatch)

    await capture.setAgentMailResult(.providerAccepted("mail-2"))
    let replayed = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    #expect(replayed.status == "providerAccepted")
    let calls = await capture.agentMailCalls
    #expect(calls.count == 2)
    #expect(calls[0].key == calls[1].key)
    #expect(calls[0].input == calls[1].input)
    #expect(await capture.slackCalls.isEmpty)
}

@Test func localPreDispatchFailureNeverClaimsAProviderRequestStarted() async throws {
    let root = try externalSendRoot("pre-dispatch")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    await capture.setSlackResult(.preDispatchFailed("connector_preflight_failed"))

    let outcome = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: externalSendDependencies(capture)
    )

    #expect(outcome.status == "preDispatchFailed")
    #expect(!outcome.didDispatch)
    let model = try await ExternalSendMotorActionReadModelProvider(dataRoot: root)
        .motorActionReadModel(actionId: record.id)
    #expect(model?.phase == .blocked)
    #expect(model?.verification == .notStarted)
}

@Test func slackProcessInterruptionRestoresUnknownAndNeverAutoReplays() async throws {
    // Same 2026-07-21 audit rule across a simulated relaunch: the restored
    // ambiguous receipt must not mint a second Slack request.
    let root = try externalSendRoot("crash-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    await capture.setSlackResult(.outcomeUnknown("process_interrupted"))
    let dependencies = externalSendDependencies(capture)

    _ = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    await NativeClient.resetExternalSendReceiptCacheForTesting(dataRoot: root)
    await capture.setSlackResult(.providerAccepted("1700000000.4"))

    let restored = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    #expect(restored.status == "outcomeUnknown")
    #expect(!restored.didDispatch)
    let calls = await capture.slackCalls
    #expect(calls.count == 1, "restored ambiguous Slack receipt must never auto-replay")
}

@Test func concurrentDuplicateApplyDispatchesOneAcceptedRequest() async throws {
    let root = try externalSendRoot("concurrent-duplicate")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    let dependencies = ExternalSendExecutionDependencies(
        slackSend: { input, key, _ in
            let result = await capture.sendSlack(input, key: key)
            try? await Task.sleep(for: .milliseconds(50))
            return result
        },
        agentMailSend: { input, key, _ in await capture.sendAgentMail(input, key: key) }
    )

    async let first = NativeClient.applyResolvedExternalSend(
        from: record, dataRoot: root, dependencies: dependencies
    )
    async let second = NativeClient.applyResolvedExternalSend(
        from: record, dataRoot: root, dependencies: dependencies
    )
    let (firstOutcome, secondOutcome) = await (first, second)
    let outcomes = [firstOutcome, secondOutcome]

    #expect(outcomes.contains { $0.status == "providerAccepted" })
    #expect(outcomes.allSatisfy {
        ["providerAccepted", "outcomeUnknown"].contains($0.status)
    })
    #expect(outcomes.filter(\.didDispatch).count == 1)
    #expect(await capture.slackCalls.count == 1)
}

@Test func canceledApprovalIsExactOnlyBeforeRequestStart() async throws {
    let root = try externalSendRoot("cancel-before-start")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .canceled)
    let capture = ExternalSendCapture()

    let outcome = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: externalSendDependencies(capture)
    )

    #expect(outcome.status == "canceled")
    #expect(!outcome.didDispatch)
    #expect(await capture.slackCalls.isEmpty)
}

@Test func cancellationAfterRequestStartRemainsOutcomeUnknown() async throws {
    let root = try externalSendRoot("cancel-after-start")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    let dependencies = ExternalSendExecutionDependencies(
        slackSend: { input, key, _ in
            _ = await capture.sendSlack(input, key: key)
            do {
                try await Task.sleep(for: .seconds(10))
                return .providerAccepted("should-not-complete")
            } catch {
                return .outcomeUnknown("local_cancellation")
            }
        },
        agentMailSend: { input, key, _ in await capture.sendAgentMail(input, key: key) }
    )
    let task = Task {
        await NativeClient.applyResolvedExternalSend(
            from: record,
            dataRoot: root,
            dependencies: dependencies
        )
    }
    for _ in 0..<200 {
        if !(await capture.slackCalls.isEmpty) { break }
        await Task.yield()
    }
    task.cancel()
    let outcome = await task.value

    #expect(outcome.status == "outcomeUnknown")
    #expect(outcome.didDispatch)
    #expect(!outcome.shouldArchiveVisibleCard)
}

@Test func corruptReceiptIndexCannotRepeatAProvenAcceptedSend() async throws {
    let root = try externalSendRoot("corrupt-index")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    let dependencies = externalSendDependencies(capture)
    _ = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    let indexPath = try #require(
        NativeClient.externalSendReceiptIndexPath(approvalID: record.id, dataRoot: root)
    )
    try Data("{corrupt".utf8).write(to: indexPath)
    await NativeClient.resetExternalSendReceiptCacheForTesting(dataRoot: root)

    let replay = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: dependencies
    )
    #expect(replay.status == "providerAccepted")
    #expect(!replay.didDispatch)
    #expect(await capture.slackCalls.count == 1)
}

@Test func externalSendMotorProjectionIsPayloadFreeAndAcceptanceIsNotDelivery() async throws {
    let root = try externalSendRoot("motor-privacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await resolvedSlackApproval(root: root, decision: .approved)
    let capture = ExternalSendCapture()
    _ = await NativeClient.applyResolvedExternalSend(
        from: record,
        dataRoot: root,
        dependencies: externalSendDependencies(capture)
    )

    let model = try #require(
        try await ExternalSendMotorActionReadModelProvider(dataRoot: root)
            .motorActionReadModel(actionId: record.id)
    )
    #expect(model.domain == "external_send")
    #expect(model.actionIdentity == CausalTransitionEvidence.opaqueIdentity(record.id))
    #expect(model.phase == .succeeded)
    #expect(model.verification == .unverified)
    #expect(model.expectedNextEvidence?.contains("delivery and read remain unknown") == true)
    let encoded = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
    #expect(!encoded.contains("private execution body"))
    #expect(!encoded.contains("C123"))

    let indexPath = try #require(
        NativeClient.externalSendReceiptIndexPath(approvalID: record.id, dataRoot: root)
    )
    let receiptData = try Data(contentsOf: indexPath)
    let receiptText = String(decoding: receiptData, as: UTF8.self)
    let receipt = try JSONValue.parse(receiptData)
    guard case .object(let receiptObject) = receipt,
          case .object(let output)? = receiptObject["output"] else {
        Issue.record("expected payload-free external-send lifecycle receipt")
        return
    }
    #expect(output["delivery"] == .string("unknown"))
    #expect(output["read"] == .string("unknown"))
    #expect(!receiptText.contains("private execution body"))
    #expect(!receiptText.contains("C123"))
}
