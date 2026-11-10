import Foundation
// Blueprint: | `FaceContracts.swift` | Typed body–face requests, effects and optional field settlement without changing installed-phone enums |

public enum FaceEffects: String, Codable, Sendable { case none, known, unknown }
public enum FacePresentationPolicy: String, Codable, Sendable { case foreground, quiet }
public enum FaceNavigationDisposition: String, Codable, Sendable { case mounted, queued, unavailable }
public enum ComposerEditDisposition: String, Codable, Sendable { case applied, conflict, preservedExisting }
public enum FaceEffectDisposition: String, Codable, Sendable { case completed, skipped }
public enum FaceApprovalDecision: String, Codable, Sendable { case approved, denied, canceled }
public enum ProposalDecision: String, Codable, Sendable { case accept, reject }

public enum DocumentSubject: Codable, Sendable, Equatable {
    case pageItem(page: String, item: String)
    case memory(id: String, rejected: Bool)
    case proposal(String)
    case message(session: String, message: String)
    case helperEntry(String)
    case dream(date: String)
    case run(String)
    case context(session: String)

    public var documentFormat: String {
        switch self {
        case .message, .run, .context: "code"
        case .pageItem, .memory, .proposal, .helperEntry, .dream: "plain"
        }
    }
}

public enum FaceDemand: Codable, Sendable, Equatable {
    case key(FaceKey)
    case composer(session: String)
    case palette(view: UUID, query: String)
    case sessionSearch(view: UUID, query: String)
    case deskPalette(view: UUID, query: String)
    case agentScreen(room: String, scope: String?)
    case graphNeighborhood(entity: String)
    case dreamDiary(limit: Int)
}

public enum FaceRefreshScope: Codable, Sendable, Equatable {
    case all
    case page(String)
    case session(String)
    case panel(String)
    case settings
}

public struct WireFailure: Codable, Sendable, Equatable, LocalizedError {
    public var code: String
    public var message: String
    public var cause: String?
    public var effects: FaceEffects
    public var committed: [FaceCommittedField]?
    public var fields: [String: String]?
    public var errorDescription: String? { cause.map { message + "\n" + $0 } ?? message }
    public init(code: String, message: String, cause: String?, effects: FaceEffects,
                committed: [FaceCommittedField]? = nil, fields: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.cause = cause
        self.effects = effects
        self.committed = committed
        self.fields = fields
    }
}

public struct CommittedResult: Codable, Sendable, Equatable {
    public var identities: [String]
    public var value: PartFace.Value
    public var revision: String?
    public var effects: FaceEffects
    public var publicationFailure: WireFailure?
    public init(identities: [String], value: PartFace.Value, revision: String?, effects: FaceEffects, publicationFailure: WireFailure?) {
        self.identities = identities
        self.value = value
        self.revision = revision
        self.effects = effects
        self.publicationFailure = publicationFailure
    }
}

/// A file handed between her body and her window, which are separate apps: a plain bookmark, which any process resolves;
/// an app-scoped (security-scoped) bookmark resolves only in the app that made it.
public struct ResourceGrant: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var bookmark: Data
    public var writable: Bool
    public init(id: UUID, name: String, bookmark: Data, writable: Bool) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.writable = writable
    }
}

public struct ArtifactGrant: Codable, Sendable, Equatable {
    public var resource: ResourceGrant?
    public var bytes: Data?
    public var mimeType: String
    public var name: String
    public var warnings: [String]
    public init(resource: ResourceGrant?, bytes: Data?, mimeType: String, name: String, warnings: [String]) {
        self.resource = resource
        self.bytes = bytes
        self.mimeType = mimeType
        self.name = name
        self.warnings = warnings
    }
}

public struct FaceDestination: Codable, Sendable, Equatable {
    public var page: String
    public var item: String?
    public var session: String?
    public var message: String?
    public init(page: String, item: String?, session: String?, message: String?) {
        self.page = page
        self.item = item
        self.session = session
        self.message = message
    }
}

public struct FaceNavigationRequest: Codable, Sendable, Equatable {
    public var destination: FaceDestination
    public var policy: FacePresentationPolicy
    public init(destination: FaceDestination, policy: FacePresentationPolicy) {
        self.destination = destination
        self.policy = policy
    }
}

