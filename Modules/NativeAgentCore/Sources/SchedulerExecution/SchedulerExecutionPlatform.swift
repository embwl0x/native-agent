import Foundation
import AppToolRuntime
import AttentionRouting
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SchedulerExecutionPlatform.swift` | `SchedulerExecutionPlatform` protocol; `postNotification`, `read` (a scheduled read through the app door) |

/// Concrete app effects used by the due-job owner. Selection, claims, delivery policy and receipts remain in SchedulerExecution.
public protocol SchedulerExecutionPlatform: Sendable {
    var attentionRouter: AttentionRouter { get }
    func postNotification(title: String, body: String) async -> NativeAgentNotificationPostResult
    /// A scheduled read: `action` with `input` through the app door, as any of the agent's calls, held to a read. Throws what refused or failed it.
    func read(action: String, input: [String: JSONValue]) async throws -> JSONValue
    func runDream(force: Bool) async throws -> sending [String: Any]
    func runRem(force: Bool) async throws -> sending [String: Any]
    func runHarnessBenchmark() async throws -> (id: String, status: String?)
}
