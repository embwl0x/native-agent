import Foundation
import NativeAgentShared
// Blueprint: | `Turn.swift` | `Turn`: one identity handed to everything serving it; `TurnPart` keys each owner's state |

/// One turn: which act it is, which run and session are its own, and each
/// owner's state for it. Born once at acceptance and passed by value to
/// whatever serves the turn, so work that runs later (settle, a callback, a
/// detached task) holds the same turn. Nothing reads turn identity from the
/// air; task-locals carry trace correlation only.
public struct Turn: Sendable {
    /// The act: causal identity, and the id trace correlation carries.
    public let id: String
    /// The user row's run: transcript identity, distinct from the act.
    public var run: String
    /// The resolved session; nil until one exists.
    public var session: String?
    private var parts: [ObjectIdentifier: any Sendable] = [:]

    public init(id: String = Turn.mintID(), run: String = UUID().uuidString, session: String? = nil) {
        self.id = id
        self.run = run
        self.session = session
    }

    /// Lowercased UUID, the row-id convention every trace writer shares.
    public static func mintID() -> String { UUID().uuidString.lowercased() }

    /// An owner's state on this turn, keyed by the owner's part type.
    public subscript<Part: TurnPart>(_ part: Part.Type) -> Part.Value {
        get { parts[ObjectIdentifier(part)] as? Part.Value ?? Part.unset }
        set { parts[ObjectIdentifier(part)] = newValue }
    }

    /// The same turn with one value changed: the explicit form of a nested scope.
    public func with<Value>(_ path: WritableKeyPath<Turn, Value>, _ value: Value) -> Turn {
        var turn = self
        turn[keyPath: path] = value
        return turn
    }

    /// A new act inside this turn (a part's thought, a helper): its own id,
    /// this turn's run and session unless given, every part carried.
    public func derived(id: String = Turn.mintID(), run: String? = nil) -> Turn {
        var turn = Turn(id: id, run: run ?? self.run, session: session)
        turn.parts = parts
        return turn
    }
}

/// One owner's state carried on a turn. The owner declares the key beside its
/// value type and exposes it as a `Turn` property; `unset` is what a turn that
/// never set it holds.
public protocol TurnPart {
    associatedtype Value: Sendable
    static var unset: Value { get }
}

/// The renderer that admitted a presentation; disconnection never retargets its effects.
public enum FacePresentationPart: TurnPart {
    public static let unset: UUID? = nil
}

/// The provider route admitted once for the turn; adapters read it, a later
/// picker change never splices into it.
public struct ModelAdmission: Sendable, Equatable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String?
    public let serviceTier: String?
    public init(provider: String, model: String, reasoningEffort: String? = nil, serviceTier: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

private enum ClientPart: TurnPart { static let unset: (any LLMClient)? = nil }
private enum TokenBudgetPart: TurnPart { static let unset: TurnTokenBudget? = nil }
private enum OfferedToolsPart: TurnPart { static let unset: Set<String>? = nil }
private enum CapabilityNotePart: TurnPart { static let unset: (@Sendable (String) -> Void)? = nil }
private enum PartialReplyPart: TurnPart { static let unset: (@Sendable (String) async -> Void)? = nil }
private enum AdmissionPart: TurnPart { static let unset: ModelAdmission? = nil }
private enum VerifiedSessionPart: TurnPart { static let unset: String? = nil }
private enum ToolActPart: TurnPart { static let unset: String? = nil }
private enum FileAccessPart: TurnPart { static let unset = ICloudChatFileAccessPolicy.Ceiling() }

extension Turn {
    /// The request's admitted file-access ceiling, shared by Trust, execution and the cards it files.
    public var fileAccess: String? {
        get { fileAccessCeiling.mode }
        set { fileAccessCeiling = .init(newValue) }
    }
    /// Re-entry can only intersect authority; neither a wider ID nor an absent one erases a held restriction.
    public var fileAccessCeiling: ICloudChatFileAccessPolicy.Ceiling {
        get { self[FileAccessPart.self] }
        set { self[FileAccessPart.self] = self[FileAccessPart.self].intersecting(newValue) }
    }
    /// The enclosing tool act; nested receipts and terminal accounting retain its exact cause.
    public var act: String? {
        get { self[ToolActPart.self] }
        set { self[ToolActPart.self] = newValue }
    }
    /// The admitted client, for thoughts the turn's own code makes.
    public var client: (any LLMClient)? {
        get { self[ClientPart.self] }
        set { self[ClientPart.self] = newValue }
    }
    /// One output allowance shared by every provider request of the turn.
    public var tokenBudget: TurnTokenBudget? {
        get { self[TokenBudgetPart.self] }
        set { self[TokenBudgetPart.self] = newValue }
    }
    /// The tools this turn offers by name.
    public var offeredTools: Set<String>? {
        get { self[OfferedToolsPart.self] }
        set { self[OfferedToolsPart.self] = newValue }
    }
    /// Where a tool's capability note for this turn goes.
    public var capabilityNote: (@Sendable (String) -> Void)? {
        get { self[CapabilityNotePart.self] }
        set { self[CapabilityNotePart.self] = newValue }
    }
    /// The whole reply so far on an abnormal end, delivered before the error rethrows.
    public var partialReply: (@Sendable (String) async -> Void)? {
        get { self[PartialReplyPart.self] }
        set { self[PartialReplyPart.self] = newValue }
    }
    /// The model route admitted at the turn's boundary.
    public var admission: ModelAdmission? {
        get { self[AdmissionPart.self] }
        set { self[AdmissionPart.self] = newValue }
    }
    /// The gate-verified tool session, distinct from a provider's cache scope.
    public var verifiedSessionID: String? {
        get { self[VerifiedSessionPart.self] }
        set { self[VerifiedSessionPart.self] = newValue }
    }
    /// Who is driving the screen for this turn's tool calls: the verified tool session, which an
    /// ephemeral thought keeps after it clears its own provider session.
    public var windowDriver: PersonOnlyWindows.Driver? {
        (verifiedSessionID ?? session).map { PersonOnlyWindows.Driver(session: $0, turn: id) }
    }
}
