import Foundation

// Blueprint: | `InlineInteraction.swift` | `InlineInteraction`: durable card/continuation contract; owners retain authority |

/// Display state grants no authority; resolution checks the canonical owner. Dispatch, transcript and renderers share this durable receipt. Unknown
/// kinds/states remain inert evidence; identity, action and continuation must satisfy the current contract.
public struct InlineInteraction: Codable, Sendable, Equatable, Identifiable {
    /// Wire version of this value. Bumped only for a shape change readers must notice; additive optional fields do not bump it.
    public static let currentVersion = 1

    // MARK: Kind

    /// Cards branch on control kind, never service name, so connectors need only a registry row.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// `target` is a canonical connector ID ("slack", "telegram").
        case connector
        /// `target` is a canonical Mac capability/integration ID. `additionalTargets` carries the rest of a predictable chain.
        case permission
        /// `target` is an existing Providers group ID.
        case modelChoice = "model_choice"
        /// `target` is a canonical provider ID.
        case apiKey = "api_key"
        /// `target` is an existing, user-configurable capability flag ID.
        case capability
        /// A bounded question; `options` carries the answers.
        case choose
        /// A kind this build does not know. Renders unavailable.
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    // MARK: Options

    /// One answer in a `choose`, or one model in a `model_choice`.
    public struct Option: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String?

        public init(id: String, label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    // MARK: Scope

    /// A request-only model choice never changes the Work group's stored choice.
    public enum Scope: String, Codable, Sendable, Equatable {
        /// Bind the choice to the resumed request only; no stored change.
        case thisRequestOnly = "this_request_only"
        /// Write the choice through the group's own owner, as Providers does.
        case persistent

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let value = Scope(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Unknown Scope: \(raw)"))
            }
            self = value
        }
    }

    // MARK: Access mode

    /// A refused read must not grant write access. The raise site carries the requested axis through card scope to the permission owner.
    public enum AccessMode: String, Codable, Sendable, Equatable {
        case read
        case write
        /// The call needed both, or the raise site genuinely cannot tell.
        case readWrite = "read_write"

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let value = AccessMode(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Unknown AccessMode: \(raw)"))
            }
            self = value
        }

        public var wantsRead: Bool { self != .write }
        public var wantsWrite: Bool { self != .read }