public struct NavigationReceipt: Codable, Sendable, Equatable {
    public var disposition: FaceNavigationDisposition
    public var destination: FaceDestination?
    public var reason: String?
    public init(disposition: FaceNavigationDisposition, destination: FaceDestination?, reason: String?) {
        self.disposition = disposition
        self.destination = destination
        self.reason = reason
    }
}

public struct ComposerControlsSnapshot: Codable, Sendable, Equatable {
    public var openCard: String?
    public var rows: [String]
    public var workPaneClosed: Bool
    public init(openCard: String?, rows: [String], workPaneClosed: Bool) {
        self.openCard = openCard
        self.rows = rows
        self.workPaneClosed = workPaneClosed
    }
}

public struct ComposerSnapshot: Codable, Sendable, Equatable {
    public var session: String
    public var text: String
    public var revision: UInt64
    public var editedAt: Date?
    public var attachments: [FaceAttachment]
    public init(session: String, text: String, revision: UInt64, editedAt: Date?, attachments: [FaceAttachment]) {
        self.session = session
        self.text = text
        self.revision = revision
        self.editedAt = editedAt
        self.attachments = attachments
    }
}

public struct ComposerEditRequest: Codable, Sendable, Equatable {
    public var session: String
    public var text: String
    public var attachments: [FaceAttachment]
    public var expectedRevision: UInt64
    public var expectedEditedAt: Date?
    public var existingAttachmentIDs: [String]
    public init(session: String, text: String, attachments: [FaceAttachment], expectedRevision: UInt64, expectedEditedAt: Date?,
                existingAttachmentIDs: [String]) {
        self.session = session
        self.text = text
        self.attachments = attachments
        self.expectedRevision = expectedRevision
        self.expectedEditedAt = expectedEditedAt
        self.existingAttachmentIDs = existingAttachmentIDs
    }
}

public struct ComposerAcceptedEdit: Codable, Sendable, Equatable {
    public var session: String
    public var text: String
    public var revision: UInt64
    public var attachmentIDs: [String]
    public init(session: String, text: String, revision: UInt64, attachmentIDs: [String]) {
        self.session = session
        self.text = text
        self.revision = revision
        self.attachmentIDs = attachmentIDs
    }
}

public struct ComposerEditResult: Codable, Sendable, Equatable {
    public var disposition: ComposerEditDisposition
    public var snapshot: ComposerSnapshot
    public init(disposition: ComposerEditDisposition, snapshot: ComposerSnapshot) {
        self.disposition = disposition
        self.snapshot = snapshot
    }
}

public struct FaceAttachment: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    public var resource: ResourceGrant?
    public var bytes: Data?
    public init(id: String, name: String, mimeType: String, byteCount: Int, resource: ResourceGrant?, bytes: Data?) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.resource = resource
        self.bytes = bytes
    }
}

public struct SendRequest: Codable, Sendable, Equatable {
    public var session: String?
    public var text: String
    public var attachments: [FaceAttachment]
    public var composerRevision: UInt64
    public var expectedSelection: String?
    public var options: FaceSendOptions
    public init(session: String?, text: String, attachments: [FaceAttachment], composerRevision: UInt64, expectedSelection: String?,
                options: FaceSendOptions) {
        self.session = session
        self.text = text
        self.attachments = attachments
        self.composerRevision = composerRevision
        self.expectedSelection = expectedSelection
        self.options = options
    }
}

public struct FaceSendOptions: Codable, Sendable, Equatable {
    public var hideUserBubble: Bool
    public var choice: ProviderTurnChoice?
    public var continuationReference: String?
    public init(hideUserBubble: Bool, choice: ProviderTurnChoice?, continuationReference: String?) {
        self.hideUserBubble = hideUserBubble
        self.choice = choice
        self.continuationReference = continuationReference
    }
}

public struct ConversationExportRequest: Codable, Sendable, Equatable {
    public var session: String
    public var format: String
    public var destination: ResourceGrant
    public init(session: String, format: String, destination: ResourceGrant) {
        self.session = session
        self.format = format
        self.destination = destination
    }
}

public struct PageActRequest: Codable, Sendable, Equatable {
    public var page: String
    public var row: String
    public var action: String
    public var value: PartFace.Value?
    public var expectedRevision: String?
    public var expectedCall: PartFace.Call?
    public var answers: Bool?
    public var operation: UUID?
    public var undoOf: UUID?
    public var checking: Bool?
    public init(page: String, row: String, action: String, value: PartFace.Value?, expectedRevision: String?, expectedCall: PartFace.Call?,
                answers: Bool? = nil, operation: UUID? = nil, undoOf: UUID? = nil, checking: Bool? = nil) {
        self.page = page
        self.row = row
        self.action = action
        self.value = value
        self.expectedRevision = expectedRevision
        self.expectedCall = expectedCall
        self.answers = answers
        self.operation = operation
        self.undoOf = undoOf
        self.checking = checking
    }
}

