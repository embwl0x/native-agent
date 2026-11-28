import Foundation
// Blueprint: | `FacePresentations.swift` | Finished renderer feed values; read state distinguishes waiting, known empty and unavailable |

public enum FaceReadState: Codable, Sendable, Equatable {
    case waiting(on: String)
    case ready
    case unavailable(WireFailure)
}
public enum FaceContextFlowHealth: String, Codable, Sendable { case off, ready, unreadable, failed }
public enum FaceVoicePhase: String, Codable, Sendable { case idle, listening, recognizing, speaking, finished, cancelled }

public struct MessageActionFace: Codable, Sendable, Equatable {
    public var message: String
    public var canRetry: Bool
    public var canRemember: Bool
    public init(message: String, canRetry: Bool, canRemember: Bool) {
        self.message = message
        self.canRetry = canRetry
        self.canRemember = canRemember
    }
}

public struct FaceResolvedAttachment: Codable, Sendable, Equatable {
    public var id: String
    public var message: String
    public var kind: String
    public var title: String
    public var text: String?
    public var resource: ResourceGrant?
    public var card: PartFace?
    public var secureCard: SecureCardFace?
    public var failure: WireFailure?
    /// An image's saved preview, drawn at once at its own size, as the original window drew it.
    public var preview: TranscriptAttachmentPreview?
    public init(id: String, message: String, kind: String, title: String, text: String?, resource: ResourceGrant?, card: PartFace?,
                failure: WireFailure?, secureCard: SecureCardFace? = nil, preview: TranscriptAttachmentPreview? = nil) {
        self.id = id
        self.message = message
        self.kind = kind
        self.title = title
        self.text = text
        self.resource = resource
        self.card = card
        self.secureCard = secureCard
        self.failure = failure
        self.preview = preview
    }
}

extension PartFace.Row {
    /// A card's answers where it shows in its own conversation (Mac or phone): this Inbox row's own answers, same ids and door calls, so a
    /// press there is the Inbox's press. Housekeeping (read, archive, dismiss) stays the Inbox page's; opening the card is no answer where
    /// the card already is; Not now is one of the card's answers, drawn plain and never asked twice. Nil when nothing is left to answer.
    public var cardAnswers: [PartFace.Action]? {
        let answers = (actions ?? []).filter { $0.aside != true && $0.call?.action != "inbox.open_on_mac" }.map { action in
            action.role == .destructive ? PartFace.Action(id: action.id, label: action.label, doors: action.doors, call: action.call,
                open: action.open, unavailable: action.unavailable) : action
        }
        return answers.isEmpty ? nil : answers
    }
}

public struct FaceThreadLine: Codable, Sendable, Equatable {
    public var id: String
    public var speaker: String
    public var text: String
    public var date: Date?
    public var session: String?
    public var receipt: String?
    public var failure: WireFailure?
    public init(id: String, speaker: String, text: String, date: Date?, session: String?, receipt: String?, failure: WireFailure?) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.date = date
        self.session = session
        self.receipt = receipt
        self.failure = failure
    }
}

public struct FaceContact: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var portrait: Data?
    public var appBundleID: String?
    public var state: FaceReadState
    /// The connection's setup waits on the person: its program needs their approval before it can start a turn.
    public var needsYou: Bool
    public init(id: String, label: String, portrait: Data?, appBundleID: String?, state: FaceReadState, needsYou: Bool) {
        self.id = id
        self.label = label
        self.portrait = portrait
        self.appBundleID = appBundleID
        self.state = state
        self.needsYou = needsYou
    }
}

public struct FaceMakeVersion: Codable, Sendable, Equatable {
    public var reference: String
    public var version: String
    public var title: String
    public var date: Date?
    public var prompt: String?
    public var kind: String?
    public init(reference: String, version: String, title: String, date: Date?, prompt: String? = nil, kind: String? = nil) {
        self.reference = reference
        self.version = version
        self.title = title
        self.date = date
        self.prompt = prompt
        self.kind = kind
    }
}

public struct FaceGraphEntity: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var detail: String?
    public var weight: Double?
    public var lastSeen: Date?
    public init(id: String, name: String, kind: String, detail: String?, weight: Double?, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.detail = detail
        self.weight = weight
        self.lastSeen = lastSeen
    }
}

public struct FaceGraphEdge: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var kind: String
    public var weight: Double?
    public init(from: String, to: String, kind: String, weight: Double?) {
        self.from = from
        self.to = to
        self.kind = kind
        self.weight = weight
    }
}

public struct LayoutFace: FaceValue {
    public var availability: SurfaceLayoutAvailability
    public init(availability: SurfaceLayoutAvailability) { self.availability = availability }