        /// The phrase the card uses on its scope line.
        public var phrase: String {
            switch self {
            case .read: return "read only"
            case .write: return "write only"
            case .readWrite: return "read and write"
            }
        }
    }

    // MARK: Secret

    /// Secret grants carry destinations and optional sign-in parameters, never the secret value.
    public struct SecretAsk: Codable, Sendable, Equatable {
        public var hosts: [String]
        public var programs: [String]
        public var signIn: SignIn?
        /// The person is asked to remove the secret instead of granting it.
        public var remove: Bool?
        /// Where it is kept for now and stops going once this grant is kept.
        public var stops: [String]?

        /// An OAuth authorization-code sign-in with PKCE through a loopback redirect, or with `device` in place of `authorize` a device sign-in (RFC 8628).
        /// `authorize` may carry extra query parameters of its own. A client secret is never here: the person types it on the card.
        public struct SignIn: Codable, Sendable, Equatable {
            public var authorize: String?
            /// The device authorization endpoint of a device sign-in.
            public var device: String?
            public var token: String
            public var clientID: String
            public var scopes: String?
            /// The registered loopback redirect, when the service needs an exact one.
            public var redirect: String?
            /// "basic" selects HTTP Basic; nil sends credentials in the token request body.
            public var clientAuth: String?
            public init(authorize: String?, device: String? = nil, token: String, clientID: String, scopes: String? = nil, redirect: String? = nil,
                        clientAuth: String? = nil) {
                self.authorize = authorize; self.device = device; self.token = token; self.clientID = clientID
                self.scopes = scopes; self.redirect = redirect; self.clientAuth = clientAuth
            }
        }

        public init(hosts: [String], programs: [String], signIn: SignIn? = nil, remove: Bool = false, stops: [String] = []) {
            self.hosts = hosts; self.programs = programs; self.signIn = signIn; self.remove = remove ? true : nil
            self.stops = stops.isEmpty ? nil : stops
        }

        public var line: String {
            (hosts + programs.map { "program \($0)" }).joined(separator: ", ")
        }
    }

    // MARK: Outcome / state

    /// Canonical owners verify outcomes; receipts contain only bounded, credential-free IDs and prose.
    public struct Outcome: Codable, Sendable, Equatable {
        public var selection: String?
        public var summary: String
        public var scope: Scope?

        public init(selection: String? = nil, summary: String, scope: Scope? = nil) {
            self.selection = selection
            self.summary = summary
            self.scope = scope
        }
    }

    /// Failed cards require an explicit retry and never read as connected.
    public enum State: Sendable, Equatable {
        case pending
        case running
        case settled(Outcome)
        case declined
        case failed(reason: String)
        case stopped(reason: String)
        /// Terminal replacement by a newer identical ask preserves one live card per ask.
        case superseded
        /// Unknown states remain inert for forward compatibility.
        case unknown(String)

        public var name: String {
            switch self {
            case .pending: return "pending"
            case .running: return "running"
            case .settled: return "settled"
            case .declined: return "declined"
            case .failed: return "failed"
            case .stopped: return "stopped"
            case .superseded: return "superseded"
            case .unknown(let raw): return raw
            }
        }

        public var isOpen: Bool {
            switch self {
            case .pending, .running: return true
            default: return false
            }
        }

        /// A terminal continuation may run at most once.
        public var isTerminal: Bool { !isOpen && !isUnknown }

        public var isUnknown: Bool {
            if case .unknown = self { return true }
            return false
        }

        public var outcome: Outcome? {
            if case .settled(let outcome) = self { return outcome }
            return nil
        }

        public var failureReason: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }

        public var isRetryable: Bool {
            switch self {
            case .failed, .stopped: return true
            default: return false
            }
        }
    }

    // MARK: Waiting on

    /// The one thing a running permission card waits on: one of its own targets still off in macOS, or the one restart that makes its launch-applied grants
    /// take effect. Written only by the card's own walk; every other transition clears it. On the wire it is the target ID, or "restart".
    public enum WaitingOn: Codable, Sendable, Equatable {
        /// A card target (privacy:<grant>, applescript:<bundle_id>, or an integration ID with a macOS grant behind it).
        case target(String)
        case restart

        static let restartWire = "restart"

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            guard !raw.isEmpty else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "A card cannot wait on an empty target.")
            }
            self = raw == Self.restartWire ? .restart : .target(raw)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .target(let id): try c.encode(id)
            case .restart: try c.encode(Self.restartWire)
            }
        }
    }

    // MARK: Continuation

    /// Runtime-owned durable record of a suspended request, including captured replay input. The mobile card projection omits it; resolution still checks
    /// canonical owners and signature provenance.
    public struct Continuation: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable, Equatable {
            /// Replay the captured tool call through the ordinary gated dispatcher once setup is verified.
            case retryBlockedTool = "retry_blocked_tool"
            /// A direct request resumes the turn without replaying a tool.
            case continueTurn = "continue_turn"

            public init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                let raw = try c.decode(String.self)
                guard let value = Mode(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported continuation mode: \(raw)")
                }
                self = value
            }
        }

        public enum ResumeState: String, Codable, Sendable, Equatable {
            case waiting
            /// A resume claim is held; duplicate clicks and Mac/phone races cannot start a second turn.
            case claimed
            /// Persist before dispatch or turn admission. After relaunch, an uncertain effect is never replayed automatically because its record cannot
            /// prove whether it landed.
            case replaying
            case resumed
            case stopped
            case invalidated

            public init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                let raw = try c.decode(String.self)
                guard let value = ResumeState(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported continuation state: \(raw)")
                }
                self = value
            }
        }

        public var originRunId: String?
        /// The act that raised this card; only that exact turn may consume its hand-back.
        public var originTurnId: String?
        public var lifeID: String?
        public var reason: String?
        public var toolCallId: String?
        public var toolName: String?
        /// Exact unredacted blocked-call arguments, replayed through the ordinary gate. Nil continues the conversation without a captured-call replay.
        public var toolArgumentsJSON: String?
        public var mode: Mode
        public var state: ResumeState
        /// The person's text when no provider accepted the request and no user row was persisted; other needs resume from the saved conversation.
        public var resumeText: String?
        /// Stable ID for the continuation turn, so a duplicate resolve from a second surface lands on the same claim instead of a second turn.
        public var resumeRunId: String
        /// Persist successful replay before turn admission: a refused admission must not make the next tap repeat the effect. Failed replays never write
        /// this checkpoint.
        public var replayedAt: Date?
        /// What that replay returned, held so a retried continuation tells the model the same thing instead of re-making the call.
        public var replayedResult: String?
        /// A MAC over `resumeRunId` proves transport verification. Recheck against live pairing material at replay so unpairing revokes authority; a
        /// persisted Boolean cannot confer it.
        public var signatureReceipt: String?
        /// A running turn that receives this result owns the continuation; recording its identity prevents a second turn.
        public var resumedByTurnId: String?
        /// Peer provenance of the suspended turn; nil carries no peer evidence.
        public var peerSources: [String]?
        public var elevatedPeerSources: [String]?

        public init(
            originRunId: String? = nil,
            toolCallId: String? = nil,
            toolName: String? = nil,
            toolArgumentsJSON: String? = nil,
            mode: Mode,
            state: ResumeState = .waiting,
            resumeRunId: String,
            resumeText: String? = nil,
            replayedAt: Date? = nil,
            replayedResult: String? = nil,
            signatureReceipt: String? = nil,
            resumedByTurnId: String? = nil,
            peerSources: [String]? = nil,
            elevatedPeerSources: [String]? = nil
        ) {
            self.peerSources = peerSources
            self.elevatedPeerSources = elevatedPeerSources
            self.resumedByTurnId = resumedByTurnId
            self.replayedAt = replayedAt
            self.replayedResult = replayedResult
            self.signatureReceipt = signatureReceipt
            self.originRunId = originRunId
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.toolArgumentsJSON = toolArgumentsJSON
            self.mode = mode
            self.state = state
            self.resumeRunId = resumeRunId
            self.resumeText = resumeText
        }
    }

    // MARK: Stored properties

    public var version: Int
    public var id: String
    /// Bumped on every transition. A resolve carrying a stale revision is refused, which is what makes duplicate clicks safe.
    public var revision: Int
    public var kind: Kind
    /// Canonical ID of the thing being connected/enabled/chosen. Empty for `choose`.
    public var target: String
    /// The rest of a predictable chain: when the checker can know a request needs Mac Control AND Desktop access, it raises ONE need listing both and the
    /// person grants once.
    public var additionalTargets: [String]
    /// Permission needs carry the requested axis; other kinds carry none.
    public var mode: AccessMode?
    public var title: String
    public var why: String
    public var primaryActionLabel: String
    public var secondaryActionLabel: String?
    /// Every decline explains its consequence so the person knows what they give up.
    public var declineConsequence: String
    public var persistenceNote: String?
    /// One sentence above the card without repeating its rows; nil uses `textLaneProse`.
    public var cardProse: String?
    public var options: [Option]
    /// The primary and secondary actions apply at different scopes.
    public var primaryScope: Scope?
    public var state: State
    public var createdAt: Date
    public var settledAt: Date?
    public var continuation: Continuation?
    public var secret: SecretAsk?
    /// Set while a running permission card walks its grants; it is also what carries the card across its own restart.
    public var waitingOn: WaitingOn?

    // MARK: Init

    public init(
        version: Int = InlineInteraction.currentVersion,
        id: String = UUID().uuidString.lowercased(),
        revision: Int = 1,
        kind: Kind,
        target: String,
        additionalTargets: [String] = [],
        mode: AccessMode? = nil,
        title: String,
        why: String,
        primaryActionLabel: String,
        secondaryActionLabel: String? = nil,
        declineConsequence: String,
        persistenceNote: String? = nil,
        cardProse: String? = nil,
        options: [Option] = [],
        primaryScope: Scope? = nil,
        state: State = .pending,
        createdAt: Date = Date(),
        settledAt: Date? = nil,
        continuation: Continuation? = nil,
        secret: SecretAsk? = nil
    ) {
        self.version = version
        self.id = id
        self.revision = revision
        self.kind = kind
        self.target = target
        self.additionalTargets = additionalTargets
        self.mode = mode
        self.title = title
        self.why = why
        self.primaryActionLabel = primaryActionLabel
        self.secondaryActionLabel = secondaryActionLabel
        self.declineConsequence = declineConsequence
        self.persistenceNote = persistenceNote
        self.cardProse = cardProse
        self.options = options
        self.primaryScope = primaryScope
        self.state = state
        self.createdAt = createdAt
        self.settledAt = settledAt
        self.continuation = continuation
        self.secret = secret
    }

    /// One grant covers the primary capability and its predictable chain.
    public var allTargets: [String] {
        target.isEmpty ? additionalTargets : [target] + additionalTargets
    }

    /// Text-only routes need the card’s reason, remedy and decline consequence as prose; otherwise a parked turn reaches them as silence.
    public var textLaneProse: String {
        var line = why.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = line.last, !".!?".contains(last) { line += "." }
        let action = primaryActionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return line }
        if !line.isEmpty { line += " " }
        line += "\(action) in the app, or say \u{201C}not now\u{201D}"
        var consequence = InlineInteraction.lowercasedLead(
            declineConsequence.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !consequence.isEmpty else { return line + "." }
        if let last = consequence.last, !".!?".contains(last) { consequence += "." }
        return line + " \u{2014} " + consequence
    }

    /// Card surfaces use one sentence because the card already carries the details.
    public var cardLaneProse: String {
        let written = (cardProse ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return written.isEmpty ? textLaneProse : written
    }

    public enum ConsequenceCopy {
        public static let keepGoingSuffix = "or tell me not now and I'll keep going."
        public static let connectorCarryOn = "I'll carry on with whatever else I can reach."
        public static let permissionLeaveAlone = "alone and tell you what I couldn't do."
        public static let modelScopedSkip = "I'll skip this one and leave your "
        public static let modelStopHere = "I'll stop here rather than guess which model you want."
        public static let apiKeyNothingChanges = "; nothing else changes."
        public static let capabilityStaysOff = "It stays off and I'll get as far as I can without it."
        public static let trustSwitchedOff = "is switched off in Trust."
    }

    /// Lowercase a sentence folded into the middle of another one \u{2014} except where the capital is the word's own: the pronoun "I" and its
    /// contractions, and a name carrying a second capital ("OpenAI").
    public static func lowercasedLead(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let rest = text.dropFirst()
        if first == "I", rest.first.map({ $0 == "\u{2019}" || $0 == "'" || $0 == " " }) ?? true {
            return text
        }
        let word = text.prefix { !$0.isWhitespace }
        if word.dropFirst().contains(where: { $0.isUppercase }) { return text }
        return first.lowercased() + rest
    }

    // MARK: Transitions
    // Transitions are value-level and always bump `revision`; the resolver owns durability and the single-continuation claim.

    /// A tap starts a fresh walk; the walk records what it waits on at its first read.
    public func running() -> InlineInteraction {
        var copy = self
        copy.state = .running
        copy.revision += 1
        copy.waitingOn = nil
        return copy
    }

    public func settled(_ outcome: Outcome, at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .settled(outcome)
        copy.settledAt = date
        copy.revision += 1
        copy.waitingOn = nil
        return copy
    }

    public func declined(at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .declined
        copy.settledAt = date
        copy.revision += 1
        copy.waitingOn = nil
        return copy
    }

    /// Only the newest identical ask owns the continuation; a superseded card must never start a turn.
    public func superseded(at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .superseded
        copy.settledAt = date
        copy.revision += 1
        copy.continuation?.state = .invalidated
        copy.waitingOn = nil
        return copy
    }

    public func failed(reason: String, at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .failed(reason: reason)
        copy.settledAt = date
        copy.revision += 1
        copy.waitingOn = nil
        return copy
    }

    // MARK: Codable
    // `state` is a discriminated object. Missing core evidence never creates an executable pending card; optional content remains optional.

    private enum CodingKeys: String, CodingKey {
        case version, id, revision, kind, target, additionalTargets, mode, title, why
        case primaryActionLabel, secondaryActionLabel, declineConsequence
        case persistenceNote, cardProse, options, primaryScope, state, createdAt, settledAt
        case continuation, secret, waitingOn
    }

    private struct WireState: Codable {
        var name: String
        var outcome: Outcome?
        var reason: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == InlineInteraction.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported interaction version \(version)")
        }
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        kind = try container.decode(Kind.self, forKey: .kind)
        target = try container.decode(String.self, forKey: .target)
        additionalTargets = try container.decodeIfPresent([String].self, forKey: .additionalTargets) ?? []
        mode = try container.decodeIfPresent(AccessMode.self, forKey: .mode)
        title = try container.decode(String.self, forKey: .title)
        why = try container.decode(String.self, forKey: .why)
        primaryActionLabel = try container.decode(String.self, forKey: .primaryActionLabel)
        secondaryActionLabel = try container.decodeIfPresent(String.self, forKey: .secondaryActionLabel)
        declineConsequence = try container.decode(String.self, forKey: .declineConsequence)
        persistenceNote = try container.decodeIfPresent(String.self, forKey: .persistenceNote)
        cardProse = try container.decodeIfPresent(String.self, forKey: .cardProse)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
        primaryScope = try container.decodeIfPresent(Scope.self, forKey: .primaryScope)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        settledAt = try container.decodeIfPresent(Date.self, forKey: .settledAt)
        continuation = try container.decodeIfPresent(Continuation.self, forKey: .continuation)
        secret = try container.decodeIfPresent(SecretAsk.self, forKey: .secret)
        waitingOn = try container.decodeIfPresent(WaitingOn.self, forKey: .waitingOn)
        let wire = try container.decode(WireState.self, forKey: .state)
        switch wire.name {
        case "pending": state = .pending
        case "running": state = .running
        case "settled":
            guard let outcome = wire.outcome else {
                throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "Settled interaction has no outcome")
            }
            state = .settled(outcome)
        case "declined": state = .declined
        case "failed", "stopped":
            guard let reason = wire.reason else {
                throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "Terminal interaction has no reason")
            }
            state = wire.name == "failed" ? .failed(reason: reason) : .stopped(reason: reason)
        case "superseded": state = .superseded
        default: state = .unknown(wire.name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        try container.encode(kind, forKey: .kind)
        try container.encode(target, forKey: .target)
        if !additionalTargets.isEmpty {
            try container.encode(additionalTargets, forKey: .additionalTargets)
        }
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encode(title, forKey: .title)
        try container.encode(why, forKey: .why)
        try container.encode(primaryActionLabel, forKey: .primaryActionLabel)
        try container.encodeIfPresent(secondaryActionLabel, forKey: .secondaryActionLabel)
        try container.encode(declineConsequence, forKey: .declineConsequence)
        try container.encodeIfPresent(persistenceNote, forKey: .persistenceNote)
        try container.encodeIfPresent(cardProse, forKey: .cardProse)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
        try container.encodeIfPresent(primaryScope, forKey: .primaryScope)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(settledAt, forKey: .settledAt)
        try container.encodeIfPresent(continuation, forKey: .continuation)
        try container.encodeIfPresent(secret, forKey: .secret)
        try container.encodeIfPresent(waitingOn, forKey: .waitingOn)
        let wire: WireState
        switch state {
        case .pending: wire = WireState(name: "pending", outcome: nil, reason: nil)
        case .running: wire = WireState(name: "running", outcome: nil, reason: nil)
        case .settled(let outcome): wire = WireState(name: "settled", outcome: outcome, reason: nil)
        case .declined: wire = WireState(name: "declined", outcome: nil, reason: nil)
        case .superseded: wire = WireState(name: "superseded", outcome: nil, reason: nil)
        case .failed(let reason): wire = WireState(name: "failed", outcome: nil, reason: reason)
        case .stopped(let reason): wire = WireState(name: "stopped", outcome: nil, reason: reason)
        case .unknown(let raw): wire = WireState(name: raw, outcome: nil, reason: nil)
        }
        try container.encode(wire, forKey: .state)
    }
}

// MARK: - Transcript vocabulary

/// Wire constants shared by the writer, the renderer, and the resolver, so none of them re-guesses the other's spelling.
public enum InlineInteractionWire {
    /// Posted only after a durable card write; object is its originating session.
    public static let changedNotification = Notification.Name("NativeAgent.inlineInteractionChanged")
    /// `metadata.kind` on the persisted `role: "tool"` row. PRESERVED after settlement, so "GitHub connected" stays a compact card in scrollback.
    public static let transcriptKind = "inline_interaction"
    public static let metadataKey = "interaction"
    public static let waitingStatus = "needs_input"
    public static let needsKey = "needs"
    public static let toolName = "request_interaction"

    /// Canonical JSON encoder/decoder for the transcript: ISO-8601 dates so a row is readable, diffable, and stable across surfaces.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
