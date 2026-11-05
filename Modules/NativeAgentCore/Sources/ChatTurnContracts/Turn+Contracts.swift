import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
// Blueprint: | `Turn+Contracts.swift` | `Turn` holds chat admission, execution and sinks; `TurnRows` holds transcript state |

/// The transcript rows a turn writes as its own, decided by its ingress.
public struct TurnRows: Sendable, Equatable {
    /// What the creating ingress declares its session is; continuations keep the row's kind.
    public var threadKind: ChatThreadKind?
    /// The exact session the ingress owns for kind assignment.
    public var ownedSessionID: String?
    /// The assistant row a regenerate replaces on success.
    public var replacementAssistantMessageID: String?
    /// The question a regenerate updates in place and history excludes.
    public var replacementUserMessageID: String?
    /// Crash-recoverable completion identity stamped on the canonical assistant row.
    public var codexCompletion: CodexCompletionTranscriptBinding?
    /// The id the surface already shows for this turn's user row.
    public var pinnedUserMessageID: String?
    /// A room import keeps its source timestamp.
    public var importedMessageCreatedAt: String?
    /// The run whose user row holds this turn's question when the turn writes none: a card continuation answers its origin's.
    public var questionRunID: String?
    public init() {}
}

private enum EnvelopePart: TurnPart { static let unset: TurnEnvelope? = nil }
private enum UserTextPart: TurnPart { static let unset: String? = nil }
private enum FileAccessPart: TurnPart { static let unset: String? = nil }
private enum RendersCardsPart: TurnPart { static let unset = false }
private enum SettingEvidencePart: TurnPart {
    static let unset: (@Sendable (String, JSONValue, JSONValue, String) async -> Bool?)? = nil
}
private enum OriginPart: TurnPart { static let unset: ChatMessageOrigin? = nil }
private enum RowsPart: TurnPart { static let unset = TurnRows() }
private enum RuntimePart: TurnPart { static let unset: ChatTurnRuntimeContext.Active? = nil }
private enum ReplyChoicesPart: TurnPart { static let unset: ReplyChoices? = nil }
private enum ExecutionPart: TurnPart { static let unset: ChatTurnExecution? = nil }
private enum PeerSteeringPart: TurnPart { static let unset: PeerDataTaint? = nil }
private enum NoticesPart: TurnPart { static let unset: (@Sendable (String, String) async -> Void)? = nil }

/// A lexical scope over an explicit value. The closure receives what it holds;
/// no child task or later callback can discover it through ambient state.
public func holding<Value: Sendable, Result>(_ value: Value,
    isolation: isolated (any Actor)? = #isolation,
    operation: (Value) async throws -> Result
) async rethrows -> Result { try await operation(value) }

public func holding<Value, Result>(_ value: Value,
    operation: (Value) throws -> Result
) rethrows -> Result { try operation(value) }

extension Turn {
    /// Only a mounted stream on a card-rendering route can withhold the card's prose.
    public var replyIsTextOnly: Bool {
        !(replyStreamRendersCards && (replyRoute?.rendersInlineCards ?? true))
    }
    /// The one surface identity: who sent it, verified how, and where it answers.
    /// Unset is unauthenticated, remote-marked provenance (`TurnEnvelope.current`).
    public var envelope: TurnEnvelope? {
        get { self[EnvelopePart.self] }
        set {
            self[EnvelopePart.self] = newValue
            traceReplyRoute = { turn in
                let route = turn.replyRoute
                return (route?.destinationId, route?.threadId)
            }
        }
    }
    /// The route the reply goes to: the envelope's delivery projection.
    public var replyRoute: TurnEnvelope.DeliveryRoute? { envelope?.deliveryRoute }
    /// The current request's words only; history and tool results never fill it.
    public var userText: String? {
        get { self[UserTextPart.self] }
        set { self[UserTextPart.self] = newValue }
    }
    /// The admitted file-access restriction, carried to the cards it files.
    public var fileAccess: String? {
        get { self[FileAccessPart.self] }
        set { self[FileAccessPart.self] = newValue }
    }
    /// True while a chat UI that draws inline cards consumes the turn as a stream.
    public var replyStreamRendersCards: Bool {
        get { self[RendersCardsPart.self] }
        set { self[RendersCardsPart.self] = newValue }
    }
    /// Whether a quoted setting request is the person's own; nil rejects the quote.
    public var settingRequestEvidence: (@Sendable (String, JSONValue, JSONValue, String) async -> Bool?)? {
        get { self[SettingEvidencePart.self] }
        set { self[SettingEvidencePart.self] = newValue }
    }
    /// Who authored the incoming row, stamped on user rows only.
    public var origin: ChatMessageOrigin? {
        get { self[OriginPart.self] }
        set { self[OriginPart.self] = newValue }
    }
    /// Where the turn arrived, which each row it writes as its own records as its source (`ChatThreadKind.transcriptSource`), the same meaning
    /// a phone row's `ios` carries. A recorded origin names it, since a trusted bridge authorizes through `chat` yet arrived on `agent-bridge`;
    /// an ingress that records no origin (this Mac's chat, the phone, Telegram) arrived on the surface it authorizes through.
    public func arrivalSurface(authorizing surface: String) -> String { origin?.surface ?? surface }
    /// The rows this turn writes as its own.
    public var rows: TurnRows {
        get { self[RowsPart.self] }
        set { self[RowsPart.self] = newValue }
    }
    /// The live model/provider/surface/persona facts while a tool dispatch runs.
    public var runtime: ChatTurnRuntimeContext.Active? {
        get { self[RuntimePart.self] }
        set { self[RuntimePart.self] = newValue }
    }
    /// The reply's explicit artifact choices.
    public var replyChoices: ReplyChoices? {
        get { self[ReplyChoicesPart.self] }
        set { self[ReplyChoicesPart.self] = newValue }
    }
    /// The turn's running ledger: approvals, cards, tool records, attached pixels.
    package var execution: ChatTurnExecution? {
        get { self[ExecutionPart.self] }
        set { self[ExecutionPart.self] = newValue }
    }
    /// The peers steering this turn and the lines they said.
    public var peerSteering: PeerDataTaint? {
        get { self[PeerSteeringPart.self] }
        set { self[PeerSteeringPart.self] = newValue }
    }
    /// Where the turn's tool notices go.
    public var notices: (@Sendable (String, String) async -> Void)? {
        get { self[NoticesPart.self] }
        set { self[NoticesPart.self] = newValue }
    }
    /// The originating principal, independent of the turn's door or carried steering.
    public var originPrincipal: String {
        if let origin, origin.authored != .agent { return "person" }
        if let agent = origin?.agent ?? envelope?.agent { return agent == "self" ? "self" : "agent:" + agent }
        return origin?.authored == .agent ? "agent:unknown" : "person"
    }
}
