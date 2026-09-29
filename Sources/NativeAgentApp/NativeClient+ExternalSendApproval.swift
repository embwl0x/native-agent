import Foundation
import ChatOrchestration
import NativeAgentCore
import ApprovalInbox
import ApprovalTransactions
import SlackConnector

typealias ExternalSendMotorActionReadModelProvider = ApprovalTransactions.ExternalSendMotorActionReadModelProvider

extension ExternalSendExecutionDependencies {
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

extension NativeClient {
    static func applyResolvedExternalSend(
        from record: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        dependencies: ExternalSendExecutionDependencies = .production
    ) async -> ExternalSendExecutionOutcome {
        await ExternalSendApprovalTransactions.applyResolvedExternalSend(
            from: record,
            dataRoot: dataRoot,
            dependencies: dependencies,
            observeMotorActionState: { await NativeAgentEngine.liveCognition.observeMotorActionState($0) }
        )
    }

    static func externalSendReceiptsPath(dataRoot: URL) -> URL {
        ExternalSendApprovalTransactions.externalSendReceiptsPath(dataRoot: dataRoot)
    }

    static func externalSendReceiptIndexPath(approvalID: String, dataRoot: URL) -> URL? {
        ExternalSendApprovalTransactions.externalSendReceiptIndexPath(approvalID: approvalID, dataRoot: dataRoot)
    }

    static func resetExternalSendReceiptCacheForTesting(dataRoot: URL) async {
        await ExternalSendApprovalTransactions.resetExternalSendReceiptCacheForTesting(dataRoot: dataRoot)
    }
}