public struct DocumentRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var subject: DocumentSubject
    public var expectedCall: PartFace.Call?
    public var textOnly: Bool?
    public var presentation: Bool?
    public var pageRead: FaceReadRequest?
    public var release: Bool?
    public init(id: UUID, subject: DocumentSubject, expectedCall: PartFace.Call? = nil, textOnly: Bool? = nil,
                presentation: Bool? = nil, pageRead: FaceReadRequest? = nil, release: Bool? = nil) {
        self.id = id
        self.subject = subject
        self.expectedCall = expectedCall
        self.textOnly = textOnly
        self.presentation = presentation
        self.pageRead = pageRead
        self.release = release
    }
}

public struct TranscriptReaderGeometry: Codable, Sendable, Equatable {
    public var reader: UUID
    public var width: Double
    public var scale: Double
    public var viewportHeight: Double
    public var viewport: Set<String>
    public init(reader: UUID, width: Double, scale: Double, viewportHeight: Double, viewport: Set<String> = []) {
        self.reader = reader
        self.width = width
        self.scale = scale
        self.viewportHeight = viewportHeight
        self.viewport = viewport
    }
}

public struct TranscriptReaderRequest: Codable, Sendable, Equatable {
    public var session: String
    public var presentation: String
    public var geometry: TranscriptReaderGeometry
    public var openingParagraphCount: Int
    public init(session: String, presentation: String, geometry: TranscriptReaderGeometry, openingParagraphCount: Int) {
        self.session = session
        self.presentation = presentation
        self.geometry = geometry
        self.openingParagraphCount = openingParagraphCount
    }
}

public struct VisibleReplyReceipt: Codable, Sendable, Equatable {
    public var reader: UUID
    public var session: String
    public var message: String
    public var turn: String
    public var script: UUID
    public var visible: Bool
    public init(reader: UUID, session: String, message: String, turn: String, script: UUID, visible: Bool) {
        self.reader = reader
        self.session = session
        self.message = message
        self.turn = turn
        self.script = script
        self.visible = visible
    }
}

public enum ChatChoiceEdit: String, Codable, Sendable { case selection, reasoning, fast }

public struct ChatChoiceWrite: Codable, Sendable, Equatable {
    public var choice: ProviderTurnChoice
    public var expectedBaseline: ProviderTurnChoice?
    public var expectedRevision: Double
    public var edit: ChatChoiceEdit
    public init(choice: ProviderTurnChoice, expectedBaseline: ProviderTurnChoice?, expectedRevision: Double, edit: ChatChoiceEdit = .selection) {
        self.choice = choice
        self.expectedBaseline = expectedBaseline
        self.expectedRevision = expectedRevision
        self.edit = edit
    }
}

public struct ProviderConnectionWrite: Codable, Sendable, Equatable {
    public var id: String
    public var secret: Data?
    public var authMode: String
    public var defaultModel: String
    public var expectedRevision: String?
    public init(id: String, secret: Data?, authMode: String, defaultModel: String, expectedRevision: String?) {
        self.id = id
        self.secret = secret
        self.authMode = authMode
        self.defaultModel = defaultModel
        self.expectedRevision = expectedRevision
    }
}

public struct ProviderTestRequest: Codable, Sendable, Equatable {
    public var id: String
    public var authMode: String
    public var secret: Data?
    public var displayedRevision: String?
    public init(id: String, authMode: String, secret: Data?, displayedRevision: String?) {
        self.id = id
        self.authMode = authMode
        self.secret = secret
        self.displayedRevision = displayedRevision
    }
}

public struct ProviderTestReply: Codable, Sendable {
    public var result: ProviderTestResult
    public var credentialReady: Bool
    public var credentialMatches: Bool
    public init(result: ProviderTestResult, credentialReady: Bool, credentialMatches: Bool) {
        self.result = result
        self.credentialReady = credentialReady
        self.credentialMatches = credentialMatches
    }
}

public struct CardIdentity: Codable, Sendable, Equatable {
    public var card: String
    public var session: String
    public var revision: Int
    public init(card: String, session: String, revision: Int) {
        self.card = card
        self.session = session
        self.revision = revision
    }
}

