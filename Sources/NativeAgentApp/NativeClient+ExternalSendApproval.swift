import Foundation
import Darwin
import ApprovalInbox
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import SlackConnector
import TrustCenter

struct ExternalSendExecutionDependencies: Sendable {
    let slackSend: @Sendable ([String: JSONValue], String, URL) async -> ExternalSendProviderOutcome
    let agentMailSend: @Sendable ([String: JSONValue], String, URL) async -> ExternalSendProviderOutcome

    static let production = ExternalSendExecutionDependencies(
        slackSend: { input, idempotencyKey, dataRoot in
            do {
                let result = try await SlackConnectorActions.postMessage(
                    input: input,
                    idempotencyKey: idempotencyKey,
                    dataRoot: dataRoot
                )
                return ExternalSendProviderOutcome.classifySlack(result)
            } catch let error as NSError
                where error.domain == "NativeAgentSlack" && [-400, -401].contains(error.code) {
                return .preDispatchFailed("connector_preflight_failed")
            } catch {
                // Once Slack's local preflight has passed, URLSession errors,
                // cancellation, and process interruption cannot prove whether
                // Slack received the request. Never turn ambiguity into failure.
                return .outcomeUnknown("transport_outcome_unknown")
            }
        },
        agentMailSend: { input, idempotencyKey, dataRoot in
            let result = await AgentMailActions.sendNow(
                input: input,
                approvalId: nil,
                idempotencyKey: idempotencyKey,
                dataRoot: dataRoot,
                recordReceipt: false
            )
            return ExternalSendProviderOutcome.classifyAgentMail(result)
        }
    )
}

enum ExternalSendLifecycleState: String, Sendable, Codable, CaseIterable {
    case preDispatchFailed
    case remoteRejected
    case providerAccepted
    case outcomeUnknown

    var requestStarted: Bool {
        self != .preDispatchFailed
    }

}

struct ExternalSendProviderOutcome: Sendable, Equatable {
    let state: ExternalSendLifecycleState
    let acceptanceID: String?
    let failureCode: String?

    static func preDispatchFailed(_ code: String) -> Self {
        Self(state: .preDispatchFailed, acceptanceID: nil, failureCode: code)
    }

    static func remoteRejected(_ code: String) -> Self {
        Self(state: .remoteRejected, acceptanceID: nil, failureCode: code)
    }

    static func providerAccepted(_ acceptanceID: String) -> Self {
        Self(state: .providerAccepted, acceptanceID: acceptanceID, failureCode: nil)
    }

    static func outcomeUnknown(_ code: String) -> Self {
        Self(state: .outcomeUnknown, acceptanceID: nil, failureCode: code)
    }

    /// Slack acceptance requires both its explicit `ok` bit and the message
    /// timestamp. HTTP completion or a generic `completed` envelope alone is
    /// not evidence that Slack accepted the message.
    static func classifySlack(_ result: JSONValue) -> Self {
        guard case .object(let root) = result,
              case .object(let response)? = root["response"] else {
            return .outcomeUnknown("missing_provider_response")
        }
        if case .bool(false)? = response["ok"] {
            return .remoteRejected(providerCode(response["error"]) ?? "provider_rejected")
        }
        guard case .bool(true)? = response["ok"],
              let timestamp = nonEmptyString(response["ts"]) else {
            return .outcomeUnknown("missing_acceptance_proof")
        }
        return .providerAccepted(String(timestamp.prefix(128)))
    }

