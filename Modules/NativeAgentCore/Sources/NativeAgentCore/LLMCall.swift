import Foundation
// Blueprint: | `LLMCall.swift` | `LLMCall`: explicit call identity and request shape shared by all `LLMClient` methods |

/// One model call's identity and request shape, handed to the client with the
/// call. A provider adapter reads everything it routes on from here, so a
/// stream or task it starts later reads the same call.
public struct LLMCall: Sendable {
    /// The turn this call serves; nil for work outside any turn (a dream, a sweep).
    public var turn: Turn? {
        didSet { standaloneAdmission = nil }
    }
    private var parts: [ObjectIdentifier: any Sendable] = [:]
    /// A standalone call owns its route; a turn call keeps the route only on the turn.
    private var standaloneAdmission: ModelAdmission?
    /// This request's wire activity and cancellation-independent callbacks.
    public var lifetime = ProviderRequestLifetime()
    /// The calling surface: routing and cache semantics, and telemetry.
    public var surface: String
    /// The named purpose, carried into telemetry and receipts.
    public var purpose: String
    /// The provider's conversation/cache scope; it can differ from the turn's verified session.
    public var session: String?
    /// Only the conversation's own requests calibrate its context; secondary calls stay unmeasured.
    public var conversationRequest = false
    /// A clean provider terminal may complete this request without answer text or calls.
    public var allowsSilentCompletion = false
    /// Payload-free replay recipe from the request builder.
    public var requestPlan: Data?
    /// Stable/dynamic split of the system prompt; a caching layout, never content.
    public var systemSegments: SystemPromptSegments?
    /// Index of the current turn's user message in the array handed to the adapter.
    public var currentUserIndex: Int?
    /// A real generation for an explicit preview: nothing learns from it.
    public var preview = false
    /// Trace root for this call; nil resolves the default data root.
    public var traceDataRoot: URL?

    public init(turn: Turn?, surface: String, purpose: String, session: String? = nil) {
        self.turn = turn
        self.surface = surface
        self.purpose = purpose
        self.session = session ?? turn?.session
    }

    /// The route admitted for this call; a turn call stores it only on that turn.
    public var admission: ModelAdmission? {
        get { if let turn { return turn.admission }; return standaloneAdmission }
        set { if turn != nil { turn?.admission = newValue } else { standaloneAdmission = newValue } }
    }

    /// Owner-defined operation data, held with this call through streams and callbacks.
    public subscript<Part: LLMCallPart>(_ part: Part.Type) -> Part.Value {
        get { parts[ObjectIdentifier(part)] as? Part.Value ?? Part.unset }
        set { parts[ObjectIdentifier(part)] = newValue }
    }
}

/// A call owner's explicit request state; distinct from state shared by a whole turn.
public protocol LLMCallPart {
    associatedtype Value: Sendable
    static var unset: Value { get }
}
