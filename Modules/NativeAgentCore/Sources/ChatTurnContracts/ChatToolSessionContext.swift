import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import MacControl
// Blueprint: | `ChatToolSessionContext.swift` | `ChatToolSessionContext`, `TurnEnvelope.workIdentity`, `answerExperienceID`: attribution, not authority |

// MARK: - Per-turn tool session context

/// Downstream dispatchers use the gate-bound session ID to resolve the same trust origin.
public enum ChatToolSessionContext {
    public struct ReplyRoute: Sendable, Equatable {
        public let surface: String
        public let destinationId: String?
        public let threadId: String?
        public let sourceKey: String?
        public let replyTo: String?
        public let correlationId: String?
        public let requesterUserId: String?

        public init(
            surface: String,
            destinationId: String? = nil,
            threadId: String? = nil,
            sourceKey: String? = nil,
            replyTo: String? = nil,
            correlationId: String? = nil,
            requesterUserId: String? = nil
        ) {
            self.surface = surface
            self.destinationId = destinationId
            self.threadId = threadId
            self.sourceKey = sourceKey
            self.replyTo = replyTo
            self.correlationId = correlationId
            self.requesterUserId = requesterUserId
        }

        public var stringFields: [String: String] {
            ["surface": surface, "destinationId": destinationId, "threadId": threadId,
             "sourceKey": sourceKey, "replyTo": replyTo, "correlationId": correlationId,
             "requesterUserId": requesterUserId].compactMapValues { $0 }
        }

        /// Only Mac and iPhone routes draw cards; other routes need prose. Check the route because bridges can use the chat surface.
        public var rendersInlineCards: Bool {
            switch surface.lowercased() {
            case "chat", "app", "ios": true
            default: false
            }
        }
    }


}

// MARK: - TurnEnvelope (the per-turn surface contract)

/// Carry only transport-verified identity on the explicit turn; unverifiable identifiers stay nil and fail closed.
/// Persist `deliveryRoute` for delayed completions; publish a `ConversationAnchor` for direct user conversations.
/// Session IDs are opaque storage keys and prove no identity. Only the current envelope grants authority; history grants none.
/// Remoteness may be added for unknown surfaces but never removed from a known-remote surface.
public struct TurnEnvelope: Sendable, Equatable {
    /// Delayed replies require this half of the envelope to survive on the durable message row.
    public typealias DeliveryRoute = ChatToolSessionContext.ReplyRoute

    /// Record the adapter's raw surface; canonical normalization belongs at the trust boundary.
    public let surface: String
    public let agent: String?
    /// Only transport verification supplies this identity; absent or unverifiable identifiers stay nil.
    public let verifiedChatId: String?
    /// Only the transport may attest this person identifier.
    public let verifiedUserId: String?
    /// Nil means the transport has no verification scheme; false means verification did not succeed.
    public let commandSignatureVerified: Bool?
    public let deliveryRoute: DeliveryRoute?
    /// Unknown surfaces may add remoteness; known-remote surfaces cannot subtract it.
    public let declaredRemote: Bool?
    /// Request-time AX evidence, process-local and never restored from history.
    public let macContinuation: MacWorkContinuation?
    /// Work attribution only; it grants no authority.
    public let workIdentity: String?
    public var answerExperienceID: String?

    public init(
        surface: String,
        agent: String? = nil,
        verifiedChatId: String? = nil,
        verifiedUserId: String? = nil,
        commandSignatureVerified: Bool? = nil,
        deliveryRoute: DeliveryRoute? = nil,
        declaredRemote: Bool? = nil,
        macContinuation: MacWorkContinuation? = nil,
        workIdentity: String? = nil,
        answerExperienceID: String? = nil
    ) {
        self.surface = surface
        self.agent = agent
        self.verifiedChatId = Self.cleaned(verifiedChatId)
        self.verifiedUserId = Self.cleaned(verifiedUserId)
        self.commandSignatureVerified = commandSignatureVerified
        self.deliveryRoute = deliveryRoute
        self.declaredRemote = declaredRemote
        self.macContinuation = macContinuation
        self.workIdentity = workIdentity
        self.answerExperienceID = answerExperienceID
    }

    /// Native work is locally attributed without inventing a transport identity.
    public static func native(_ workIdentity: String, surface: String = "chat") -> TurnEnvelope {
        TurnEnvelope(surface: surface, agent: "self", declaredRemote: false, workIdentity: workIdentity)
    }

    /// The person's own act on this Mac. UI owners use this constructor;
    /// native agent work uses `native` and never impersonates the person.
    public static func personOnMac(_ workIdentity: String, surface: String = "chat") -> TurnEnvelope {
        TurnEnvelope(surface: surface, declaredRemote: false, workIdentity: workIdentity)
    }

    public func withMacContinuation(_ continuation: MacWorkContinuation) -> TurnEnvelope {
        TurnEnvelope(surface: surface, agent: agent, verifiedChatId: verifiedChatId,
            verifiedUserId: verifiedUserId, commandSignatureVerified: commandSignatureVerified,
            deliveryRoute: deliveryRoute, declaredRemote: declaredRemote, macContinuation: continuation, workIdentity: workIdentity,
            answerExperienceID: answerExperienceID)
    }

