import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import CognitiveSubstrate
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// Blueprint: | `CognitionHost.swift` | Native cognition reach, including the sender-owned phone notification target count and root-bound pure readout-face invocation; domain facts and canonical commits remain outside editable code |

/// Concrete tool and chat clients composed by the app for a Studio hour.
public protocol StudioWanderClientPort: Sendable {
    func toolDispatchClient() -> any ToolDispatchClient
    func chatClient(tools: any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient
}

/// The single background-work slot a reflection shares with the Workshop.
public protocol BackgroundWorkLeasing: Sendable {
    func tryAcquire(holder: String, window: String) async -> Bool
    @discardableResult
    func releaseUnused(holder: String, window: String) async -> Bool
}

/// What the resident mind reaches that the app still owns: the attention
/// router and device sync, the Workshop's lease and pursuit score, the
/// background LLM client and trust gate, the dream action, the scheduler's
/// jobs file, morning briefs and her Studio hour.
public protocol CognitionHost: Sendable {
    func phoneNotificationTargetCount(dataRoot: URL) async throws -> Int
    func readoutFace(id: String, input: JSONValue, version: String, dataRoot: URL) async -> PartCallResult<PartFace>
    /// The user's declared quiet hours, as the attention router reads them.
    func inQuietHours(at date: Date, dataRoot: URL) -> Bool
    /// Routes one informational shoulder tap; the delivery it knocked by, or
    /// nil when routing did not knock (no delivery, or already delivered).
    func deliverShoulderTap(
        eventId: String, title: String, body: String, reason: String,
        userInfo: [String: String], at date: Date
    ) async throws -> String?
    /// Publishes the Mac's snapshots to the phone.
    /// The shared background LLM client; nil cognition binds the root's own owner.
    func backgroundLLMClient(dataRoot: URL, cognition: NativeCognitionRuntime?) -> any LLMClient
    /// Workshop's autonomy gate for unattended work.
    func unattendedWorkAllowed(dataRoot: URL) async -> Bool
    func backgroundWorkLease(dataRoot: URL) -> any BackgroundWorkLeasing
    func backgroundWorkWindow(_ date: Date) -> String
    /// The Workshop pump's choice score for one pursuit, nil when not a pursuit.
    func pursuitChoiceTotal(for item: DeskItem, now: Date) -> Double?
    /// The scheduler runner's checked read of its jobs file.
    func schedulerJobRows(at path: URL) throws -> [JSONValue]
    func archiveSupersededMorningBriefs(dataRoot: URL) async
    /// The platform-backed clients her Core-owned Studio hour calls.
    func studioWanderClient(dataRoot: URL, usesLiveAppBody: Bool) -> any StudioWanderClientPort
    /// Native source selection enters the engine's ordinary originating door.
    func callReadPart(id: String, input: JSONValue, actions: Set<String>, dataRoot: URL, origin: String) async throws -> JSONValue
}