    /// `AgentMailActions.sendNow` reaches `succeeded` only after a 2xx HTTP
    /// response. A nonempty provider message id is additionally required here;
    /// without both facts the result stays ambiguous.
    static func classifyAgentMail(_ result: JSONValue) -> Self {
        guard case .object(let root) = result else {
            return .outcomeUnknown("missing_provider_response")
        }
        let status = nonEmptyString(root["status"])?.lowercased()
        if status == "succeeded" {
            guard let messageID = nonEmptyString(root["messageId"] ?? root["message_id"]) else {
                return .outcomeUnknown("missing_acceptance_proof")
            }
            return .providerAccepted(String(messageID.prefix(256)))
        }

        let code = providerCode(root["error"]) ?? "connector_error"
        if code.hasPrefix("http_") {
            return .remoteRejected(code)
        }
        let preDispatchCodes: Set<String> = [
            "agentmail_not_configured", "agentmail_secret_invalid", "invalid_url",
            "missing_input", "input_too_large", "stale_sender", "invalid_replay_input",
        ]
        if preDispatchCodes.contains(code) {
            return .preDispatchFailed(code)
        }
        return .outcomeUnknown("transport_outcome_unknown")
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func providerCode(_ value: JSONValue?) -> String? {
        guard let raw = nonEmptyString(value)?.lowercased(), raw.utf8.count <= 96 else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return raw
    }
}

struct ExternalSendExecutionOutcome: Sendable, Equatable {
    let status: String
    let didDispatch: Bool
    let shouldArchiveVisibleCard: Bool
}

private actor ExternalSendApprovalExecutor {
    static let shared = ExternalSendApprovalExecutor()

    private static let validLifecycleStatuses: Set<String> = Set(
        ExternalSendLifecycleState.allCases.map(\.rawValue)
            + ["succeeded", "failed", "denied", "canceled"]
    )

    private struct ReceiptKey: Hashable {
        let approvalID: String
        let idempotencyKey: String
        let connectorID: String
        let actionID: String
    }

    private enum ReceiptIndexWriteResult {
        case created
        case updated
        case existing
        case failed
    }

    private enum CanonicalReceiptRead {
        case missing
        case valid(JSONValue)
        case unavailable
    }

    private struct ReceiptLookup {
        let receipt: JSONValue?
        let canonicalUnavailable: Bool
    }

    // A data root is loaded at most once. This keeps the unbounded legacy-log
    // fallback O(N) for a relaunch reconciliation pass instead of O(N^2).
    private var legacyReceiptIndexes: [String: [ReceiptKey: JSONValue]] = [:]
    // Actor methods are reentrant at suspension points. Keep one canonical
    // approval/idempotency execution in flight so concurrent apply calls can
    // observe ambiguity but can never duplicate the provider request.
    private var activeExecutions: Set<ReceiptKey> = []

    func apply(
        record: ApprovalRecord,
        dataRoot: URL,
        dependencies: ExternalSendExecutionDependencies
    ) async -> ExternalSendExecutionOutcome {
        guard record.action == ExternalSendApprovalRequest.approvalAction,
              record.status == "resolved",
              let decision = record.decision else {
            return ExternalSendExecutionOutcome(
                status: "invalid_approval",
                didDispatch: false,
                shouldArchiveVisibleCard: false
            )
        }

        guard let request = ExternalSendApprovalRequest(record: record) else {
            let summary: JSONValue = .object([
                "op": .string("external_send"),
                "status": .string(ExternalSendLifecycleState.preDispatchFailed.rawValue),
                "error": .string("malformed_replay_payload"),
            ])
            _ = await annotate(
                recordID: record.id,
                summary: summary,
                detail: "External send FAILED: malformed replay payload; no connector call ran.",
                dataRoot: dataRoot
            )
            return ExternalSendExecutionOutcome(
                status: ExternalSendLifecycleState.preDispatchFailed.rawValue,
                didDispatch: false,
                shouldArchiveVisibleCard: false
            )
        }

        let executionKey = ReceiptKey(
            approvalID: record.id,
            idempotencyKey: request.idempotencyKey,
            connectorID: request.connectorID,
            actionID: request.actionID
        )
        guard activeExecutions.insert(executionKey).inserted else {
            return ExternalSendExecutionOutcome(
                status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
                didDispatch: false,
                shouldArchiveVisibleCard: false
            )
        }
        defer { activeExecutions.remove(executionKey) }

        let receiptLookup = await lifecycleReceipt(
            request: request,
            approvalID: record.id,
            dataRoot: dataRoot
        )
        let currentReceipt = receiptLookup.receipt
        guard !receiptLookup.canonicalUnavailable else {
            _ = await annotate(
                recordID: record.id,
                summary: executionSummary(
                    request: request,
                    status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
                    receiptID: nil,
                    error: "authoritative_receipt_unavailable"
                ),
                detail: "\(request.actionID) was not dispatched because its authoritative execution receipt is unreadable or invalid. Repair that preserved receipt before retrying.",
                dataRoot: dataRoot
            )
            return ExternalSendExecutionOutcome(
                status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
                didDispatch: false,
                shouldArchiveVisibleCard: false
            )
        }
        let latestExecutedAction = try? await SwiftNativeApprovalInbox(root: dataRoot)
            .get(record.id).executedAction
        let settledStatus = currentReceipt.flatMap(Self.status)
            ?? latestExecutedAction.flatMap(Self.status)
        if let settledStatus, Self.isSettled(status: settledStatus) {
            let summary = executionSummary(
                request: request,
                status: settledStatus,
                receiptID: currentReceipt.flatMap { Self.string($0, key: "id") },
                error: currentReceipt.flatMap(Self.failureCode)
            )
            let annotated = await annotate(
                recordID: record.id,
                summary: summary,
                detail: healedDetail(actionID: request.actionID, status: settledStatus),
                dataRoot: dataRoot
            )
            return ExternalSendExecutionOutcome(
                status: settledStatus,
                didDispatch: false,
                shouldArchiveVisibleCard: Self.shouldArchive(status: settledStatus) && annotated
            )
        }

        if decision != "approved",
           let currentReceipt,
           Self.status(currentReceipt) == ExternalSendLifecycleState.outcomeUnknown.rawValue,
           Self.bool(currentReceipt, key: "didDispatch") == true {
            // A later local cancellation cannot retract a request that may
            // already have crossed the transport boundary. Preserve ambiguity
            // until provider proof arrives; never rewrite it as exact cancel.
            let summary = executionSummary(
                request: request,
                status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
                receiptID: Self.string(currentReceipt, key: "id"),
                error: Self.failureCode(currentReceipt)
            )
            _ = await annotate(
                recordID: record.id,
                summary: summary,
                detail: "\(request.actionID) was canceled after request start; provider outcome remains unknown.",
                dataRoot: dataRoot
            )
            return ExternalSendExecutionOutcome(
                status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
                didDispatch: false,
                shouldArchiveVisibleCard: false
            )
        }

        if decision == "approved",
           request.actionID == "slack.post_message",
           let currentReceipt,
           Self.status(currentReceipt) == ExternalSendLifecycleState.outcomeUnknown.rawValue,
           Self.bool(currentReceipt, key: "didDispatch") == true {
            // 2026-07-21 audit (HIGH): Slack's Web API accepts client_msg_id
            // but does NOT dedupe on it, so auto-replaying an approved
            // ambiguous send double-posts. Mirror the cancel-after-start
            // branch: preserve ambiguity and never auto-replay. Recovery is
            // an explicit human-verified retry (check conversations.history
            // first). AgentMail is exempt — its real Idempotency-Key header
            // makes replays safe, so its path below stays byte-identical.
            let summary = executionSummary(
                request: request,
                status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
                receiptID: Self.string(currentReceipt, key: "id"),
                error: Self.failureCode(currentReceipt)
            )
            _ = await annotate(
                recordID: record.id,
                summary: summary,
                detail: "\(request.actionID) prior dispatch outcome is unknown and Slack does not dedupe client_msg_id; "
                    + "automatic replay suppressed to avoid a double-post. Verify via conversations.history before any manual retry.",
                dataRoot: dataRoot
            )
            return ExternalSendExecutionOutcome(
                status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
                didDispatch: false,
                shouldArchiveVisibleCard: false
            )
        }

        guard decision == "approved" else {
            let status = decision == "denied" ? "denied" : "canceled"
            let receipt = terminalReceiptValue(
                request: request,
                approvalID: record.id,
                status: status,
                attempt: 0,
                didDispatch: false,
                output: .object(["status": .string(status)])
            )
            let receiptWritten = await appendLifecycleReceipt(receipt, dataRoot: dataRoot)
            let summary = executionSummary(
                request: request,
                status: status,
                receiptID: Self.string(receipt, key: "id"),
                error: nil
            )
            let annotated = await annotate(
                recordID: record.id,
                summary: summary,
                detail: "\(request.actionID) \(status); no connector call ran.",
                dataRoot: dataRoot
            )
            return ExternalSendExecutionOutcome(
                status: status,
                didDispatch: false,
                shouldArchiveVisibleCard: receiptWritten && annotated
            )
        }

        let security = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let envelope = await security.evaluateTool(
            tool: request.actionID,
            input: request.input,
            origin: SecurityOriginContext(
                surface: request.surface,
                sessionId: request.sessionID,
                userId: nil,
                chatId: request.remoteChatID,
                deviceId: nil,
                source: "approved_external_send",
                isRemote: Self.isRemoteSurface(request.surface),
                commandSignatureVerified: request.commandSignatureVerified
            ),
            enforceAutonomy: false
        )
        try? await security.record(envelope)
        if envelope.decision == .block {
            let reason = envelope.reasons.first(where: { !$0.hasPrefix("autonomy:") })
                ?? "security policy blocked approved send"
            return await finishFailureWithoutDispatch(
                record: record,
                request: request,
                error: reason,
                dataRoot: dataRoot
            )
        }

        let priorAttempt = currentReceipt.flatMap(Self.attempt) ?? 0
        let attempt = priorAttempt + 1
        // Persist ambiguity before handing the request to a transport. A crash
        // after this write can only replay the same approved input with the same
        // idempotency key; it cannot falsely claim failure or mint a new send.
        let requestStartedReceipt = terminalReceiptValue(
            request: request,
            approvalID: record.id,
            status: ExternalSendLifecycleState.outcomeUnknown.rawValue,
            attempt: attempt,
            didDispatch: true,
            output: lifecycleOutput(
                request: request,
                outcome: .outcomeUnknown("request_started_no_provider_proof")
            )
        )
        guard await appendLifecycleReceipt(requestStartedReceipt, dataRoot: dataRoot) else {
            return await finishUnpersistedPreDispatchFailure(
                record: record,
                request: request,
                dataRoot: dataRoot
            )
        }

        let providerOutcome: ExternalSendProviderOutcome
        switch request.actionID {
        case "slack.post_message":
            providerOutcome = await dependencies.slackSend(
                request.input,
                request.idempotencyKey,
                dataRoot
            )
        case "agentmail.send":
            providerOutcome = await dependencies.agentMailSend(
                request.input,
                request.idempotencyKey,
                dataRoot
            )
        default:
            providerOutcome = .preDispatchFailed("unsupported_action")
        }

        let status = providerOutcome.state.rawValue
        let safeOutput = lifecycleOutput(request: request, outcome: providerOutcome)
        let receipt = terminalReceiptValue(
            request: request,
            approvalID: record.id,
            status: status,
            attempt: attempt,
            didDispatch: providerOutcome.state.requestStarted,
            output: safeOutput
        )
        let receiptWritten = await appendLifecycleReceipt(receipt, dataRoot: dataRoot)
        let persistedStatus = receiptWritten
            ? status
            : ExternalSendLifecycleState.outcomeUnknown.rawValue
        let error = Self.failureCode(safeOutput)
        var summary = executionSummary(
            request: request,
            status: persistedStatus,
            receiptID: Self.string(receipt, key: "id"),
            error: error
        )
        var detail = lifecycleDetail(actionID: request.actionID, status: persistedStatus)
        if !receiptWritten {
            summary = .object([
                "op": .string("external_send"),
                "connectorId": .string(request.connectorID),
                "actionId": .string(request.actionID),
                "status": .string(ExternalSendLifecycleState.outcomeUnknown.rawValue),
                "error": .string("result_persistence_failed"),
            ])
            detail = "\(request.actionID) outcome remains unknown because result persistence failed; "
                + "any retry must preserve the approved idempotency key."
        }
        let annotated = await annotate(
            recordID: record.id,
            summary: summary,
            detail: detail,
            dataRoot: dataRoot
        )
        return ExternalSendExecutionOutcome(
            status: persistedStatus,
            didDispatch: providerOutcome.state.requestStarted,
            shouldArchiveVisibleCard: persistedStatus == ExternalSendLifecycleState.providerAccepted.rawValue
                && receiptWritten && annotated
        )
    }

    private func finishFailureWithoutDispatch(
        record: ApprovalRecord,
        request: ExternalSendApprovalRequest,
        error: String,
        dataRoot: URL
    ) async -> ExternalSendExecutionOutcome {
        let safeError = Self.safeFailureCode(error, fallback: "policy_pre_dispatch_failed")
        let status = ExternalSendLifecycleState.preDispatchFailed.rawValue
        let output = lifecycleOutput(
            request: request,
            outcome: .preDispatchFailed(safeError)
        )
        let receipt = terminalReceiptValue(
            request: request,
            approvalID: record.id,
            status: status,
            attempt: 0,
            didDispatch: false,
            output: output
        )
        _ = await appendLifecycleReceipt(receipt, dataRoot: dataRoot)
        let summary = executionSummary(
            request: request,
            status: status,
            receiptID: Self.string(receipt, key: "id"),
            error: safeError
        )
        _ = await annotate(
            recordID: record.id,
            summary: summary,
            detail: "\(request.actionID) failed before request start; no provider call ran.",
            dataRoot: dataRoot
        )
        return ExternalSendExecutionOutcome(
            status: status,
            didDispatch: false,
            shouldArchiveVisibleCard: false
        )
    }

    private func finishUnpersistedPreDispatchFailure(
        record: ApprovalRecord,
        request: ExternalSendApprovalRequest,
        dataRoot: URL
    ) async -> ExternalSendExecutionOutcome {
        let status = ExternalSendLifecycleState.preDispatchFailed.rawValue
        let summary = executionSummary(
            request: request,
            status: status,
            receiptID: nil,
            error: "request_start_persistence_failed"
        )
        _ = await annotate(
            recordID: record.id,
            summary: summary,
            detail: "\(request.actionID) did not start because replay state could not be persisted.",
            dataRoot: dataRoot
        )
        return ExternalSendExecutionOutcome(
            status: status,
            didDispatch: false,
            shouldArchiveVisibleCard: false
        )
    }

    private func annotate(
        recordID: String,
        summary: JSONValue,
        detail: String,
        dataRoot: URL
    ) async -> Bool {
        do {
            try await NativeClient.annotateApprovalExecution(
                id: recordID,
                executedAction: summary,
                detail: detail,
                root: dataRoot
            )
            return true
        } catch {
            return false
        }
    }

    private func lifecycleReceipt(
        request: ExternalSendApprovalRequest,
        approvalID: String,
        dataRoot: URL,
        allowLegacyAuditFallback: Bool = true
    ) async -> ReceiptLookup {
        let key = ReceiptKey(
            approvalID: approvalID,
            idempotencyKey: request.idempotencyKey,
            connectorID: request.connectorID,
            actionID: request.actionID
        )
        let persistence = SwiftNativePersistenceCore()
        if let indexPath = NativeClient.externalSendReceiptIndexPath(
            approvalID: approvalID,
            dataRoot: dataRoot
        ) {
            switch Self.readCanonicalReceipt(at: indexPath, expectedKey: key) {
            case .valid(let indexed):
                return ReceiptLookup(receipt: indexed, canonicalUnavailable: false)
            case .unavailable:
                // An existing private receipt is authoritative. It may never
                // be treated as absent or replaced from the legacy audit log.
                return ReceiptLookup(receipt: nil, canonicalUnavailable: true)
            case .missing:
                break
            }
        }

        guard allowLegacyAuditFallback else {
            return ReceiptLookup(receipt: nil, canonicalUnavailable: false)
        }

        let receiptsPath = NativeClient.externalSendReceiptsPath(dataRoot: dataRoot)
        let rootKey = receiptsPath.standardizedFileURL.path
        let receiptIndex: [ReceiptKey: JSONValue]
        if let cached = legacyReceiptIndexes[rootKey] {
            receiptIndex = cached
        } else {
            let rows = (try? await persistence.readJSONL(receiptsPath)) ?? []
            var built: [ReceiptKey: JSONValue] = [:]
            for row in rows {
                guard let rowKey = Self.receiptKey(row) else { continue }
                built[rowKey] = row
            }
            legacyReceiptIndexes[rootKey] = built
            receiptIndex = built
        }
        guard let receipt = receiptIndex[key] else {
            return ReceiptLookup(receipt: nil, canonicalUnavailable: false)
        }
        let imported = await persistReceiptIndex(receipt, dataRoot: dataRoot)
        guard imported != .failed else {
            return ReceiptLookup(receipt: nil, canonicalUnavailable: true)
        }
        return ReceiptLookup(receipt: receipt, canonicalUnavailable: false)
    }

    private static func readCanonicalReceipt(
        at path: URL,
        expectedKey: ReceiptKey
    ) -> CanonicalReceiptRead {
        var info = stat()
        if lstat(path.path, &info) != 0 {
            return errno == ENOENT ? .missing : .unavailable
        }
        do {
            let values = try path.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= 1_048_576 else {
                return .unavailable
            }
            let data = try Data(contentsOf: path, options: [.mappedIfSafe])
            let value = try JSONValue.parse(data)
            guard receiptKey(value) == expectedKey else { return .unavailable }
            return .valid(value)
        } catch {
            return .unavailable
        }
    }

    private static func receiptKey(_ receipt: JSONValue) -> ReceiptKey? {
        guard string(receipt, key: "kind") == "external_send_execution",
              let approvalID = string(receipt, key: "approvalId"),
              let idempotencyKey = string(receipt, key: "idempotencyKey"),
              let connectorID = string(receipt, key: "connectorId"),
              let actionID = string(receipt, key: "actionId"),
              let status = string(receipt, key: "status"),
              let didDispatch = bool(receipt, key: "didDispatch"),
              validLifecycleStatuses.contains(status),
              ![ExternalSendLifecycleState.providerAccepted.rawValue, "succeeded"].contains(status)
                || didDispatch,
              !["denied", "canceled"].contains(status) || !didDispatch else {
            return nil
        }
        return ReceiptKey(
            approvalID: approvalID,
            idempotencyKey: idempotencyKey,
            connectorID: connectorID,
            actionID: actionID
        )
    }

    private func appendLifecycleReceipt(_ receipt: JSONValue, dataRoot: URL) async -> Bool {
        guard let receiptKey = Self.receiptKey(receipt) else { return false }
        let indexResult = await persistReceiptIndex(receipt, dataRoot: dataRoot)
        guard indexResult != .failed else { return false }

        let path = NativeClient.externalSendReceiptsPath(dataRoot: dataRoot)
        let rootKey = path.standardizedFileURL.path
        if var cached = legacyReceiptIndexes[rootKey] {
            cached[receiptKey] = receipt
            legacyReceiptIndexes[rootKey] = cached
        }
        guard indexResult == .created || indexResult == .updated else { return true }

        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                try await appendJSONLCapped(
                    receipt,
                    to: path,
                    using: persistence,
                    maxLines: JSONLLineCaps.actionReceipts,
                    logLabel: "ExternalSendApprovalExecutor",
                    takeLock: false
                )
            }
        } catch {
            // The private per-approval receipt is authoritative for replay
            // correctness. The shared JSONL is an audit/read-model mirror.
        }
        return true
    }

    private func persistReceiptIndex(
        _ receipt: JSONValue,
        dataRoot: URL
    ) async -> ReceiptIndexWriteResult {
        guard let receiptKey = Self.receiptKey(receipt),
              let path = NativeClient.externalSendReceiptIndexPath(
                approvalID: receiptKey.approvalID,
                dataRoot: dataRoot
              ) else {
            return .failed
        }
        let persistence = SwiftNativePersistenceCore()
        do {
            return try await persistence.withFileLock(path) {
                switch Self.readCanonicalReceipt(at: path, expectedKey: receiptKey) {
                case .valid(let existing):
                    let existingStatus = Self.status(existing)
                    let nextStatus = Self.status(receipt)
                    if let existingStatus, Self.isSettled(status: existingStatus) {
                        return existingStatus == nextStatus ? .existing : .failed
                    }
                    let existingAttempt = Self.attempt(existing) ?? 0
                    let nextAttempt = Self.attempt(receipt) ?? 0
                    guard nextAttempt >= existingAttempt else { return .failed }
                    if existing == receipt { return .existing }
                    try await persistence.writeJSON(receipt, to: path)
                    return .updated
                case .unavailable:
                    return .failed
                case .missing:
                    try await persistence.writeJSON(receipt, to: path)
                    return .created
                }
            }
        } catch {
            return .failed
        }
    }

    private func terminalReceiptValue(
        request: ExternalSendApprovalRequest,
        approvalID: String,
        status: String,
        attempt: Int,
        didDispatch: Bool,
        output: JSONValue
    ) -> JSONValue {
        .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("external_send_execution"),
            "approvalId": .string(approvalID),
            "connectorId": .string(request.connectorID),
            "actionId": .string(request.actionID),
            "idempotencyKey": .string(request.idempotencyKey),
            "status": .string(status),
            "ok": .bool(status == ExternalSendLifecycleState.providerAccepted.rawValue),
            "attempt": .int(Int64(max(0, attempt))),
            "didDispatch": .bool(didDispatch),
            "output": output,
            "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(Date())),
        ])
    }

    private func executionSummary(
        request: ExternalSendApprovalRequest,
        status: String,
        receiptID: String?,
        error: String?
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "op": .string("external_send"),
            "connectorId": .string(request.connectorID),
            "actionId": .string(request.actionID),
            "status": .string(status),
        ]
        value["receiptId"] = receiptID.map(JSONValue.string) ?? .null
        if let error { value["error"] = .string(Self.redacted(error)) }
        return .object(value)
    }

    private func lifecycleOutput(
        request: ExternalSendApprovalRequest,
        outcome: ExternalSendProviderOutcome
    ) -> JSONValue {
        var output: [String: JSONValue] = [
            "status": .string(outcome.state.rawValue),
            "connectorId": .string(request.connectorID),
            "actionId": .string(request.actionID),
            "providerAccepted": .bool(outcome.state == .providerAccepted),
            // Provider acceptance is never projected as delivery or read.
            "delivery": .string("unknown"),
            "read": .string("unknown"),
        ]
        if let failureCode = outcome.failureCode {
            output["error"] = .string(Self.safeFailureCode(failureCode))
        }
        if let acceptanceID = outcome.acceptanceID,
           outcome.state == .providerAccepted {
            output["providerAcceptanceId"] = .string(String(acceptanceID.prefix(256)))
        }
        return .object(output)
    }

    private func healedDetail(actionID: String, status: String) -> String {
        if status == ExternalSendLifecycleState.providerAccepted.rawValue || status == "succeeded" {
            return "\(actionID) provider-acceptance receipt healed; connector call was not repeated. "
                + "Delivery and read remain unproven."
        }
        if status == ExternalSendLifecycleState.remoteRejected.rawValue || status == "failed" {
            return "\(actionID) prior request was rejected by the provider; connector call was not repeated."
        }
        return "\(actionID) \(status); no connector call ran."
    }

    private func lifecycleDetail(actionID: String, status: String) -> String {
        switch status {
        case ExternalSendLifecycleState.providerAccepted.rawValue:
            return "\(actionID) was accepted by the provider. Delivery and read remain unknown."
        case ExternalSendLifecycleState.remoteRejected.rawValue:
            return "\(actionID) was rejected by the provider; delivery did not occur through this request."
        case ExternalSendLifecycleState.preDispatchFailed.rawValue:
            return "\(actionID) failed before request start; no provider call ran."
        default:
            return "\(actionID) request outcome is unknown; any replay must preserve the approved idempotency key."
        }
    }

    private static func string(_ value: JSONValue, key: String) -> String? {
        guard case .object(let object) = value,
              case .string(let string)? = object[key] else {
            return nil
        }
        return string
    }

    private static func bool(_ value: JSONValue, key: String) -> Bool? {
        guard case .object(let object) = value,
              case .bool(let bool)? = object[key] else {
            return nil
        }
        return bool
    }

    private static func int(_ value: JSONValue, key: String) -> Int? {
        guard case .object(let object) = value else { return nil }
        switch object[key] {
        case .int(let raw)?: return Int(raw)
        case .double(let raw)?: return Int(raw)
        default: return nil
        }
    }

    private static func status(_ value: JSONValue) -> String? {
        string(value, key: "status")
    }

    private static func attempt(_ value: JSONValue) -> Int? {
        int(value, key: "attempt")
    }

    private static func failureCode(_ value: JSONValue) -> String? {
        if let direct = string(value, key: "error") { return direct }
        guard case .object(let root) = value,
              case .object(let output)? = root["output"],
              case .string(let code)? = output["error"] else { return nil }
        return code
    }

    private static func isSettled(status: String) -> Bool {
        [
            ExternalSendLifecycleState.providerAccepted.rawValue,
            ExternalSendLifecycleState.remoteRejected.rawValue,
            "succeeded", "failed", "denied", "canceled",
        ].contains(status)
    }

    private static func shouldArchive(status: String) -> Bool {
        [
            ExternalSendLifecycleState.providerAccepted.rawValue,
            "succeeded", "denied", "canceled",
        ].contains(status)
    }

    private static func safeFailureCode(_ value: String, fallback: String = "connector_error") -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, raw.utf8.count <= 96 else { return fallback }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard raw.unicodeScalars.allSatisfy(allowed.contains) else { return fallback }
        return raw
    }

    private static func redacted(_ value: String) -> String {
        String(NativeAppSecretRedactor.redactText(value).prefix(800))
    }

    private static func isRemoteSurface(_ surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isRemote
    }

    func motorActionReadModel(
        approvalID: String,
        dataRoot: URL
    ) async throws -> MotorActionReadModel? {
        let record: ApprovalRecord
        do {
            record = try await SwiftNativeApprovalInbox(root: dataRoot).get(approvalID)
        } catch ApprovalInboxError.notFound(_) {
            return nil
        }
        guard record.action == ExternalSendApprovalRequest.approvalAction,
              let request = ExternalSendApprovalRequest(record: record) else {
            return nil
        }

        let receiptLookup = await lifecycleReceipt(
            request: request,
            approvalID: record.id,
            dataRoot: dataRoot,
            allowLegacyAuditFallback: false
        )
        let receipt = receiptLookup.receipt
        // The private per-approval lifecycle receipt is the current execution
        // truth. `executedAction` is a UI annotation and must not become a
        // second motor-state owner.
        let exactStatus = receiptLookup.canonicalUnavailable
            ? ExternalSendLifecycleState.outcomeUnknown.rawValue
            : receipt.flatMap(Self.status)

        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let domainState: String
        let expected: String?
        if record.status == "pending" {
            phase = .awaitingApproval
            verification = .notStarted
            domainState = "awaitingApproval"
            expected = "explicit approval or rejection"
        } else if record.decision == "denied" {
            phase = .cancelled
            verification = .notRequired
            domainState = "denied"
            expected = nil
        } else if record.decision == "canceled" {
            phase = .cancelled
            verification = .notRequired
            domainState = "canceled"
            expected = nil
        } else {
            switch exactStatus {
            case ExternalSendLifecycleState.providerAccepted.rawValue, "succeeded":
                phase = .succeeded
                verification = .unverified
                domainState = ExternalSendLifecycleState.providerAccepted.rawValue
                expected = "provider acceptance is proven; delivery and read remain unknown"
            case ExternalSendLifecycleState.remoteRejected.rawValue, "failed":
                phase = .failed
                verification = .failed
                domainState = ExternalSendLifecycleState.remoteRejected.rawValue
                expected = nil
            case ExternalSendLifecycleState.preDispatchFailed.rawValue:
                phase = .blocked
                verification = .notStarted
                domainState = ExternalSendLifecycleState.preDispatchFailed.rawValue
                expected = "local preflight repair before an explicit same-approval retry"
            case ExternalSendLifecycleState.outcomeUnknown.rawValue:
                phase = .waitingExternal
                verification = .unknown
                domainState = ExternalSendLifecycleState.outcomeUnknown.rawValue
                expected = "provider proof or replay with the same idempotency key"
            default:
                phase = record.decision == "approved" ? .ready : .unknown
                verification = .notStarted
                domainState = record.decision == "approved" ? "approvedNotStarted" : "unknown"
                expected = record.decision == "approved" ? "durable request-start marker" : nil
            }
        }

        return MotorActionReadModel(
            domain: "external_send",
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(record.id),
            phase: phase,
            domainState: domainState,
            verification: verification,
            expectedNextEvidence: expected,
            updatedAt: receipt.flatMap { Self.string($0, key: "createdAt") }
                ?? record.resolvedAt ?? record.createdAt,
            cancellationIdentity: nil,
            deadline: nil
        )
    }

    func resetReceiptCacheForTesting(dataRoot: URL) {
        legacyReceiptIndexes.removeValue(
            forKey: NativeClient.externalSendReceiptsPath(dataRoot: dataRoot)
                .standardizedFileURL.path
        )
    }
}

