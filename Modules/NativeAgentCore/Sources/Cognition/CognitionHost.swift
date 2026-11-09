import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import CognitiveSubstrate
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
import DreamREMCycle
// Blueprint: | `CognitionHost.swift` | CognitionHost owner. |

public protocol StudioWanderClientPort: Sendable {
    func toolDispatchClient() -> any ToolDispatchClient
    func chatClient(tools: any ToolDispatchClient) -> SwiftNativeChatOrchestrationClient
}

/// Reflection and Workshop share one background-work slot.
public protocol BackgroundWorkLeasing: Sendable {
    func tryAcquire(holder: String, window: String) async -> Bool
    @discardableResult
    func releaseUnused(holder: String, window: String) async -> Bool
    /// Who claimed `window` and when, so a refused claim names what holds the slot; throws when the lease cannot be read.
    func claim(window: String) async throws -> (holder: String, acquiredAt: String)?
}

/// Keep app-owned dependencies behind this host boundary so cognition can use them without owning their implementations.
public protocol CognitionHost: Sendable {
    /// Share canonical Telegram identity without coupling cognition/history to transport.
    func telegramOwnerUserId(dataRoot: URL) throws -> Int64?
    /// Bring permitted clock and calendar evidence through the same crossing at launch and on clock changes.
    func perceiveDay(dataRoot: URL) async
    func phoneNotificationTargetCount(dataRoot: URL) async throws -> Int
    func readoutFace(id: String, input: JSONValue, version: String, dataRoot: URL) async -> PartCallResult<PartFace>
    func inQuietHours(at date: Date, dataRoot: URL) -> Bool
    /// Return the route for confirmed delivery; nil leaves delivery unconfirmed here.
    func deliverShoulderTap(
        eventId: String, title: String, body: String, reason: String,
        userInfo: [String: String], at date: Date, turn: Turn?
    ) async throws -> String?
    /// Bind the root's cognition and the operation's explicit persona assembly to its background client.
    func backgroundLLMClient(dataRoot: URL, cognition: NativeCognitionRuntime?, assembly: PrivateWorkContextAssembly) -> any LLMClient
    func unattendedWorkAllowed(dataRoot: URL) async -> Bool
    func backgroundWorkLease(dataRoot: URL) -> any BackgroundWorkLeasing
    func backgroundWorkWindow(_ date: Date) -> String
    /// When the window holding `date` ends: the next background slot opens then.
    func backgroundWorkWindowEnd(_ date: Date) -> Date
    func pursuitChoiceTotal(for item: DeskItem, now: Date) -> Double?
    func archiveSupersededMorningBriefs(dataRoot: URL) async
    func studioWanderClient(dataRoot: URL, usesLiveAppBody: Bool) -> any StudioWanderClientPort
    /// Native source selection uses the engine's ordinary originating door.
    func callReadPart(id: String, input: JSONValue, actions: Set<String>, dataRoot: URL, origin: String) async throws -> JSONValue
    /// Carried habits use the same originating Trust gate as part wakes.
    func runCarriedAction(_ step: DeskStep, handle: String, dataRoot: URL) async -> JSONValue
}
