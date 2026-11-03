import Foundation
import os
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import ChatToolRuntime
import TurnTrace
import ToolRegistry
import Experiences
// Blueprint: | `SessionTurnDelivery.swift` | Root/session-owned live delivery: mounted recipients or the resident resolver; caller-result routes and queued peer/mechanical rows cannot hide the person's recorded destination; every turn attaches independently of its caller's observer; recipient leases cannot retire a newer mount; unproven destinations retain an exact-run RepairOwed delivery debt |

/// A surface owns delivery; a turn's caller can only add an observer. Mounted
/// streams live with their consumer, while resident transports resolve a fresh
/// recipient for a continuation from the turn's bound conversation route.
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

    public typealias Resolver = @Sendable (Context) async throws -> Recipient?
    private final class ResolverBox: Sendable {
        let call: Resolver
        init(_ call: @escaping Resolver) { self.call = call }
    }
    private struct Mount: Sendable { let id: UUID; let recipient: Recipient }
    private struct State: Sendable {
        var resolvers: [String: ResolverBox] = [:]
        var mounts: [String: Mount] = [:]
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static func key(_ root: URL, _ session: String, _ run: String) -> String {
        root.standardizedFileURL.path + "\u{1f}" + session + "\u{1f}" + run
    }

    public static func install(dataRoot: URL, resolver: @escaping Resolver) {
        let box = ResolverBox(resolver)
        state.withLock { $0.resolvers[dataRoot.standardizedFileURL.path] = box }
    }

    /// Surface lifecycle registration, never a parameter to a turn-start call.
    public static func mount(dataRoot: URL, sessionID: String, runID: String, recipient: Recipient) -> UUID {
        let id = UUID()
        state.withLock { $0.mounts[key(dataRoot, sessionID, runID)] = Mount(id: id, recipient: recipient) }
        return id
    }

    public static func unmount(dataRoot: URL, sessionID: String, runID: String, lease: UUID) {
        state.withLock {
            let key = key(dataRoot, sessionID, runID)
            if $0.mounts[key]?.id == lease { $0.mounts.removeValue(forKey: key) }
        }
    }

    /// A transport's presentation adapter, with result names paired to the
    /// exact action its app call displayed. This state belongs to one turn.
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

    static func open(dataRoot: URL, sessionID: String, runID: String, surface: String) async -> Recipient? {
        let (mounted, resolver) = state.withLock {
            ($0.mounts[key(dataRoot, sessionID, runID)]?.recipient, $0.resolvers[dataRoot.standardizedFileURL.path])
        }
        var route = ChatToolSessionContext.replyRoute ?? ChatToolSessionContext.envelope?.deliveryRoute
        let recipient: Recipient?
        var unavailable: String?
        do {
            if let mounted { recipient = mounted }
            else {
                if route == nil || route?.surface == "caller-result" {
                    // A caller's result route is not the person's destination.
                    // The conversation owns that destination; Mac presentation
                    // needs only its recorded local source, even when the latest
                    // user-role row belongs to a bridge rather than the person.
                    route = try await HumanConversationReader.readForSessionDelivery(sessionID: sessionID, dataRoot: dataRoot)
                }
                if let route {
                    recipient = try await resolver?.call(Context(dataRoot: dataRoot, sessionID: sessionID, runID: runID,
                        surface: route.surface, route: route))
                } else { recipient = nil }
            }
        }
        catch {
            // Delivery unavailability must never discard her transcript or
            // prevent the turn. It is evidence of no live recipient, not a send verdict.
            recipient = nil
            unavailable = TurnTraceRedactor.redactText(String(describing: error))
        }
        if recipient == nil {
            RepairOwed.owe(dataRoot, id: "session-delivery:" + sessionID + ":" + runID, kind: .run,
                operation: "session.delivery:" + sessionID + ":" + runID, owner: "Conversation delivery",
                words: "Live delivery is still owed for run \(runID) in conversation \(sessionID). "
                    + (unavailable ?? "The recorded destination or its recipient is unavailable; the transcript remains saved."),
                lever: "Recover the recorded human destination and deliver the saved answer for this exact run; do not invent a route or repeat its work.")
        }
        if let turn = TurnTraceContext.turnId {
            TurnTraceBus.fire(TurnTraceEvent(turnId: turn, kind: "turn.deliveryAttached",
                sessionId: sessionID, surface: route?.surface ?? surface, payload: .object([
                    "runId": .string(runID), "live": .bool(recipient != nil),
                    "recipient": .string(mounted != nil ? "mounted" : recipient != nil ? "resident" : "unavailable"),
                    "detail": unavailable.map(JSONValue.string) ?? .null
                ])))
        }
        return recipient
    }

    static func withDelivery<T>(dataRoot: URL, sessionID: String, runID: String, surface: String,
        observer: TurnEventSink?, isolation: isolated (any Actor)? = #isolation,
        operation: (@escaping TurnEventSink) async throws -> T) async rethrows -> T {
        let recipient = await open(dataRoot: dataRoot, sessionID: sessionID, runID: runID, surface: surface)
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