    public func withDeliveryRoute(_ route: DeliveryRoute?) -> TurnEnvelope {
        TurnEnvelope(surface: surface, agent: agent, verifiedChatId: verifiedChatId,
            verifiedUserId: verifiedUserId, commandSignatureVerified: commandSignatureVerified,
            deliveryRoute: route, declaredRemote: declaredRemote, macContinuation: macContinuation,
            workIdentity: workIdentity, answerExperienceID: answerExperienceID)
    }

    public var replyRoute: DeliveryRoute {
        deliveryRoute ?? DeliveryRoute(surface: surface)
    }

    /// Persist provenance without a trust verdict: each turn's gate must decide authority afresh.
    public func persistedMetadata() -> JSONValue {
        var object: [String: JSONValue] = ["surface": .string(surface)]
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            object[key] = .string(value)
        }
        put("agent", Self.cleaned(agent))
        if let declaredRemote { object["declaredRemote"] = .bool(declaredRemote) }
        put("workIdentity", workIdentity)
        put("answerExperienceID", answerExperienceID)
        put("chatId", verifiedChatId)
        put("userId", verifiedUserId)
        put("requesterUserId", Self.cleaned(deliveryRoute?.requesterUserId))
        put("destinationId", Self.cleaned(deliveryRoute?.destinationId))
        put("threadId", Self.cleaned(deliveryRoute?.threadId))
        put("sourceKey", Self.cleaned(deliveryRoute?.sourceKey))
        put("replyTo", Self.cleaned(deliveryRoute?.replyTo))
        put("correlationId", Self.cleaned(deliveryRoute?.correlationId))
        return .object(object)
    }

    /// Restored envelopes label provenance only; they never authorize tool calls.
    public static func fromPersistedMetadata(_ value: JSONValue?) -> TurnEnvelope? {
        guard case .object(let object)? = value else { return nil }
        func read(_ key: String) -> String? {
            guard case .string(let string)? = object[key] else { return nil }
            return cleaned(string)
        }
        guard let surface = read("surface") else { return nil }
        let declaredRemote: Bool?
        switch object["declaredRemote"] {
        case .bool(let value)?: declaredRemote = value
        case nil: declaredRemote = nil
        default: return nil
        }
        let route = ChatToolSessionContext.ReplyRoute(
            surface: surface,
            destinationId: read("destinationId"),
            threadId: read("threadId"),
            sourceKey: read("sourceKey"),
            replyTo: read("replyTo"),
            correlationId: read("correlationId"),
            requesterUserId: read("requesterUserId") ?? read("userId")
        )
        return TurnEnvelope(
            surface: surface,
            agent: read("agent"),
            verifiedChatId: read("chatId"),
            verifiedUserId: read("userId"),
            deliveryRoute: route,
            declaredRemote: declaredRemote,
            workIdentity: read("workIdentity"),
            answerExperienceID: read("answerExperienceID")
        )
    }

    /// Only the explicit ingress envelope supplies identity. Missing provenance is unbound,
    /// never authenticated or local merely because a caller supplied a surface spelling.
    public static func current(turn: Turn?, surface: String) -> TurnEnvelope {
        if let bound = turn?.envelope {
            return bound
        }
        return TurnEnvelope(
            surface: surface,
            declaredRemote: true
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Call and origin equality grant no authority. Injection replay must verify and spend the canonical approval before minting.
/// SecurityCenter, file access and effect-time validation still apply.
public struct ApprovedChatToolReplay: Sendable, Equatable {
    public let approvalID: String
    public let tool: String
    public let surface: String
    public let input: [String: JSONValue]
    public let verifiedSessionID: String?
    public let verifiedChatID: String?
    public let verifiedUserID: String?

    public init(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue],
        verifiedSessionID: String?,
        verifiedChatID: String?,
        verifiedUserID: String?
    ) {
        self.approvalID = approvalID
        self.tool = tool
        self.surface = surface
        self.input = input
        self.verifiedSessionID = verifiedSessionID
        self.verifiedChatID = verifiedChatID
        self.verifiedUserID = verifiedUserID
    }

}

/// Introspection reads the live turn route, which may differ from configuration. Outside a turn it reads the configured route.
public enum ChatTurnRuntimeContext {
    public struct Active: Sendable {
        public let model: String
        public let surface: String
        public let personaID: String?
        /// Keep admitted transport separate from model-family inference because transports can expose overlapping model names.
        public let providerID: String?
        public init(
            model: String,
            surface: String,
            personaID: String? = nil,
            providerID: String? = nil
        ) {
            self.model = model
            self.surface = surface
            self.personaID = personaID
            self.providerID = providerID
        }
    }
}

/// One turn-wide choice covers direct calls, nested batches and scripts.
public final class ReplyChoices: @unchecked Sendable {
    private let lock = NSLock()
    private var chosen: [String] = []
    public init() {}
    public func choose(_ path: String) { lock.withLock { if !chosen.contains(path) { chosen.append(path) } } }
    public var paths: [String] { lock.withLock { chosen } }
}