public struct CardAnswer: Codable, Sendable, Equatable {
    public var identity: CardIdentity
    public var choice: String
    public var fields: [String: PartFace.Value]
    public var secrets: [String: Data]
    public init(identity: CardIdentity, choice: String, fields: [String: PartFace.Value], secrets: [String: Data]) {
        self.identity = identity
        self.choice = choice
        self.fields = fields
        self.secrets = secrets
    }
}

public struct ConnectorCredentialWrite: Codable, Sendable, Equatable {
    public var operation: UUID
    public var id: String
    public var fields: [String: Data]
    public init(operation: UUID, id: String, fields: [String: Data]) {
        self.operation = operation
        self.id = id
        self.fields = fields
    }
}

public struct TelegramConfigurationWrite: Codable, Sendable, Equatable {
    public var token: Data?
    public var allowedUserIDs: [String]
    public var allowedChatIDs: [String]
    public init(token: Data?, allowedUserIDs: [String], allowedChatIDs: [String]) {
        self.token = token
        self.allowedUserIDs = allowedUserIDs
        self.allowedChatIDs = allowedChatIDs
    }
}

public struct SlackIngressWrite: Codable, Sendable, Equatable {
    public var token: Data?
    public var allowedChannelIDs: [String]
    public var allowedUserIDs: [String]
    public init(token: Data?, allowedChannelIDs: [String], allowedUserIDs: [String]) {
        self.token = token
        self.allowedChannelIDs = allowedChannelIDs
        self.allowedUserIDs = allowedUserIDs
    }
}

public struct GrokCredentialWrite: Codable, Sendable, Equatable {
    public var operation: UUID
    public var contact: String
    public var secret: Data
    public init(operation: UUID, contact: String, secret: Data) {
        self.operation = operation
        self.contact = contact
        self.secret = secret
    }
}

public struct TrustPresetRequest: Codable, Sendable, Equatable {
    public var preset: String
    public var confirmed: Bool
    public var expectedRevision: String
    public init(preset: String, confirmed: Bool, expectedRevision: String) {
        self.preset = preset
        self.confirmed = confirmed
        self.expectedRevision = expectedRevision
    }
}

public struct MemoryPolicyPatch: Codable, Sendable, Equatable {
    public var fields: [String: PartFace.Value]
    public var expectedRevision: String
    public init(fields: [String: PartFace.Value], expectedRevision: String) {
        self.fields = fields
        self.expectedRevision = expectedRevision
    }
}

public struct MacControlPolicyWrite: Codable, Sendable, Equatable {
    public var policy: MacControlPolicyWireSnapshot
    public var baseline: MacControlPolicyWireSnapshot
    public init(policy: MacControlPolicyWireSnapshot, baseline: MacControlPolicyWireSnapshot) {
        self.policy = policy
        self.baseline = baseline
    }
}

public struct MultimodalPolicyWrite: Codable, Sendable, Equatable {
    public var fields: [String: PartFace.Value]
    public var expectedRevision: String
    public init(fields: [String: PartFace.Value], expectedRevision: String) {
        self.fields = fields
        self.expectedRevision = expectedRevision
    }
}

public struct MacControlRequest: Codable, Sendable, Equatable {
    public var action: String
    public var arguments: [String: PartFace.Value]
    public var checking: Bool?
    public init(action: String, arguments: [String: PartFace.Value], checking: Bool? = nil) {
        self.action = action
        self.arguments = arguments
        self.checking = checking
    }
}

public struct ActivityPolicyWrite: Codable, Sendable, Equatable {
    public var fields: [String: PartFace.Value]
    public var expectedRevision: String
    public init(fields: [String: PartFace.Value], expectedRevision: String) {
        self.fields = fields
        self.expectedRevision = expectedRevision
    }
}

public struct DoctorRequest: Codable, Sendable, Equatable {
    public var scope: String
    public var repair: Bool
    public init(scope: String, repair: Bool) {
        self.scope = scope
        self.repair = repair
    }
}

public struct StarterPersonaRequest: Codable, Sendable, Equatable {
    public var agentName: String
    public var personaType: String
    public var userName: String
    public init(agentName: String, personaType: String, userName: String) {
        self.agentName = agentName
        self.personaType = personaType
        self.userName = userName
    }
}