    public func contentNames(_ surface: String, profile: String?) -> [String] {
        availability.contentNames(surface, profile: profile)
    }
}

public struct VisibleReplyTarget: Codable, Sendable, Equatable {
    public var message: String
    public var turn: String
    public init(message: String, turn: String) { self.message = message; self.turn = turn }
}

public struct ConversationFace: FaceValue {
    public var session: String
    public var state: FaceReadState
    public var actions: [MessageActionFace]
    public var attachments: [FaceResolvedAttachment]
    public var waitingForPerson: Bool?
    public var visibleReply: VisibleReplyTarget?
    public var contactName: String?
    public init(session: String, state: FaceReadState, actions: [MessageActionFace], attachments: [FaceResolvedAttachment],
                waitingForPerson: Bool? = nil, visibleReply: VisibleReplyTarget? = nil) {
        self.session = session
        self.state = state
        self.actions = actions
        self.attachments = attachments
        self.waitingForPerson = waitingForPerson
        self.visibleReply = visibleReply
    }
}

public struct AgentScreenFace: FaceValue {
    public var room: String
    public var scope: String?
    public var text: String?
    public var state: FaceReadState
    public init(room: String, scope: String?, text: String?, state: FaceReadState) {
        self.room = room
        self.scope = scope
        self.text = text
        self.state = state
    }
}

public enum FacePaletteTarget: Codable, Sendable, Equatable {
    case page(String)
    case tab(page: String, tab: String)
    case setting(page: String, tab: String?)
    case conversation(String)
    case newConversation
    case refresh(FaceRefreshScope)
    case desk(String)
    case memory(String)
    case dream(String)
    case helperResult(bot: UUID, entry: UUID)
}

public struct PaletteFace: FaceValue {
    public var view: UUID
    public var query: String
    public var ranks: [[PartFace.Row]]
    public var sourceFailures: [String: WireFailure]
    public var targets: [String: FacePaletteTarget]
    public var state: FaceReadState
    public init(view: UUID, query: String, ranks: [[PartFace.Row]], targets: [String: FacePaletteTarget],
                sourceFailures: [String: WireFailure], state: FaceReadState) {
        self.view = view
        self.query = query
        self.ranks = ranks
        self.sourceFailures = sourceFailures
        self.targets = targets
        self.state = state
    }
}

public struct DeskPaletteFace: FaceValue {
    public var view: UUID
    public var query: String
    public var rows: [PartFace.Row]
    public var commands: [DeskCommandRequest]
    public var selectedHandle: String?
    public var state: FaceReadState
    public init(view: UUID, query: String, rows: [PartFace.Row], commands: [DeskCommandRequest], state: FaceReadState,
                selectedHandle: String? = nil) {
        self.view = view
        self.query = query
        self.rows = rows
        self.commands = commands
        self.selectedHandle = selectedHandle
        self.state = state
    }
}

public struct DeskDiagnosticsFace: FaceValue {
    public var rows: [PartFace.Row]
    public var state: FaceReadState
    public init(rows: [PartFace.Row], state: FaceReadState) {
        self.rows = rows
        self.state = state
    }
}

public struct WorkDetailFace: FaceValue {
    public var kind: String
    public var id: String
    public var title: String?
    public var status: String?
    public var location: String?
    public var text: String?
    public var sourceDate: Date?
    public var state: FaceReadState
    public init(kind: String, id: String, title: String?, status: String?, location: String?, text: String?, sourceDate: Date?,
                state: FaceReadState) {
        self.kind = kind
        self.id = id
        self.title = title
        self.status = status
        self.location = location
        self.text = text
        self.sourceDate = sourceDate
        self.state = state
    }
}

public struct ContactsFace: FaceValue {
    public var contacts: [FaceContact]
    public var state: FaceReadState
    public init(contacts: [FaceContact], state: FaceReadState) {
        self.contacts = contacts
        self.state = state
    }
}

public enum FaceContactThreadCommand: Codable, Sendable, Equatable {
    case stop(contact: String, record: String)
    case resend(contact: String, item: String, session: String)

    public var label: String {
        switch self {
        case .stop: "Stop"
        case .resend: "Send again"
        }
    }
}

public struct FaceContactFlight: Codable, Sendable, Equatable {
    public var record: String
    public var session: String
    public var isRunning: Bool
    public var liveLine: String?
    public init(record: String, session: String, isRunning: Bool, liveLine: String?) {
        self.record = record
        self.session = session
        self.isRunning = isRunning
        self.liveLine = liveLine
    }
}

