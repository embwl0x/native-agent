import Foundation
import AppToolRuntime
import AttentionRouting
import NativeAgentCore
import PersistenceCore

/// Concrete app effects used by the due-job owner. Selection, claims, delivery
/// policy and receipts remain in SchedulerExecution.
public protocol SchedulerExecutionPlatform: Sendable {
    var attentionRouter: AttentionRouter { get }
    func postNotification(title: String, body: String) async -> NativeAgentNotificationPostResult
    func sendTelegramMessage(message: String) async throws
    func notifyInboxIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String, summary: String,
        source: String, severity: String
    ) async
    func runConnectorAction(
        id: String, dryRun: Bool, input: [String: JSONValue],
        externalSendIdempotencyKey: String
    ) async throws -> (id: String, status: String)
    func runDream(force: Bool) async throws -> sending [String: Any]
    func runRem(force: Bool) async throws -> sending [String: Any]
    func startImprovement(objective: String) async throws -> (id: String, status: String?, phase: String?)
    func runHarnessBenchmark() async throws -> (id: String, status: String?)
    func createWorkshopTask(
        title: String, objective: String, projectSpaceId: String?
    ) async throws -> (id: String, status: String)
}