public struct DeskCommandRequest: Codable, Sendable, Equatable {
    public var command: String
    public var handle: String?
    public var arguments: [String: PartFace.Value]
    public init(command: String, handle: String?, arguments: [String: PartFace.Value]) {
        self.command = command
        self.handle = handle
        self.arguments = arguments
    }
}

public enum MakeExportDestination: Codable, Sendable, Equatable {
    case project(session: String)
    case chosen(directory: ResourceGrant, name: String)
}

public struct MakeExportChoice: Codable, Sendable, Equatable {
    public var name: String
    public var directory: ResourceGrant?
    public init(name: String, directory: ResourceGrant?) { self.name = name; self.directory = directory }
}

public struct MakeExportRequest: Codable, Sendable, Equatable {
    public var reference: String
    public var version: String
    public var destination: MakeExportDestination
    public init(reference: String, version: String, destination: MakeExportDestination) {
        self.reference = reference
        self.version = version
        self.destination = destination
    }
}

public struct ContactSendRequest: Codable, Sendable, Equatable {
    public var contact: String
    public var text: String
    public var session: String?
    public init(contact: String, text: String, session: String?) {
        self.contact = contact
        self.text = text
        self.session = session
    }
}

public struct AttachmentTransfer: Codable, Sendable, Equatable {
    public var id: UUID
    public var session: String?
    public var attachment: FaceAttachment
    public init(id: UUID, session: String?, attachment: FaceAttachment) {
        self.id = id
        self.session = session
        self.attachment = attachment
    }
}

public struct ScreenCaptureRequest: Codable, Sendable, Equatable {
    public var operation: UUID
    public var session: String?
    public var composerRevision: UInt64
    public var expectedSelection: String?
    public var sendWithText: String?
    public init(operation: UUID, session: String?, composerRevision: UInt64, expectedSelection: String?, sendWithText: String?) {
        self.operation = operation
        self.session = session
        self.composerRevision = composerRevision
        self.expectedSelection = expectedSelection
        self.sendWithText = sendWithText
    }
}

public struct SceneReport: Codable, Sendable, Equatable {
    public var connection: UUID
    public var id: UUID
    public var destination: FaceDestination?
    public var isKey: Bool
    public var composerSession: String?
    public var selectedSession: String?
    public var mounted: Bool
    public init(connection: UUID, id: UUID, destination: FaceDestination?, isKey: Bool,
                composerSession: String?, selectedSession: String?, mounted: Bool) {
        self.connection = connection
        self.id = id
        self.destination = destination
        self.isKey = isKey
        self.composerSession = composerSession
        self.selectedSession = selectedSession
        self.mounted = mounted
    }
}

public struct FaceRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ProtectedWindow: Codable, Sendable, Equatable {
    public var number: Int
    public var frame: FaceRect
    public var keyHeld: Bool
    public init(number: Int, frame: FaceRect, keyHeld: Bool) {
        self.number = number
        self.frame = frame
        self.keyHeld = keyHeld
    }
}

public struct ProtectedWindowsReport: Codable, Sendable, Equatable {
    public var connection: UUID
    public var windows: [ProtectedWindow]
    public init(connection: UUID, windows: [ProtectedWindow]) {
        self.connection = connection
        self.windows = windows
    }
}

public struct RendererInspectorReport: Codable, Sendable, Equatable {
    public var connection: UUID
    public var view: UUID?
    public var subscription: UUID?
    public var mounted: Bool
    public var observing: Bool
    public var issue: String?
    public init(connection: UUID, view: UUID?, subscription: UUID?, mounted: Bool, observing: Bool, issue: String?) {
        self.connection = connection
        self.view = view
        self.subscription = subscription
        self.mounted = mounted
        self.observing = observing
        self.issue = issue
    }
}

public struct RendererDiagnostic: Codable, Sendable, Equatable {
    public var kind: String
    public var reader: UUID?
    public var message: String
    public init(kind: String, reader: UUID?, message: String) {
        self.kind = kind
        self.reader = reader
        self.message = message
    }
}

public struct NotificationResponse: Codable, Sendable, Equatable {
    public var id: String?
    public var action: String
    public var text: String?
    public var category: String
    public var route: [String: String]
    public var title: String
    public var body: String
    public init(id: String?, action: String, text: String?, category: String, route: [String: String], title: String, body: String) {
        self.id = id
        self.action = action
        self.text = text
        self.category = category
        self.route = route
        self.title = title
        self.body = body
    }
}