public struct ContactThreadFace: FaceValue {
    public var contact: String
    public var lines: [FaceThreadLine]
    public var linkedSessions: [String]
    public var partialReply: String?
    public var flight: FaceContactFlight?
    public var waiting: [PartFace.Row]
    public var queued: [PartFace.Row]
    public var commands: [String: FaceContactThreadCommand]
    public var label: String?
    public var subtitle: String?
    public var sendRestriction: String?
    public var receipt: String?
    public var emptyText: String?
    public var state: FaceReadState
    public init(contact: String, lines: [FaceThreadLine], linkedSessions: [String], partialReply: String?, flight: FaceContactFlight?,
                waiting: [PartFace.Row], queued: [PartFace.Row], state: FaceReadState,
                commands: [String: FaceContactThreadCommand] = [:], label: String? = nil, subtitle: String? = nil, sendRestriction: String? = nil,
                receipt: String? = nil, emptyText: String? = nil) {
        self.contact = contact
        self.lines = lines
        self.linkedSessions = linkedSessions
        self.partialReply = partialReply
        self.flight = flight
        self.waiting = waiting
        self.queued = queued
        self.commands = commands
        self.label = label
        self.subtitle = subtitle
        self.sendRestriction = sendRestriction
        self.receipt = receipt
        self.emptyText = emptyText
        self.state = state
    }
}

public struct HelpersFace: FaceValue {
    public var rows: [PartFace.Row]
    public var runningIDs: [String]
    public var waitingIDs: [String]
    /// Helpers that wait on the person: for their answer, their approval or their choice of model.
    public var needsYouIDs: [String]
    public var state: FaceReadState
    public init(rows: [PartFace.Row], runningIDs: [String], waitingIDs: [String], needsYouIDs: [String], state: FaceReadState) {
        self.rows = rows
        self.runningIDs = runningIDs
        self.waitingIDs = waitingIDs
        self.needsYouIDs = needsYouIDs
        self.state = state
    }
}

public struct HelperRunsFace: FaceValue {
    public var helper: String
    public var runs: [PartFace.Row]
    public var state: FaceReadState
    public init(helper: String, runs: [PartFace.Row], state: FaceReadState) {
        self.helper = helper
        self.runs = runs
        self.state = state
    }
}

public struct MakeShelfFace: FaceValue {
    public var versions: [FaceMakeVersion]
    public var newest: String?
    public var state: FaceReadState
    public init(versions: [FaceMakeVersion], newest: String?, state: FaceReadState) {
        self.versions = versions
        self.newest = newest
        self.state = state
    }
}

extension MakePreviewFace {
    /// The most words, in UTF-8 bytes, Make takes in hand from one file: make.add's content, a contact's read of a piece, and a table the
    /// window reads or saves. The body and the window bound by this one number.
    public static let wordsLimit = 2_000_000
}

public struct MakePreviewFace: FaceValue {
    public var reference: String
    public var version: String
    public var kind: String?
    public var text: String?
    public var resources: [ResourceGrant]
    public var revision: String?
    public var titleKey: FaceKey?
    public var state: FaceReadState
    public init(reference: String, version: String, kind: String?, text: String?, resources: [ResourceGrant], revision: String?,
                state: FaceReadState, titleKey: FaceKey? = nil) {
        self.reference = reference
        self.version = version
        self.kind = kind
        self.text = text
        self.resources = resources
        self.revision = revision
        self.titleKey = titleKey
        self.state = state
    }
}

public struct SenseViewFace: FaceValue {
    public var senseID: String?
    public var version: Int?
    public var title: String?
    public var html: String?
    public var revision: String?
    public var resources: [ResourceGrant]
    public var state: FaceReadState
    public init(senseID: String?, version: Int?, title: String?, html: String?, revision: String?, resources: [ResourceGrant],
                state: FaceReadState) {
        self.senseID = senseID
        self.version = version
        self.title = title
        self.html = html
        self.revision = revision
        self.resources = resources
        self.state = state
    }
}

public struct MemoryDiagnosticsFace: Sendable, Equatable {
    public var rows: [PartFace.Row]
    public var stale: Bool?
    public var embeddingIssue: WireFailure?
    public var state: FaceReadState
    public init(rows: [PartFace.Row], stale: Bool?, embeddingIssue: WireFailure?, state: FaceReadState) {
        self.rows = rows
        self.stale = stale
        self.embeddingIssue = embeddingIssue
        self.state = state
    }
}

public struct KnowledgeGraphFace: FaceValue {
    public var entities: [FaceGraphEntity]
    public var edges: [FaceGraphEdge]
    public var state: FaceReadState
    public init(entities: [FaceGraphEntity], edges: [FaceGraphEdge], state: FaceReadState) {
        self.entities = entities
        self.edges = edges
        self.state = state
    }
}

