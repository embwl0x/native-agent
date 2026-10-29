import Foundation
import AppToolRuntime
import AttentionRouting
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SchedulerExecutionPlatform.swift` | `SchedulerExecutionPlatform` protocol; `postNotification`, `sendTelegramMessage`, `read` (a scheduled read through the app door) |

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
    /// A scheduled read: `action` with `input` through the app door, as any of
    /// her calls, held to a read. Throws what refused or failed it.
    func read(action: String, input: [String: JSONValue]) async throws -> JSONValue
    func runDream(force: Bool) async throws -> sending [String: Any]
    func runRem(force: Bool) async throws -> sending [String: Any]
    func runHarnessBenchmark() async throws -> (id: String, status: String?)
    func createWorkshopTask(
        title: String, objective: String, projectSpaceId: String?
    ) async throws -> (id: String, status: String)
    /// A scheduled turn: one ephemeral tool turn of hers with her full tools, through the
    /// same door the Workshop pump runs a reserved Desk session; returns the model and reply.
    func runScheduledTurn(name: String, prompt: String) async throws -> (model: String, output: String)
}
