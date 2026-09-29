import Foundation
import PersistenceCore

/// App-owned routing bookmarks, not another transcript or authority store.
/// The last receipt is a bounded cache; the adapter remains the evidence owner.
public struct AgentConversationRecord: Codable, Sendable {
    public var id: String
    public var scopeSessionID: String
    public var agent: String
    public var name: String
    public var label: String
    public var conversationID: String?
    public var readInput: [String: JSONValue]?
    public var receipt: JSONValue?
    public var phase: String
    public var operationID: String
    public var updatedAt: Date
    public var sourceSurface: String
    public var operationStartedAt: Date?
    public var automaticRead: Bool = false
    public var deliveryState: String?
    public var deliveryRunID: String?
    public var nextReadAt: Date?
    public var peerRouteFingerprint: String?
    public var replyRoute: [String: String]?
    public var selected: Bool = false
    public var exchanges: [AgentConversationExchange]?
    /// The current send was typed by the person in the contact's thread, so
    /// its answer settles here and never starts an agent turn.
    public var personInitiated: Bool?
    /// The current send wants an answer (a question or a request), fixed at
    /// send time. False for an FYI, a report or a receipt: once delivered it
    /// is done, never "waiting". Nil on records saved before 2026-09-25.
    public var expectsReply: Bool?
    /// Follow-ups written while a reply was still in flight, oldest first.
    /// Each goes by itself, in order, once the reply ahead of it settles.
    public var queued: [AgentConversationQueued]?
    /// A stop asked for on the in-flight reply (`agent_cancel`).
    public var stop: AgentConversationStop?
    /// The queued message taken to be sent next: the thread is its alone
    /// until that send begins.
    public var queueReservation: String?
    /// "<operation>:<phase>" whose settled result her own call already
    /// returned to her (a blocking lane's reply, an immediate failure), so it
    /// is no arrival. A later change on that send (a late reply) still is.
    public var shownInline: String?
    /// A built-in delegate's stall or bad outcome on the current send, held
    /// until the continuation tells her in this chat (once per event).
    public var notice: AgentConversationNotice?
    package init(id: String,
                 scopeSessionID: String,
                 agent: String,
                 name: String,
                 label: String,
                 conversationID: String? = nil,
                 readInput: [String: JSONValue]? = nil,
                 receipt: JSONValue? = nil,
                 phase: String,
                 operationID: String,
                 updatedAt: Date,
                 sourceSurface: String,
                 operationStartedAt: Date? = nil,
                 automaticRead: Bool = false,
                 deliveryState: String? = nil,
                 deliveryRunID: String? = nil,
                 nextReadAt: Date? = nil,
                 peerRouteFingerprint: String? = nil,
                 replyRoute: [String: String]? = nil,
                 selected: Bool = false,
                 exchanges: [AgentConversationExchange]? = nil,
                 personInitiated: Bool? = nil,
                 expectsReply: Bool? = nil,
                 queued: [AgentConversationQueued]? = nil,
                 stop: AgentConversationStop? = nil,
                 queueReservation: String? = nil,
                 shownInline: String? = nil,
                 notice: AgentConversationNotice? = nil) {
        self.id = id
        self.scopeSessionID = scopeSessionID
        self.agent = agent
        self.name = name
        self.label = label
        self.conversationID = conversationID
        self.readInput = readInput
        self.receipt = receipt
        self.phase = phase
        self.operationID = operationID
        self.updatedAt = updatedAt
        self.sourceSurface = sourceSurface
        self.operationStartedAt = operationStartedAt
        self.automaticRead = automaticRead
        self.deliveryState = deliveryState
        self.deliveryRunID = deliveryRunID
        self.nextReadAt = nextReadAt
        self.peerRouteFingerprint = peerRouteFingerprint
        self.replyRoute = replyRoute
        self.selected = selected
        self.exchanges = exchanges
        self.personInitiated = personInitiated
        self.expectsReply = expectsReply
        self.queued = queued
        self.stop = stop
        self.queueReservation = queueReservation
        self.shownInline = shownInline
        self.notice = notice
    }

}

/// One delegation event for her, in the chat the send came from.
public struct AgentConversationNotice: Codable, Sendable, Equatable {
    public var event: String
    public var text: String
    public init(event: String, text: String) { self.event = event; self.text = text }
}

/// A message waiting on its thread behind the reply in progress (09-25: a
/// second message used to be refused). Never dropped: it goes, or it stays
/// here `held` with the reason, and is never resent by itself after that.
public struct AgentConversationQueued: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var queuedAt: Date
    public var byPerson: Bool?
    public var held: String?
    package init(id: String,
                 text: String,
                 queuedAt: Date,
                 byPerson: Bool? = nil,
                 held: String? = nil) {
        self.id = id
        self.text = text
        self.queuedAt = queuedAt
        self.byPerson = byPerson
        self.held = held
    }

}

/// The thread's stop state for one operation: "stopping" (asked, the lane has
/// not confirmed), "stopped" (the reply ended because of it), "finished" (it
/// answered first), "released" (no stop exists, but its answer comes back on its
/// own, so the thread stops waiting), or "cannot_stop"
/// (this lane has no stop; the reply keeps coming).
public struct AgentConversationStop: Codable, Sendable, Equatable {
    public var state: String
    public var operationID: String
    public var at: Date
    public var detail: String
    package init(state: String,
                 operationID: String,
                 at: Date,
                 detail: String) {
        self.state = state
        self.operationID = operationID
        self.at = at
        self.detail = detail
    }

}


/// Bounded display history inside the routing bookmark. Never provider context,
/// replay input, settlement authority, or a replacement for the reply's owner.
public struct AgentConversationExchange: Codable, Sendable {
    public var id: String
    public var sentAt: Date
    public var prompt: String?
    public var reply: String?
    public var promptTruncated: Bool
    public var replyTruncated: Bool
    public var phase: String
    public var status: String
    /// Typed by the person in the contact's thread, not sent by the agent.
    public var byPerson: Bool?
    /// When the reply landed, or (with no reply) when the send settled. Nil
    /// on exchanges saved before 2026-09-25 and while it is still in flight.
    public var settledAt: Date?
    /// The agent's first sign of work on this send (text, a tool, bytes), if any.
    public var firstActivityAt: Date?

    package init(id: String,
                 sentAt: Date,
                 prompt: String? = nil,
                 reply: String? = nil,
                 promptTruncated: Bool,
                 replyTruncated: Bool,
                 phase: String,
                 status: String,
                 byPerson: Bool? = nil,
                 settledAt: Date? = nil,
                 firstActivityAt: Date? = nil) {
        self.id = id
        self.sentAt = sentAt
        self.prompt = prompt
        self.reply = reply
        self.promptTruncated = promptTruncated
        self.replyTruncated = replyTruncated
        self.phase = phase
        self.status = status
        self.byPerson = byPerson
        self.settledAt = settledAt
        self.firstActivityAt = firstActivityAt
    }

}