public struct CognitionFace: FaceValue {
    public var sections: [PartFace]
    public var proposals: [PartFace.Row]
    public var receipts: [PartFace.Row]
    public var organism: [PartFace.Row]
    public var capsule: [PartFace.Row]
    public var state: FaceReadState
    public init(sections: [PartFace], proposals: [PartFace.Row],
                receipts: [PartFace.Row], organism: [PartFace.Row], capsule: [PartFace.Row], state: FaceReadState) {
        self.sections = sections
        self.proposals = proposals
        self.receipts = receipts
        self.organism = organism
        self.capsule = capsule
        self.state = state
    }
}

public struct ContextFlowHealthFace: FaceValue {
    public var health: FaceContextFlowHealth
    public var rows: [PartFace.Row]
    public var state: FaceReadState
    public init(health: FaceContextFlowHealth, rows: [PartFace.Row], state: FaceReadState) {
        self.health = health
        self.rows = rows
        self.state = state
    }
}

public struct MoodFace: FaceValue {
    public var warmth: Double?
    public var state: FaceReadState
    public init(warmth: Double?, state: FaceReadState) {
        self.warmth = warmth
        self.state = state
    }
}

public struct RunFace: FaceValue {
    public var id: String
    public var record: RunRecord?
    public var rows: [PartFace.Row]
    public var status: String?
    public var state: FaceReadState
    public init(id: String, record: RunRecord?, rows: [PartFace.Row], status: String?, state: FaceReadState) {
        self.id = id
        self.record = record
        self.rows = rows
        self.status = status
        self.state = state
    }
}

public struct OnboardingFace: FaceValue {
    public var disposition: String
    public var agentName: String?
    public var abilityOverview: [PartFace.Row]
    public var state: FaceReadState
    public init(disposition: String, agentName: String?, abilityOverview: [PartFace.Row], state: FaceReadState) {
        self.disposition = disposition
        self.agentName = agentName
        self.abilityOverview = abilityOverview
        self.state = state
    }
}

public struct ContextReceiptFace: FaceValue {
    public enum State: Codable, Sendable, Equatable {
        case waiting(on: String), ready, noTurn, outsideSearch, unavailable(WireFailure)
    }
    public struct Part: Codable, Sendable, Equatable, Identifiable {
        public enum ID: String, Codable, Sendable {
            case system, fed, memory, tools, history, message, images, toolRounds
        }
        public enum Measurement: String, Codable, Sendable { case estimated, measured }
        public var id: ID
        public var name: String
        public var tokens: Int?
        public var count: Int?
        public var measurement: Measurement
        public var detail: String?
        public init(id: ID, name: String, tokens: Int?, count: Int?, measurement: Measurement, detail: String?) {
            self.id = id
            self.name = name
            self.tokens = tokens
            self.count = count
            self.measurement = measurement
            self.detail = detail
        }
    }
    public var session: String
    public var turnId: String?
    /// Text rows serve the composer's quiet reading; the visual face uses typed parts.
    public var rows: [PartFace.Row]
    public var parts: [Part]
    public var totalTokens: Int?
    public var windowTokens: Int?
    public var model: String?
    public var ranAt: Date?
    public var state: State
    public init(session: String, turnId: String? = nil, rows: [PartFace.Row], parts: [Part] = [],
                totalTokens: Int? = nil, windowTokens: Int? = nil, model: String? = nil, ranAt: Date? = nil, state: State) {
        self.session = session
        self.turnId = turnId
        self.rows = rows
        self.parts = parts
        self.totalTokens = totalTokens
        self.windowTokens = windowTokens
        self.model = model
        self.ranAt = ranAt
        self.state = state
    }
}

public struct MacControlFace: FaceValue {
    public var driverAllowed: Bool?
    public var handoffWouldChange: Bool?
    public var handoffGeneration: UInt64?
    public var driver: DriverIdentity?
    public var state: FaceReadState
    public init(driverAllowed: Bool?, handoffWouldChange: Bool?, handoffGeneration: UInt64?, driver: DriverIdentity?, state: FaceReadState) {
        self.driverAllowed = driverAllowed
        self.handoffWouldChange = handoffWouldChange
        self.handoffGeneration = handoffGeneration
        self.driver = driver
        self.state = state
    }
}

public struct VoiceFace: FaceValue {
    public var operation: UUID
    public var session: String?
    public var message: String?
    public var phase: FaceVoicePhase
    public var text: String?
    public var attachment: FaceAttachment?
    public var state: FaceReadState
    public init(operation: UUID, session: String?, message: String?, phase: FaceVoicePhase, text: String?,
                attachment: FaceAttachment?, state: FaceReadState) {
        self.operation = operation
        self.session = session
        self.message = message
        self.phase = phase
        self.text = text
        self.attachment = attachment
        self.state = state
    }
}
