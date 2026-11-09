import Foundation
import NativeAgentShared
import TurnTrace
// Blueprint: | `ChatPersistenceContext.swift` | Ingress provenance and durable completion identity; transcript choices live on Turn.rows |

/// Out-of-band provenance cannot be forged by typing an in-band sender prefix.
public struct ChatMessageOrigin: Sendable, Equatable, Codable {
    public let surface: String
    /// The route is authenticated; a shared bridge bearer does not attest the calling process. Nil means unattributed.
    public let agent: String?
    /// Only a lane transcribing its own agent's output sets authorship; forwarding leaves nil, interpreted as human.
    public let authored: ChatMessageAuthorship?
    public var replyTo: String? = nil
    /// Peer steering carried into a successor, independent of its reply route.
    public var peerSources: [String]? = nil
    public var elevatedPeerSources: [String]? = nil

    public init(
        surface: String,
        agent: String? = nil,
        authored: ChatMessageAuthorship? = nil,
        replyTo: String? = nil
    ) {
        self.surface = surface
        self.agent = agent
        self.authored = authored
        self.replyTo = replyTo
    }
}

/// A closed enum keeps this trust input from accidentally spelling the authority-granting `agent` case.
public enum ChatMessageAuthorship: String, Sendable, Equatable, Codable {
    case agent
    case human
}

/// Persist before returning so crash recovery can find the reply without starting another turn.
public struct CodexCompletionTranscriptBinding: Sendable, Equatable, Codable {
    public let deliveryId: String
    public let requestDigest: String
    public let model: String
    public let reasoningEffort: String?

    public init(
        deliveryId: String,
        requestDigest: String,
        model: String,
        reasoningEffort: String?
    ) {
        self.deliveryId = deliveryId
        self.requestDigest = requestDigest
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}
