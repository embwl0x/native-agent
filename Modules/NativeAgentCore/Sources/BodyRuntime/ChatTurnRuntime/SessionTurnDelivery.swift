import Synchronization
import Foundation
import os
import NativeAgentCore
import PersistenceCore
import MindCore
import SenseCore
import DeskCore
// Blueprint: | `SessionTurnDelivery.swift` | Session-owned live delivery and exact-run repair debt |

/// The conversation owns its delivery destination; callers add observers only.
/// Resolve fresh recipients for resident continuations, while mounted streams follow their consumer lifecycle.
public enum SessionTurnDelivery {
    public struct Context: Sendable {
        public let dataRoot: URL
        public let sessionID: String
        public let runID: String
        public let surface: String
        public let route: ChatToolSessionContext.ReplyRoute?
    }

    public struct Recipient: Sendable {
        public let progress: TurnEventSink
        public let finish: @Sendable () async -> Void
        public init(progress: @escaping TurnEventSink, finish: @escaping @Sendable () async -> Void = {}) {
            self.progress = progress
            self.finish = finish
        }
    }

    public typealias Resolver = @Sendable (Context, Turn) async throws -> Recipient?
    private struct Mount: Sendable { let id: UUID; let recipient: Recipient }
    private static let mounts = Mutex([String: Mount]())
    private static func key(_ root: URL, _ session: String, _ run: String) -> String {
        root.standardizedFileURL.path + "\u{1f}" + session + "\u{1f}" + run
    }

    /// Surface lifecycle registration, never a parameter to a turn-start call.
    public static func mount(dataRoot: URL, sessionID: String, runID: String, recipient: Recipient) -> UUID {
        let id = UUID()
        mounts.withLock { $0[key(dataRoot, sessionID, runID)] = Mount(id: id, recipient: recipient) }
        return id
    }

    public static func unmount(dataRoot: URL, sessionID: String, runID: String, lease: UUID) {
        mounts.withLock {
            let key = key(dataRoot, sessionID, runID)
            if $0[key]?.id == lease { $0.removeValue(forKey: key) }
        }
    }

    /// Pair presented results with the exact displayed action; this adapter's state belongs to one turn.
    public static func presentingTools(_ sink: @escaping TurnEventSink) -> TurnEventSink {
        let shown = ShownToolNames()
        return { event in
            switch event {
            case .toolUse(let name, let input):
                let call = shown.use(name, input: input)
                await sink(.toolUse(name: call.name, input: call.input))
            case .toolResult(let name, let output):
                await sink(.toolResult(name: shown.result(name).name, output: output))
            case .notice(let kind, let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { await sink(.notice(kind: kind, text: trimmed)) }
            case .final, .error: break
            default: await sink(event)
            }
        }
    }

    @concurrent private static func conversationDestination(sessionID: String, dataRoot: URL) async throws
        -> (required: Bool, route: ChatToolSessionContext.ReplyRoute?) {
        if !owesLiveDelivery(try SessionConversation.checkedKind(sessionID, dataRoot: dataRoot)) { return (false, nil) }
        return (true, try await HumanConversationReader.readForSessionDelivery(sessionID: sessionID, dataRoot: dataRoot))
    }

    private static func owesLiveDelivery(_ kind: ChatThreadKind?) -> Bool { !(kind == .builder || kind == .agent || kind == .ephemeral) }

    private static func open(dataRoot: URL, sessionID: String, runID: String, surface: String, turn: Turn,
                             resolver: Resolver?) async -> Recipient? {
        let mounted = mounts.withLock { $0[key(dataRoot, sessionID, runID)]?.recipient }
        var route = turn.replyRoute ?? turn.envelope?.deliveryRoute
        let recipient: Recipient?
        var unavailable: String?
        var needsDelivery = true
        do {
            if let mounted { recipient = mounted }
            else {
                if route == nil || route?.surface == "caller-result" {
                    // Use the conversation's destination, never a caller's result route or an unrelated bridge-authored row.
                    let destination = try await conversationDestination(sessionID: sessionID, dataRoot: dataRoot)
                    needsDelivery = destination.required
                    route = destination.route
                }
                if let route {
                    recipient = try await resolver?(Context(dataRoot: dataRoot, sessionID: sessionID, runID: runID,
                        surface: route.surface, route: route), turn)
                } else { recipient = nil }
            }
        }
        catch {
            // Delivery unavailability must never discard the agent's transcript or
            // prevent the turn. It is evidence of no live recipient, not a send verdict.
            recipient = nil
            unavailable = TurnTraceRedactor.redactText(String(describing: error))
        }
        if recipient == nil && needsDelivery && owesLiveDelivery(SessionConversation.kind(sessionID, dataRoot: dataRoot)) {
            RepairOwed.owe(dataRoot, id: "session-delivery:" + sessionID + ":" + runID, kind: .run,
                operation: "session.delivery:" + sessionID + ":" + runID, owner: "Conversation delivery",
                words: "Live delivery is still owed for run \(runID) in conversation \(sessionID). "
                    + (unavailable ?? "The recorded destination or its recipient is unavailable; the transcript remains saved."),
                lever: "Recover the recorded human destination and deliver the saved answer for this exact run; do not invent a route or repeat its work.")
        }
        do {
            let turnID = turn.id
            TurnTraceBus.fire(TurnTraceEvent(turnId: turnID, kind: "turn.deliveryAttached",
                sessionId: sessionID, surface: route?.surface ?? surface, payload: .object([
                    "runId": .string(runID), "live": .bool(recipient != nil), "required": .bool(needsDelivery),
                    "recipient": .string(mounted != nil ? "mounted" : recipient != nil ? "resident" : needsDelivery ? "unavailable" : "not-needed"),
                    "detail": unavailable.map(JSONValue.string) ?? .null
                ]), turn: turn))
        }
        return recipient
    }

    static func withDelivery<T>(dataRoot: URL, sessionID: String, runID: String, surface: String,
        observer: TurnEventSink?, turn: Turn, resolver: Resolver?, isolation: isolated (any Actor)? = #isolation,
        operation: (@escaping TurnEventSink) async throws -> T) async rethrows -> T {
        let recipient = await open(dataRoot: dataRoot, sessionID: sessionID, runID: runID, surface: surface,
                                   turn: turn, resolver: resolver)
        let progress: TurnEventSink = { event in
            await recipient?.progress(event)
            await observer?(event)
        }
        do {
            let result = try await operation(progress)
            await settle { await recipient?.finish() }
            return result
        } catch {
            await settle { await recipient?.finish() }
            throw error
        }
    }
}