public struct WorkPaneSnapshot: Codable, Sendable, Equatable {
    public var isVisible: Bool
    public var tab: String?
    public var reference: String?
    public var version: String?
    public init(isVisible: Bool, tab: String?, reference: String?, version: String? = nil) {
        self.isVisible = isVisible
        self.tab = tab
        self.reference = reference
        self.version = version
    }
}

public struct ChosenFolder: Codable, Sendable, Equatable {
    public var label: String
    public var resource: ResourceGrant
    public var writable: Bool
    public init(label: String, resource: ResourceGrant, writable: Bool) {
        self.label = label
        self.resource = resource
        self.writable = writable
    }
}

public struct ChosenExclusion: Codable, Sendable, Equatable {
    public var bundleID: String
    public var confirmed: Bool
    public init(bundleID: String, confirmed: Bool) {
        self.bundleID = bundleID
        self.confirmed = confirmed
    }
}

public struct OAuthPresentationRequest: Codable, Sendable, Equatable {
    public var operation: UUID
    public var provider: String
    public var authorizationURL: String
    public var expectedState: String
    public var callbackScheme: String
    public init(operation: UUID, provider: String, authorizationURL: String, expectedState: String, callbackScheme: String) {
        self.operation = operation
        self.provider = provider
        self.authorizationURL = authorizationURL
        self.expectedState = expectedState
        self.callbackScheme = callbackScheme
    }
}

public struct PageRenderRequest: Codable, Sendable, Equatable {
    public var page: String
    public var tab: String?
    public var width: Double
    public var height: Double
    public var epoch: UUID
    public var barrier: UUID
    public var reader: UUID
    public var workPane: WorkPaneSnapshot?
    public init(page: String, tab: String?, width: Double, height: Double, epoch: UUID, barrier: UUID, reader: UUID,
                workPane: WorkPaneSnapshot? = nil) {
        self.page = page
        self.tab = tab
        self.width = width
        self.height = height
        self.epoch = epoch
        self.barrier = barrier
        self.reader = reader
        self.workPane = workPane
    }
}

public struct PageRenderResult: Codable, Sendable, Equatable {
    public var png: Data?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var epoch: UUID
    public var appliedBarrier: UUID?
    public var failure: WireFailure?
    public init(png: Data?, pixelWidth: Int, pixelHeight: Int, epoch: UUID, appliedBarrier: UUID?, failure: WireFailure?) {
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.epoch = epoch
        self.appliedBarrier = appliedBarrier
        self.failure = failure
    }
}

public struct DriverIdentity: Codable, Sendable, Equatable {
    public var session: String
    public var turn: String
    public init(session: String, turn: String) {
        self.session = session
        self.turn = turn
    }
}

public struct PointerPresentation: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var pressed: Bool
    public var name: String?
    public var driver: DriverIdentity?
    public init(x: Double, y: Double, pressed: Bool, name: String?, driver: DriverIdentity?) {
        self.x = x
        self.y = y
        self.pressed = pressed
        self.name = name
        self.driver = driver
    }
}

public enum UpdateInteraction: Codable, Sendable, Equatable {
    case permission(automaticChecks: Bool, automaticDownloads: Bool?, systemProfile: Bool)
    case cancel, install, dismiss, skip, retryTermination, acknowledge
}

public enum UpdatePresentationEvent: Codable, Sendable, Equatable {
    case permission(request: Data)
    case checking
    case found(item: Data, state: Data)
    case releaseNotes(Data)
    case releaseNotesFailed(detail: String)
    case notFound(error: Data)
    case failed(error: Data)
    case downloading
    case expectedLength(UInt64)
    case receivedLength(UInt64)
    case extracting
    case extractionProgress(Double)
    case ready
    case installing(applicationTerminated: Bool)
    case installed(relaunched: Bool)
    case dismiss, focus
}

public struct UpdatePresentationRequest: Codable, Sendable, Equatable {
    public var operation: UUID
    public var event: UpdatePresentationEvent
    public init(operation: UUID, event: UpdatePresentationEvent) {
        self.operation = operation
        self.event = event
    }
}

public struct FaceEffectReceipt: Codable, Sendable, Equatable {
    public var operation: UUID?
    public var disposition: FaceEffectDisposition
    public var reason: String?
    public init(operation: UUID?, disposition: FaceEffectDisposition, reason: String?) {
        self.operation = operation
        self.disposition = disposition
        self.reason = reason
    }
}
