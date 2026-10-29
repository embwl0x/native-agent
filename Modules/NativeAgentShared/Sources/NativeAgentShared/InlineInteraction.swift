import Foundation

// Blueprint: | `InlineInteraction.swift` | `InlineInteraction`: durable card kind/state/scope, continuation and outcome contract shared by dispatch, transcript and renderers |

/// One durable conversation interaction: a need raised at the point of use
/// ("connect GitHub", "allow Desktop access", "which model for this image"),
/// rendered inline as a card, resolved by the EXISTING control, and left in
/// scrollback as the receipt.
///
/// This is the contract between three parties that never talk to each other
/// directly: the dispatch boundary that raises the need, the transcript that
/// persists it across relaunch, and the card that renders it. Display state
/// grants no authority; the resolver checks the canonical owner. Runtime
/// replay state follows the `Continuation` contract below.
///
/// Old transcripts decode: every field added after v1 is optional or has a
/// default, and an unknown `kind` or `state` decodes to `.unknown` rather
/// than failing the row.
public struct InlineInteraction: Codable, Sendable, Equatable, Identifiable {
    /// Wire version of this value. Bumped only for a shape change readers
    /// must notice; additive optional fields do not bump it.
    public static let currentVersion = 1

    // MARK: Kind

    /// The six control types. The card switches on THIS, never on a service
    /// name — adding a connector adds a registry row, not a card branch.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// `target` is a canonical connector ID ("slack", "telegram").
        case connector
        /// `target` is a canonical Mac capability/integration ID.
        /// `additionalTargets` carries the rest of a predictable chain.
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
            self = Scope(rawValue: raw) ?? .persistent
        }
    }

    // MARK: Access mode

    /// WHICH AXIS a permission need is asking for — the mode the blocked call
    /// actually wanted.
    ///
    /// A read that was refused must not be settled by granting write as well.
    /// The raise site knows which it was (a file READ, a file CHANGE), so it
    /// says so, the card says so on its scope line, and the grant writes only
    /// that axis where the owner has two of them to write.
    public enum AccessMode: String, Codable, Sendable, Equatable {
        case read
        case write
        /// The call needed both, or the raise site genuinely cannot tell.
        case readWrite = "read_write"

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = AccessMode(rawValue: raw) ?? .readWrite
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

    /// What an `.apiKey` card for a keyring secret (`target` "secret:<name>")
    /// asks the person to grant: where the value may go, and the sign-in
    /// NativeAgent runs in place of a paste when she supplied one. Public
    /// parameters only; the value never rides here.
    public struct SecretAsk: Codable, Sendable, Equatable {
        public var hosts: [String]
        public var programs: [String]
        public var signIn: SignIn?
        /// The person is asked to remove the secret instead of granting it.
        public var remove: Bool?
        /// Where it is kept for now and stops going once this grant is kept.
        public var stops: [String]?

        /// An OAuth authorization-code sign-in with PKCE through a loopback
        /// redirect, or with `device` in place of `authorize` a device sign-in
        /// (RFC 8628). `authorize` may carry extra query parameters of its own.
        /// A client secret is never here: the person types it on the card.
        public struct SignIn: Codable, Sendable, Equatable {
            public var authorize: String?
            /// The device authorization endpoint of a device sign-in.
            public var device: String?
            public var token: String
            public var clientID: String
            public var scopes: String?
            /// The registered loopback redirect, when the service needs an exact one.
            public var redirect: String?
            /// "basic" when the client authenticates at the token endpoint by HTTP Basic; nil in the body.
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

        /// Where it may go, said once: "api.example.com, program npx".
        public var line: String {
            (hosts + programs.map { "program \($0)" }).joined(separator: ", ")
        }
    }

    // MARK: Outcome / state

    /// What actually happened, verified by the canonical owner. Bounded and
    /// credential-free: an ID and a sentence, never a token or a key.
    public struct Outcome: Codable, Sendable, Equatable {
        /// Selected option / account / model / capability ID, when there is one.
        public var selection: String?
        /// One line for the settled receipt ("GitHub connected").
        public var summary: String
        /// Scope the resolution was applied at (model choice).
        public var scope: Scope?

        public init(selection: String? = nil, summary: String, scope: Scope? = nil) {
            self.selection = selection
            self.summary = summary
            self.scope = scope
        }
    }

    /// `pending → running → settled | declined | failed`.
    ///
    /// `failed` never retries on its own; the card keeps a retry control and
    /// the interaction never reads as connected.
    public enum State: Sendable, Equatable {
        case pending
        case running
        case settled(Outcome)
        case declined
        case failed(reason: String)
        case stopped(reason: String)
        /// Terminal replacement by a newer identical ask preserves one live card per ask.
        case superseded
        /// A state this build does not know (forward compatibility).
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

        /// True while the originating request is still waiting on a person.
        public var isOpen: Bool {
            switch self {
            case .pending, .running: return true
            default: return false
            }
        }

        /// True once the interaction has reached a terminal state; the
        /// continuation may run at most once, from here.
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

    // MARK: Continuation

    /// Runtime-owned durable record of a suspended request, including captured
    /// replay input. The mobile card projection omits it; resolution still
    /// checks canonical owners and signature provenance.
    public struct Continuation: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable, Equatable {
            /// Replay the captured tool call through the ordinary gated
            /// dispatcher once setup is verified.
            case retryBlockedTool = "retry_blocked_tool"
            /// A direct request resumes the turn without replaying a tool.
            case continueTurn = "continue_turn"

            public init(from decoder: any Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Mode(rawValue: raw) ?? .continueTurn
            }
        }

        public enum ResumeState: String, Codable, Sendable, Equatable {
            case waiting
            /// A resume claim is held; duplicate clicks and Mac/phone races
            /// cannot start a second turn.
            case claimed
            /// The "I cannot tell" state, written to disk before anything
            /// irreversible is attempted — the blocked call is about to be
            /// DISPATCHED, or the continuation turn is about to be ADMITTED.
            /// Either way a row found in it at relaunch is never auto-replayed,
            /// because nothing readable from here can tell whether the call
            /// landed or the turn started: it becomes a failed card the person
            /// retries by hand, or nothing at all.
            ///
            /// Deliberately ONE wire value for both. A second one would decode
            /// as `.waiting` on an older build — which reclaims and starts a
            /// duplicate continuation, exactly what this state exists to stop.
            case replaying
            case resumed
            case stopped
            /// Dismissal, Stop, or a cleared conversation.
            case invalidated

            public init(from decoder: any Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = ResumeState(rawValue: raw) ?? .waiting
            }
        }

        public var originRunId: String?
        public var lifeID: String?
        public var reason: String?
        public var toolCallId: String?
        public var toolName: String?
        /// Exact unredacted blocked-call arguments, replayed through the ordinary
        /// gate. Nil continues the conversation without a captured-call replay.
        public var toolArgumentsJSON: String?
        public var mode: Mode
        public var state: ResumeState
        /// The person's text when no provider accepted the request and no user
        /// row was persisted; other needs resume from the saved conversation.
        public var resumeText: String?
        /// Stable ID for the continuation turn, so a duplicate resolve from a
        /// second surface lands on the same claim instead of a second turn.
        public var resumeRunId: String
        /// When the blocked call was ACTUALLY replayed, recorded durably
        /// BEFORE the continuation turn is admitted.
        ///
        /// The replay is an effect on the world; turn admission can still be
        /// refused afterwards, and a refusal puts the claim back to `waiting`.
        /// Without this checkpoint the next tap would replay the same effect a
        /// second time. Never written for a replay that failed — a failed
        /// replay did nothing, so it is honest to let a retry run it.
        public var replayedAt: Date?
        /// What that replay returned, held so a retried continuation tells the
        /// model the same thing instead of re-making the call.
        public var replayedResult: String?
        /// Proof that the turn which raised this card was signature-verified
        /// by its transport — a MAC over `resumeRunId`, minted from the live
        /// pairing material at raise time and RE-CHECKED against that same
        /// material at replay.
        ///
        /// Not a flag. A persisted boolean saying "this was signed" is a
        /// transcript granting authority, which is exactly what the envelope
        /// refuses to do; this is a token only the holder of the pairing
        /// secret could have written, and it stops verifying the moment that
        /// secret changes (the phone was unpaired) — at which point the card
        /// fails honestly instead of replaying unsigned.
        public var signatureReceipt: String?
        /// The turn that CARRIED this continuation, when the card was settled
        /// from inside a turn already running on the session. That turn is the
        /// continuation — the result was handed back to it — so no second turn
        /// was ever started, and this records which one took it.
        public var resumedByTurnId: String?
        /// Peer provenance of the suspended turn. Nil on older cards.
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
    /// Bumped on every transition. A resolve carrying a stale revision is
    /// refused, which is what makes duplicate clicks safe.
    public var revision: Int
    public var kind: Kind
    /// Canonical ID of the thing being connected/enabled/chosen. Empty for
    /// `choose`.
    public var target: String
    /// The rest of a predictable chain: when the checker can know a request
    /// needs Mac Control AND Desktop access, it raises ONE need listing both
    /// and the person grants once.
    public var additionalTargets: [String]
    /// The axis a `.permission` need is asking for. nil on every other kind,
    /// and on transcripts written before this field existed.
    public var mode: AccessMode?
    public var title: String
    /// One sentence explaining why this is being asked here and now.
    public var why: String
    public var primaryActionLabel: String
    public var secondaryActionLabel: String?
    /// REQUIRED. Every decline says what happens next — the card never leaves
    /// the person guessing what they are giving up.
    public var declineConsequence: String
    /// Permissions say how long they last: "Stays on until you turn it off in
    /// Trust."
    public var persistenceNote: String?
    /// One sentence above the card without repeating its rows; nil uses `textLaneProse`.
    public var cardProse: String?
    public var options: [Option]
    /// Scope the PRIMARY action applies at; the secondary applies the other.
    public var primaryScope: Scope?
    public var state: State
    public var createdAt: Date
    public var settledAt: Date?
    public var continuation: Continuation?
    /// A keyring secret's ask; nil on every other card.
    public var secret: SecretAsk?

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

    /// Every capability this interaction asks for, primary first. One grant
    /// covers the whole list.
    public var allTargets: [String] {
        target.isEmpty ? additionalTargets : [target] + additionalTargets
    }

    /// The card, said out loud.
    ///
    /// A card is a REPLY, not decoration: it carries the reason, the way
    /// forward, and what saying no costs. Only the Mac and iPhone chat UIs can
    /// draw it. Every other route — the bridge, Telegram, Slack — has text and
    /// nothing else, and a turn that parks on a card with no prose reaches them
    /// as silence: "stream ended without final reply" on the bridge, and an
    /// empty-reply notice on Telegram. So the same three things the card shows
    /// are said in one sentence instead, and the person can answer either one.
    public var textLaneProse: String {
        var line = why.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = line.last, !".!?".contains(last) { line += "." }
        let action = primaryActionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return line }
        if !line.isEmpty { line += " " }
        line += "\(action) in the app, or say \u{201C}not now\u{201D}"
        // Lowercase the consequence's lead when joining it mid-sentence.
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

    /// Fixed copy shared by this file and the inline interaction registry.
    public enum ConsequenceCopy {
        /// Every card-lane sentence ends here.
        public static let keepGoingSuffix = "or tell me not now and I'll keep going."
        public static let connectorCarryOn = "I'll carry on with whatever else I can reach."
        public static let permissionLeaveAlone = "alone and tell you what I couldn't do."
        public static let modelScopedSkip = "I'll skip this one and leave your "
        public static let modelStopHere = "I'll stop here rather than guess which model you want."
        public static let apiKeyNothingChanges = "; nothing else changes."
        public static let capabilityStaysOff = "It stays off and I'll get as far as I can without it."
        public static let trustSwitchedOff = "is switched off in Trust."
    }

    /// Lowercase a sentence folded into the middle of another one \u{2014} except
    /// where the capital is the word's own: the pronoun "I" and its
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
    //
    // Transitions are value-level and always bump `revision`; the resolver
    // owns durability and the single-continuation claim.

    public func running() -> InlineInteraction {
        var copy = self
        copy.state = .running
        copy.revision += 1
        return copy
    }

    public func settled(_ outcome: Outcome, at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .settled(outcome)
        copy.settledAt = date
        copy.revision += 1
        return copy
    }

    public func declined(at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .declined
        copy.settledAt = date
        copy.revision += 1
        return copy
    }

    /// Replaced by a newer, identical ask. Terminal, so the continuation this
    /// card was holding can never start a turn: the card the person is looking
    /// at owns that now.
    public func superseded(at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .superseded
        copy.settledAt = date
        copy.revision += 1
        copy.continuation?.state = .invalidated
        return copy
    }

    public func failed(reason: String, at date: Date = Date()) -> InlineInteraction {
        var copy = self
        copy.state = .failed(reason: reason)
        copy.settledAt = date
        copy.revision += 1
        return copy
    }

    // MARK: Codable
    //
    // Hand-written only where the shape needs it (`state` is a discriminated
    // object). Every optional/defaulted field decodes from a v1 file that
    // never had it — a transcript written before this build must still render.

    private enum CodingKeys: String, CodingKey {
        case version, id, revision, kind, target, additionalTargets, mode, title, why
        case primaryActionLabel, secondaryActionLabel, declineConsequence
        case persistenceNote, cardProse, options, primaryScope, state, createdAt, settledAt
        case continuation, secret
    }

    private struct WireState: Codable {
        var name: String
        var outcome: Outcome?
        var reason: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? InlineInteraction.currentVersion
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        kind = try container.decode(Kind.self, forKey: .kind)
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        additionalTargets = try container.decodeIfPresent([String].self, forKey: .additionalTargets) ?? []
        mode = try container.decodeIfPresent(AccessMode.self, forKey: .mode)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        why = try container.decodeIfPresent(String.self, forKey: .why) ?? ""
        primaryActionLabel = try container.decodeIfPresent(String.self, forKey: .primaryActionLabel) ?? "Continue"
        secondaryActionLabel = try container.decodeIfPresent(String.self, forKey: .secondaryActionLabel)
        declineConsequence = try container.decodeIfPresent(String.self, forKey: .declineConsequence) ?? ""
        persistenceNote = try container.decodeIfPresent(String.self, forKey: .persistenceNote)
        cardProse = try container.decodeIfPresent(String.self, forKey: .cardProse)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
        primaryScope = try container.decodeIfPresent(Scope.self, forKey: .primaryScope)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        settledAt = try container.decodeIfPresent(Date.self, forKey: .settledAt)
        continuation = try container.decodeIfPresent(Continuation.self, forKey: .continuation)
        secret = try container.decodeIfPresent(SecretAsk.self, forKey: .secret)
        let wire = try container.decodeIfPresent(WireState.self, forKey: .state)
            ?? WireState(name: "pending", outcome: nil, reason: nil)
        switch wire.name {
        case "pending": state = .pending
        case "running": state = .running
        case "settled":
            // A settled state whose outcome did not survive is still settled;
            // an empty receipt is honest, a re-opened card is not.
            state = .settled(wire.outcome ?? Outcome(summary: ""))
        case "declined": state = .declined
        case "failed": state = .failed(reason: wire.reason ?? "")
        case "stopped": state = .stopped(reason: wire.reason ?? "")
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

/// Wire constants shared by the writer, the renderer, and the resolver, so
/// none of them re-guesses the other's spelling.
public enum InlineInteractionWire {
    /// Posted only after a durable card write; object is its originating session.
    public static let changedNotification = Notification.Name("NativeAgent.inlineInteractionChanged")
    /// `metadata.kind` on the persisted `role: "tool"` row. PRESERVED after
    /// settlement, so "GitHub connected" stays a compact card in scrollback.
    public static let transcriptKind = "inline_interaction"
    /// `metadata.interaction` — the encoded `InlineInteraction`.
    public static let metadataKey = "interaction"
    /// The tool-result `status` a raised need carries.
    public static let waitingStatus = "needs_input"
    /// The tool-result key holding the raised need.
    public static let needsKey = "needs"
    /// The single lazy agent-callable tool.
    public static let toolName = "request_interaction"

    /// Canonical JSON encoder/decoder for the transcript: ISO-8601 dates so a
    /// row is readable, diffable, and stable across surfaces.
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