/// One payload-free motor projection over the canonical approval/execution
/// owner. Slack and AgentMail are transport details, not separate action roots.
struct ExternalSendMotorActionReadModelProvider: MotorActionReadModelProviding {
    let dataRoot: URL

    init(dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        try await ExternalSendApprovalExecutor.shared.motorActionReadModel(
            approvalID: actionId,
            dataRoot: dataRoot
        )
    }
}

extension NativeClient {
    static func applyResolvedExternalSend(
        from record: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        dependencies: ExternalSendExecutionDependencies = .production
    ) async -> ExternalSendExecutionOutcome {
        let outcome = await ExternalSendApprovalExecutor.shared.apply(
            record: record,
            dataRoot: dataRoot,
            dependencies: dependencies
        )
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL,
           let readModel = try? await ExternalSendApprovalExecutor.shared.motorActionReadModel(
               approvalID: record.id,
               dataRoot: dataRoot
           ) {
            await NativeCognitionRuntime.shared.observeMotorActionState(readModel)
        }
        return outcome
    }

    static func externalSendReceiptsPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    static func externalSendReceiptIndexPath(approvalID: String, dataRoot: URL) -> URL? {
        guard let canonicalID = UUID(uuidString: approvalID)?.uuidString.lowercased() else {
            return nil
        }
        return dataRoot
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("external_send_receipts", isDirectory: true)
            .appendingPathComponent("\(canonicalID).json")
    }

    static func resetExternalSendReceiptCacheForTesting(dataRoot: URL) async {
        await ExternalSendApprovalExecutor.shared.resetReceiptCacheForTesting(dataRoot: dataRoot)
    }
}
